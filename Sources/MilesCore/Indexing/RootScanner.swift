import Foundation
import GRDB

/// What part of a root a scan covers.
public enum ScanScope: Equatable, Sendable {
    /// The whole root.
    case full
    /// One path under the root (relative, no leading slash): a file, or a directory and everything below it.
    /// A path that no longer exists means its rows are now missing. Used for file-change events.
    case subtree(String)
}

public struct ScanOptions: Sendable {
    /// How long a file may stay missing before its row is removed (data model: marked, not deleted).
    public var gracePeriod: TimeInterval
    public var now: @Sendable () -> Date
    /// Rows are written in transactions of this many files.
    public var batchSize: Int

    public init(gracePeriod: TimeInterval = 30 * 24 * 3600, batchSize: Int = 1000, now: @escaping @Sendable () -> Date = { Date() }) {
        self.gracePeriod = gracePeriod
        self.batchSize = batchSize
        self.now = now
    }
}

public struct ScanResult: Equatable, Sendable {
    /// False if the root's drive is not mounted or the folder is gone. Nothing was changed.
    public var rootAvailable = true
    public var added = 0
    public var updated = 0
    public var unchanged = 0
    /// Rows re-matched to a moved or renamed file (tags and identity kept).
    public var moved = 0
    public var markedMissing = 0
    public var removed = 0
    /// Directories not read: iCloud placeholders, unreadable folders, other volumes. Files under them are left as they were.
    public var skippedDirectories: [String] = []
    /// True if so many directories were skipped that missing-file bookkeeping was not attempted.
    public var missingCheckSkipped = false
}

extension Library {
    /// Walks a root (or part of it) and brings the `file` table in line with the disk. Reads metadata only:
    /// never file content (except to re-match a moved file by hash), never an iCloud download, and never
    /// anything that changes a user's files (ADR 0001).
    @discardableResult
    public func scan(rootID: Int64, scope: ScanScope = .full, fileSystem fs: FileSystem,
                     options: ScanOptions = ScanOptions()) throws -> ScanResult {
        try RootScan(library: self, rootID: rootID, scope: scope, fs: fs, options: options).run()
    }
}

private struct PendingEntry {
    var relativePath: String
    var name: String
    var path: String
    var meta: FileMetadata
}

private struct ExistingRow {
    var id: Int64
    var size: Int64
    var modified: Date
    var fileID: Int64
    var volumeID: String
    var icloudStatus: String
}

private final class RootScan {
    let library: Library
    let rootID: Int64
    let scope: ScanScope
    let fs: FileSystem
    let options: ScanOptions
    let classifier = FileKind.Classifier()

    var result = ScanResult()
    var rootVolumeID = ""
    var rootPath = ""
    var exclusions = Exclusions()
    var start = Date()
    var mayHaveCandidates = false
    var candidateRootPaths: [Int64: String?] = [:]

    init(library: Library, rootID: Int64, scope: ScanScope, fs: FileSystem, options: ScanOptions) {
        self.library = library
        self.rootID = rootID
        self.scope = scope
        self.fs = fs
        self.options = options
    }

    // MARK: Run

    func run() throws -> ScanResult {
        guard let row = try library.database.read({ db in
            try Row.fetchOne(db, sql: "SELECT volumeID, relativePath, exclusions FROM root WHERE id = ?", arguments: [rootID])
        }) else { throw LibraryError.invalidRoot("root \(rootID)") }

        let location = VolumeLocation(volumeID: row["volumeID"], relativePath: row["relativePath"])
        exclusions = Exclusions.decode(row["exclusions"])
        rootVolumeID = location.volumeID

        var startRelative = ""
        if case .subtree(let sub) = scope {
            let parts = sub.split(separator: "/").filter { $0 != "." }
            guard !parts.contains("..") else { throw LibraryError.invalidRoot(sub) }
            startRelative = parts.joined(separator: "/")
        }

        // A root whose drive is unmounted or whose folder is gone is unavailable, not empty.
        // Marking its files missing here would be wrong, so change nothing.
        guard let path = location.resolve(fileSystem: fs),
              let rootMeta = try? fs.metadata(at: path), rootMeta.isDirectory, !rootMeta.isSymlink,
              fs.volume(containing: path)?.id == location.volumeID else {
            result.rootAvailable = false
            return result
        }
        rootPath = path
        return try walk(startRelative: startRelative)
    }

