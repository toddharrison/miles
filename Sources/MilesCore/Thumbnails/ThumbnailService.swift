import Foundation
import GRDB

public enum ThumbnailOutcome: Equatable, Sendable {
    case generated
    case upToDate
    /// The file is an evicted iCloud placeholder. Nothing was read or downloaded.
    case notLocal
    /// No renderer handles this kind of file.
    case unsupported
    case missing
    case failed(String)
}

public struct ThumbnailBatch: Equatable, Sendable {
    public var generated = 0
    public var skippedNotLocal = 0
    public var unsupported = 0
    public var failed = 0
}

/// What a "fetch once" run would download. Shown to the user before a large batch starts.
public struct FetchPlan: Equatable, Sendable {
    public var rootID: Int64
    public var fileCount: Int
    public var totalBytes: Int64
}

public enum ThumbnailError: Error, Equatable, Sendable {
    case fileNotFound(Int64)
    case rootUnavailable(Int64)
    case fetchOnceDisabled(rootID: Int64)
    /// The batch is large, so the user must approve it (pass `approvedCount` at least `plan.fileCount`).
    case needsApproval(FetchPlan)
}

extension ThumbnailError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let id): "No file with id \(id)."
        case .rootUnavailable(let id): "Root \(id) is not available (is its drive mounted?)."
        case .fetchOnceDisabled(let id): "\"Fetch once\" is off for root \(id)."
        case .needsApproval(let plan):
            "This would download \(plan.fileCount) files (\(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))). Approve it explicitly to continue."
        }
    }
}

/// Generates and maintains the thumbnail cache (ADR 0011).
///
/// The one rule: **thumbnailing never downloads an iCloud file**. `generate` and `generateMissing`
/// look only at local files, checking live metadata (which does not trigger a download) before
/// reading any content. Downloads happen only in `prepareToOpen` (the user opened the file) and
/// `fetchOnce` (an opt-in per-root setting, with approval for large batches).
public final class ThumbnailService: @unchecked Sendable {
    /// Batches above either limit need explicit approval.
    public static let approvalFileLimit = 25
    public static let approvalByteLimit: Int64 = 250_000_000

    let library: Library
    let fileSystem: FileSystem
    let renderer: ThumbnailRenderer
    /// The cache lives in the library folder, which is always a real local folder.
    private let cacheFS: FileSystem = RealFileSystem()

    public init(library: Library, fileSystem: FileSystem, renderer: ThumbnailRenderer = ImageIORenderer()) {
        self.library = library
        self.fileSystem = fileSystem
        self.renderer = renderer
    }

    // MARK: Generate (never downloads)

    @discardableResult
    public func generate(fileID: Int64, force: Bool = false) -> ThumbnailOutcome {
        do {
            guard let file = try library.file(id: fileID), file.missingSince == nil else { return .missing }
            guard renderer.canRender(kind: file.kind) else { return .unsupported }
            if !force, try isFresh(file) { return .upToDate }
            guard let path = try? library.absolutePath(of: file, fileSystem: fileSystem),
                  let live = try? fileSystem.metadata(at: path) else { return .missing }
            // Live check: the index may predate an eviction. Reading a placeholder would download it.
            if live.isDataless { return .notLocal }
            for size in ThumbnailSize.allCases {
                let data = try renderer.render(path: path, maxPixelSize: size.rawValue)
                let target = library.thumbnailPath(fileID: fileID, size: size)
                try cacheFS.createDirectory(at: (target as NSString).deletingLastPathComponent)
                try cacheFS.writeFile(data, to: target)
            }
            try library.database.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO thumbnail (fileID, sourceSize, sourceModified, generatedAt) VALUES (?, ?, ?, ?)
                    """, arguments: [fileID, file.size, file.modified, Date()])
            }
            return .generated
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Generates thumbnails for local image files that have none (or a stale one). Run after a scan.
    public func generateMissing(rootID: Int64? = nil, limit: Int? = nil) throws -> ThumbnailBatch {
        var batch = ThumbnailBatch()
        for id in try library.filesNeedingThumbnails(rootID: rootID, limit: limit) {
            switch generate(fileID: id) {
            case .generated: batch.generated += 1
            case .notLocal: batch.skippedNotLocal += 1
            case .unsupported: batch.unsupported += 1
            case .upToDate: break
            case .missing, .failed: batch.failed += 1
            }
        }
        return batch
    }

    // MARK: Fetch once (opt-in, per root)

    public func fetchPlan(rootID: Int64) throws -> FetchPlan {
        let rows = try library.placeholdersWithoutThumbnails(rootID: rootID)
        return FetchPlan(rootID: rootID, fileCount: rows.count, totalBytes: rows.reduce(0) { $0 + $1.size })
    }

    /// Downloads each placeholder image that has no thumbnail, builds its thumbnail, and leaves the
    /// file for the system to evict again. Requires the root's setting to be on. A batch over the
    /// limits throws `needsApproval` unless `approvedCount` covers it; at most `approvedCount` files are fetched.
    public func fetchOnce(rootID: Int64, approvedCount: Int? = nil) throws -> ThumbnailBatch {
        guard try library.roots().first(where: { $0.id == rootID })?.fetchOnce == true else {
            throw ThumbnailError.fetchOnceDisabled(rootID: rootID)
        }
        let plan = try fetchPlan(rootID: rootID)
        let large = plan.fileCount > Self.approvalFileLimit || plan.totalBytes > Self.approvalByteLimit
        if large, (approvedCount ?? 0) < plan.fileCount { throw ThumbnailError.needsApproval(plan) }

        var batch = ThumbnailBatch()
        let candidates = try library.placeholdersWithoutThumbnails(rootID: rootID)
        for file in candidates.prefix(approvedCount ?? candidates.count) {
            guard renderer.canRender(kind: file.kind), let path = try? library.absolutePath(of: file, fileSystem: fileSystem) else {
                batch.unsupported += 1
                continue
            }
            do { try fileSystem.download(at: path) } catch { batch.failed += 1; continue }
            switch generate(fileID: file.id, force: true) {
            case .generated: batch.generated += 1
            case .notLocal: batch.skippedNotLocal += 1
            default: batch.failed += 1
            }
        }
        return batch
    }

    // MARK: Open (user action)

    /// For the user opening a file: downloads it if it is a placeholder, builds its thumbnail, and
    /// returns the absolute path to hand to the system. This is the only place a download follows
    /// from a single user action.
    public func prepareToOpen(fileID: Int64) throws -> String {
        guard let file = try library.file(id: fileID) else { throw ThumbnailError.fileNotFound(fileID) }
        let path = try library.absolutePath(of: file, fileSystem: fileSystem)
        if let live = try? fileSystem.metadata(at: path), live.isDataless {
            try fileSystem.download(at: path)
            try library.database.write { db in
                try db.execute(sql: "UPDATE file SET icloudStatus = 'local' WHERE id = ?", arguments: [fileID])
            }
        }
        generate(fileID: fileID)
        return path
    }

    // MARK: Helpers

    private func isFresh(_ file: IndexedFile) throws -> Bool {
        let recorded = try library.database.read { db in
            try Row.fetchOne(db, sql: "SELECT sourceSize, sourceModified FROM thumbnail WHERE fileID = ?", arguments: [file.id])
        }
        guard let recorded, (recorded["sourceSize"] as Int64) == file.size, (recorded["sourceModified"] as Date) == file.modified else { return false }
        return ThumbnailSize.allCases.allSatisfy { cacheFS.exists(library.thumbnailPath(fileID: file.id, size: $0)) }
    }
}