    private func walk(startRelative: String) throws -> ScanResult {
        start = library.scanClock.next(after: options.now())
        mayHaveCandidates = try library.database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM file WHERE lastSeen < ?)", arguments: [start]) ?? false
        }

        // Nothing under an excluded path is ever indexed, whatever started the scan.
        if !startRelative.isEmpty {
            var prefix = ""
            for component in startRelative.split(separator: "/") {
                prefix += (prefix.isEmpty ? "" : "/") + component
                if exclusions.excludes(name: String(component), relativePath: prefix) { return result }
            }
        }

        var skipped: [String] = []
        var buffer: [PendingEntry] = []
        let startPath = startRelative.isEmpty ? rootPath : rootPath + "/" + startRelative

        func flush() throws {
            guard !buffer.isEmpty else { return }
            let batch = buffer
            buffer.removeAll(keepingCapacity: true)
            try library.database.write { db in try self.write(batch, in: db) }
        }

        // The starting point (the root, a subtree directory, or a single file) is the first work item.
        var stack: [(path: String, relative: String)] = []
        do {
            let meta = try fs.metadata(at: startPath)
            if meta.isSymlink {
                // Not indexed, not followed.
            } else if meta.isDirectory {
                if meta.isDataless || meta.volumeID != rootVolumeID { skipped.append(startRelative) }
                else { stack.append((startPath, startRelative)) }
            } else {
                let name = (startPath as NSString).lastPathComponent
                if !Exclusions.isIgnoredFileName(name) {
                    buffer.append(PendingEntry(relativePath: startRelative, name: name, path: startPath, meta: meta))
                }
            }
        } catch FileSystemError.notFound {
            // Gone: its rows become missing below.
        } catch {
            skipped.append(startRelative)
        }

        while let (dir, relDir) = stack.popLast() {
            try Task.checkCancellation()
            let names: [String]
            do { names = try fs.contentsOfDirectory(at: dir) }
            catch FileSystemError.notFound { continue }
            catch { skipped.append(relDir); continue }

            for name in names {
                if Exclusions.isIgnoredFileName(name) { continue }
                let path = dir + "/" + name
                let rel = relDir.isEmpty ? name : relDir + "/" + name
                if exclusions.excludes(name: name, relativePath: rel) { continue }
                let meta: FileMetadata
                do { meta = try fs.metadata(at: path) }
                catch FileSystemError.notFound { continue }
                catch { skipped.append(rel); continue }
                if meta.isSymlink { continue }
                if meta.isDirectory {
                    // Listing a dataless directory could download it; another volume is not this root's.
                    if meta.isDataless || meta.volumeID != rootVolumeID { skipped.append(rel) }
                    else { stack.append((path, rel)) }
                } else {
                    buffer.append(PendingEntry(relativePath: rel, name: name, path: path, meta: meta))
                    if buffer.count >= options.batchSize { try flush() }
                }
            }
        }
        try flush()

        result.skippedDirectories = skipped.sorted()
        try markAndRemoveMissing(startRelative: startRelative, skipped: skipped)
        return result
    }

    // MARK: Writing a batch

    private func write(_ batch: [PendingEntry], in db: Database) throws {
        var existing: [String: ExistingRow] = [:]
        for chunk in batch.chunked(into: 500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var args: [DatabaseValueConvertible] = [rootID]
            args.append(contentsOf: chunk.map(\.relativePath))
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, relativePath, size, modified, fileID, volumeID, icloudStatus
                FROM file WHERE rootID = ? AND relativePath IN (\(marks))
                """, arguments: StatementArguments(args))
            for row in rows {
                existing[row["relativePath"]] = ExistingRow(
                    id: row["id"], size: row["size"], modified: row["modified"],
                    fileID: row["fileID"], volumeID: row["volumeID"], icloudStatus: row["icloudStatus"])
            }
        }

        var unchangedIDs: [Int64] = []
        for entry in batch {
            let status = entry.meta.isDataless ? "dataless" : "local"
            let kind = classifier.kind(forFileName: entry.name).rawValue
            let fileID = Int64(bitPattern: entry.meta.fileID)

            if let row = existing[entry.relativePath] {
                let sameContent = row.size == entry.meta.size
                    && abs(row.modified.timeIntervalSince(entry.meta.modified)) < 0.002
                    && row.fileID == fileID && row.volumeID == entry.meta.volumeID
                if sameContent && row.icloudStatus == status {
                    unchangedIDs.append(row.id)
                    result.unchanged += 1
                } else {
                    try updateRow(db, id: row.id, entry: entry, kind: kind, status: status, fileID: fileID, clearHashes: !sameContent)
                    result.updated += 1
                }
                continue
            }

            if mayHaveCandidates, let moved = try rematch(db, entry: entry) {
                try db.execute(sql: """
                    UPDATE file SET rootID = ?, relativePath = ?, volumeID = ?, fileID = ?, size = ?, modified = ?, kind = ?,
                        icloudStatus = ?, lastSeen = ?, missingSince = NULL,
                        partialHash = CASE WHEN ? THEN partialHash END, fullHash = CASE WHEN ? THEN fullHash END
                    WHERE id = ?
                    """, arguments: [rootID, entry.relativePath, entry.meta.volumeID, fileID, entry.meta.size, entry.meta.modified,
                                     kind, status, start, moved.contentUnchanged, moved.contentUnchanged, moved.id])
                result.moved += 1
                continue
            }

            try db.execute(sql: """
                INSERT INTO file (rootID, relativePath, volumeID, fileID, size, modified, kind, icloudStatus, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [rootID, entry.relativePath, entry.meta.volumeID, fileID, entry.meta.size, entry.meta.modified,
                                 kind, status, start, start])
            result.added += 1
        }

        for chunk in unchangedIDs.chunked(into: 500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var args: [DatabaseValueConvertible] = [start]
            args.append(contentsOf: chunk.map { $0 as DatabaseValueConvertible })
            // A file that reappeared at its old path is no longer missing.
            try db.execute(sql: "UPDATE file SET lastSeen = ?, missingSince = NULL WHERE id IN (\(marks))",
                           arguments: StatementArguments(args))
        }
    }

    private func updateRow(_ db: Database, id: Int64, entry: PendingEntry, kind: String, status: String,
                           fileID: Int64, clearHashes: Bool) throws {
        try db.execute(sql: """
            UPDATE file SET volumeID = ?, fileID = ?, size = ?, modified = ?, kind = ?, icloudStatus = ?,
                lastSeen = ?, missingSince = NULL,
                partialHash = CASE WHEN ? THEN NULL ELSE partialHash END,
                fullHash = CASE WHEN ? THEN NULL ELSE fullHash END
            WHERE id = ?
            """, arguments: [entry.meta.volumeID, fileID, entry.meta.size, entry.meta.modified, kind, status, start,
                             clearHashes, clearHashes, id])
    }

    // MARK: Re-matching moved and renamed files

    private struct Match { var id: Int64; var contentUnchanged: Bool }

    /// A row not seen in this scan whose old path no longer exists, matching the new file by volume and
    /// file ID first, then by content hash (ADR 0001). Candidates on an unmounted drive are ignored:
    /// they have not vanished, we just cannot see them.
    private func rematch(_ db: Database, entry: PendingEntry) throws -> Match? {
        let fileID = Int64(bitPattern: entry.meta.fileID)

        let byIdentity = try Row.fetchAll(db, sql: """
            SELECT id, rootID, relativePath, size, modified FROM file
            WHERE volumeID = ? AND fileID = ? AND lastSeen < ?
            """, arguments: [entry.meta.volumeID, fileID, start])
        for row in byIdentity where hasVanished(db, rootID: row["rootID"], relativePath: row["relativePath"]) {
            let unchanged = (row["size"] as Int64) == entry.meta.size
                && abs((row["modified"] as Date).timeIntervalSince(entry.meta.modified)) < 0.002
            return Match(id: row["id"], contentUnchanged: unchanged)
        }

        // By content: only for readable local files with candidates of the same size that already have a hash.
        guard !entry.meta.isDataless, entry.meta.size > 0 else { return nil }
        let bySize = try Row.fetchAll(db, sql: """
            SELECT id, rootID, relativePath, fullHash FROM file
            WHERE size = ? AND fullHash IS NOT NULL AND lastSeen < ?
            """, arguments: [entry.meta.size, start])
        let vanished = bySize.filter { hasVanished(db, rootID: $0["rootID"], relativePath: $0["relativePath"]) }
        guard !vanished.isEmpty, let hash = ContentHash.full(of: entry.path, fileSystem: fs) else { return nil }
        let same = vanished.filter { ($0["fullHash"] as Data) == hash }
        // Several vanished copies with this content: which one moved is a guess, so do not guess.
        guard same.count == 1 else { return nil }
        return Match(id: same[0]["id"], contentUnchanged: true)
    }

    private func hasVanished(_ db: Database, rootID candidateRoot: Int64, relativePath: String) -> Bool {
        guard let base = rootPathForCandidate(db, candidateRoot) else { return false }
        return !fs.exists(base + "/" + relativePath)
    }

    private func rootPathForCandidate(_ db: Database, _ id: Int64) -> String? {
        if let cached = candidateRootPaths[id] { return cached }
        var resolved: String?
        if id == rootID {
            resolved = rootPath
        } else if let row = try? Row.fetchOne(db, sql: "SELECT volumeID, relativePath FROM root WHERE id = ?", arguments: [id]) {
            resolved = VolumeLocation(volumeID: row["volumeID"], relativePath: row["relativePath"]).resolve(fileSystem: fs)
        }
        candidateRootPaths[id] = .some(resolved)
        return resolved
    }

    // MARK: Missing files

    private func markAndRemoveMissing(startRelative: String, skipped: [String]) throws {
        // Too many unreadable directories to express in one statement: leave missing-file bookkeeping alone.
        guard skipped.count <= 400 else { result.missingCheckSkipped = true; return }

        var unseen = "rootID = ? AND lastSeen < ?"
        var args: [DatabaseValueConvertible] = [rootID, start]
        if !startRelative.isEmpty {
            let prefix = startRelative + "/"
            unseen += " AND (relativePath = ? OR substr(relativePath, 1, ?) = ?)"
            args += [startRelative, prefix.unicodeScalars.count, prefix]
        }
        // Rows under a directory we did not read are unknown, not missing. Prefix match is
        // case-sensitive (substr, not LIKE) so a case-sensitive volume is not misread.
        for dir in skipped {
            if dir.isEmpty { result.missingCheckSkipped = true; return }
            let prefix = dir + "/"
            unseen += " AND NOT (relativePath = ? OR substr(relativePath, 1, ?) = ?)"
            args += [dir, prefix.unicodeScalars.count, prefix]
        }

        let cutoff = start.addingTimeInterval(-options.gracePeriod)
        try library.database.write { db in
            try db.execute(sql: "UPDATE file SET missingSince = ? WHERE \(unseen) AND missingSince IS NULL",
                           arguments: StatementArguments([start] + args))
            result.markedMissing = db.changesCount
            try db.execute(sql: "DELETE FROM file WHERE \(unseen) AND missingSince IS NOT NULL AND missingSince < ?",
                           arguments: StatementArguments(args + [cutoff]))
            result.removed = db.changesCount
        }
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}

/// Hands out scan start times that strictly increase. Rows are marked seen with the scan's start
/// time (stored to the millisecond), so two scans in the same millisecond, as event-driven rescans
/// can be, must not share one or the second would treat the first's rows as already seen.
final class ScanClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func next(after now: Date) -> Date {
        lock.withLock {
            let value = max(now, last.addingTimeInterval(0.002))
            last = value
            return value
        }
    }
}
