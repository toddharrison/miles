import Foundation
import GRDB
import CryptoKit

/// An image standardization rule for a managed root (ADR 0006). Constraints combine; at least one of
/// `maxBytes` and `maxLongEdge` is needed. A file that cannot meet the rule without going below
/// `qualityFloor` is skipped and reported, never degraded further.
public struct StandardizationRule: Codable, Equatable, Sendable {
    public var maxBytes: Int64?
    public var maxLongEdge: Int?
    /// JPEG/HEIC quality (0 to 1) Miles will not go below. 0.6 unless set.
    public var qualityFloor: Double
    /// Metadata is preserved by default. This drops GPS data from files that are re-encoded.
    public var stripLocation: Bool

    public init(maxBytes: Int64? = nil, maxLongEdge: Int? = nil, qualityFloor: Double = 0.6, stripLocation: Bool = false) {
        self.maxBytes = maxBytes; self.maxLongEdge = maxLongEdge
        self.qualityFloor = qualityFloor; self.stripLocation = stripLocation
    }

    public var isValid: Bool {
        (maxBytes != nil || maxLongEdge != nil) && (maxBytes ?? 1) > 0 && (maxLongEdge ?? 1) > 0 && (0.1...1.0).contains(qualityFloor)
    }

    static func decode(_ json: String?) -> StandardizationRule? {
        json?.data(using: .utf8).flatMap { try? JSONDecoder().decode(StandardizationRule.self, from: $0) }
    }

    var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }

    /// Quality steps to try, best first. Starts at 0.85 (or the floor, if higher) and never goes below the floor.
    var qualityLadder: [Double] {
        var steps: [Double] = []
        var q = 0.85
        while q > qualityFloor + 0.0001 { steps.append((q * 100).rounded() / 100); q -= 0.05 }
        steps.append(qualityFloor)
        return steps
    }

    func isMet(bytes: Int64, longEdge: Int) -> Bool {
        (maxBytes.map { bytes <= $0 } ?? true) && (maxLongEdge.map { longEdge <= $0 } ?? true)
    }
}

/// Where originals wait after a run. One folder per volume so the move is a same-volume rename that keeps the
/// file's identity and costs no copy. Outside every root, and never backed up (ADR 0006).
public struct HoldbackLocator: Sendable {
    public var directory: @Sendable (VolumeInfo) -> String
    public init(_ directory: @escaping @Sendable (VolumeInfo) -> String) { self.directory = directory }

    /// `<mount>/.miles-holdback/<library>` on a drive; under Application Support for the boot volume.
    public static func standard(libraryID: UUID, home: String = NSHomeDirectory()) -> HoldbackLocator {
        HoldbackLocator { volume in
            volume.mountPoint == "/"
                ? "\(home)/Library/Application Support/Miles/Holdback/\(libraryID.uuidString)"
                : "\(volume.mountPoint)/.miles-holdback/\(libraryID.uuidString)"
        }
    }
}

/// One file in a standardization preview.
public struct PlannedResize: Equatable, Sendable {
    public var fileID: Int64
    public var path: String
    public var oldBytes: Int64
    public var newBytes: Int64
    public var oldWidth: Int, oldHeight: Int
    public var newWidth: Int, newHeight: Int
    public var quality: Double
    public var maxLongEdge: Int?
    /// Hash of the content that was previewed. Apply refuses a file that no longer has it.
    public var originalHash: Data

    public var summary: String {
        let size = "\(oldBytes) -> \(newBytes) bytes"
        let dims = (oldWidth, oldHeight) == (newWidth, newHeight) ? "\(newWidth)x\(newHeight)" : "\(oldWidth)x\(oldHeight) -> \(newWidth)x\(newHeight)"
        return "\(size), \(dims), quality \(String(format: "%.2f", quality))"
    }
}

/// The preview of a standardization run (ADR 0006). Nothing has changed when you hold one. Only
/// `planStandardization` makes one and only `applyStandardization` runs it.
public struct StandardizationPlan: Sendable {
    public let rootID: Int64
    public let rule: StandardizationRule
    public let steps: [PlannedResize]
    /// Files the rule would change but cannot, with the reason. They are left alone.
    public let skipped: [(fileID: Int64, path: String, reason: String)]
    /// Images that already meet the rule (not listed one by one).
    public let alreadyCompliant: Int
    public let holdbackDays: Int
    /// The root's default is to send originals to the Trash right after the run. The preview must say so.
    public let releasesImmediately: Bool

    public var bytesFreed: Int64 { steps.reduce(0) { $0 + $1.oldBytes - $1.newBytes } }
    public var isEmpty: Bool { steps.isEmpty }
}

public struct StandardizationOutcome: Sendable {
    /// The journal batch to pass to `undoBatch` (until the originals are released); nil when nothing changed.
    public var batch: String?
    public var resizedFileIDs: [Int64] = []
    public var failures: [(fileID: Int64, reason: String)] = []
    public var bytesFreed: Int64 = 0
    /// Originals sent to the Trash because the root releases immediately.
    public var released = 0
}

extension Library {
    func managedRoot(_ rootID: Int64) throws -> RootRecord {
        guard let root = try roots().first(where: { $0.id == rootID }) else { throw LibraryError.invalidRoot("root \(rootID)") }
        guard root.isManaged else { throw OperationError.refused("root \(rootID) is not managed; managed mode is opt-in per root") }
        return root
    }

    // MARK: Settings

    /// Opt in or out of managed mode for one root. Never applied to a parent or child root (roots cannot overlap).
    public func setManaged(_ managed: Bool, forRoot rootID: Int64) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE root SET mode = ? WHERE id = ?", arguments: [managed ? "managed" : "unmanaged", rootID])
            guard db.changesCount == 1 else { throw LibraryError.invalidRoot("root \(rootID)") }
        }
    }

    /// Sets or clears (nil) a root's standardization rule. Needs managed mode.
    public func setStandardizationRule(_ rule: StandardizationRule?, forRoot rootID: Int64) throws {
        _ = try managedRoot(rootID)
        if let rule, !rule.isValid { throw OperationError.refused("a rule needs a maximum size or long edge, and a quality floor between 0.1 and 1") }
        try database.write { db in
            try db.execute(sql: "UPDATE root SET standardization = ? WHERE id = ?", arguments: [rule?.json, rootID])
        }
    }

    public func setHoldback(days: Int? = nil, releaseImmediately: Bool? = nil, forRoot rootID: Int64) throws {
        if let days, days < 0 { throw OperationError.refused("retention cannot be negative") }
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM root WHERE id = ?)", arguments: [rootID]) == true else {
                throw LibraryError.invalidRoot("root \(rootID)")
            }
            if let days { try db.execute(sql: "UPDATE root SET holdbackDays = ? WHERE id = ?", arguments: [days, rootID]) }
            if let releaseImmediately { try db.execute(sql: "UPDATE root SET releaseImmediately = ? WHERE id = ?", arguments: [releaseImmediately, rootID]) }
        }
    }

    // MARK: Preview

    /// Previews standardizing a managed root's images. Reads image content (local files only, never a
    /// download) to find what each file would become; changes nothing. `fileIDs` limits it to some files.
    public func planStandardization(rootID: Int64, fileIDs: [Int64]? = nil, fileSystem fs: FileSystem,
                                    transcoder: ImageTranscoder) throws -> StandardizationPlan {
        let root = try managedRoot(rootID)
        guard let rule = root.standardization else { throw OperationError.refused("root \(rootID) has no standardization rule; nothing runs without one") }
        guard root.location.resolve(fileSystem: fs) != nil else { throw OperationError.refused("the drive holding root \(rootID) is not available") }

        var steps: [PlannedResize] = []
        var skipped: [(fileID: Int64, path: String, reason: String)] = []
        var compliant = 0
        let wanted = fileIDs.map(Set.init)
        for file in try files(rootID: rootID) where file.kind == FileKind.image.rawValue && wanted?.contains(file.id) != false {
            guard let path = try? absolutePath(of: file, fileSystem: fs) else { continue }
            guard file.icloudStatus == "local", (try? fs.metadata(at: path))?.isDataless != true else {
                skipped.append((file.id, path, "not downloaded (Miles never downloads files to act on them)")); continue
            }
            guard let live = try? fs.metadata(at: path), !live.isDirectory, !live.isSymlink else {
                skipped.append((file.id, path, "no longer at its indexed path; scan again")); continue
            }
            guard live.size == file.size, abs(live.modified.timeIntervalSince(file.modified)) < 0.01 else {
                skipped.append((file.id, path, "changed since it was indexed; scan again")); continue
            }
            guard let data = try? fs.readFile(at: path), let info = transcoder.inspect(data) else {
                skipped.append((file.id, path, "not a readable image")); continue
            }
            if info.isRaw { skipped.append((file.id, path, "RAW files are not re-encoded")); continue }
            if info.frameCount > 1 { skipped.append((file.id, path, "animated or multi-image files are not re-encoded")); continue }
            guard info.format != nil else { skipped.append((file.id, path, "only JPEG and HEIC are re-encoded")); continue }
            if rule.isMet(bytes: Int64(data.count), longEdge: info.longEdge) { compliant += 1; continue }

            let edge = rule.maxLongEdge.flatMap { info.longEdge > $0 ? $0 : nil }
            var chosen: (quality: Double, out: Data, info: ImageInfo)?
            for quality in rule.qualityLadder {
                guard let out = try? transcoder.encode(data, maxLongEdge: edge, quality: quality, stripLocation: rule.stripLocation),
                      let outInfo = transcoder.inspect(out) else { break }
                if rule.isMet(bytes: Int64(out.count), longEdge: outInfo.longEdge) { chosen = (quality, out, outInfo); break }
            }
            guard let chosen else {
                skipped.append((file.id, path, "cannot meet the rule above the quality floor of \(rule.qualityFloor)")); continue
            }
            guard chosen.out.count < data.count else {
                skipped.append((file.id, path, "re-encoding would not make it smaller")); continue
            }
            steps.append(PlannedResize(fileID: file.id, path: path, oldBytes: Int64(data.count), newBytes: Int64(chosen.out.count),
                                       oldWidth: info.width, oldHeight: info.height, newWidth: chosen.info.width, newHeight: chosen.info.height,
                                       quality: chosen.quality, maxLongEdge: edge, originalHash: Data(SHA256.hash(data: data))))
        }
        return StandardizationPlan(rootID: rootID, rule: rule, steps: steps, skipped: skipped, alreadyCompliant: compliant,
                                   holdbackDays: root.holdbackDays, releasesImmediately: root.releaseImmediately)
    }

    // MARK: Apply

    /// Runs a previewed plan. Each file is verified again just before it is touched (local, unchanged, same
    /// content as previewed), re-encoded, and swapped in with its original moved to the holdback. Each file
    /// succeeds or fails alone. Everything is journaled first and undoable until the original is released.
    public func applyStandardization(_ plan: StandardizationPlan, fileSystem fs: FileSystem, transcoder: ImageTranscoder,
                                     holdback: HoldbackLocator, now: Date = Date()) throws -> StandardizationOutcome {
        var outcome = StandardizationOutcome()
        let root = try managedRoot(plan.rootID)
        guard root.standardization == plan.rule else { throw OperationError.refused("the rule changed since the preview; preview it again") }
        guard !plan.steps.isEmpty else { return outcome }
        if plan.steps.count > 1 { _ = try backupBeforeBulkOperation(now: now) }   // refuses to go on if the backup fails

        let batch = UUID().uuidString
        let until = plan.releasesImmediately ? now : now.addingTimeInterval(TimeInterval(plan.holdbackDays) * 86_400)
        for step in plan.steps {
            do {
                guard try file(id: step.fileID)?.rootID == plan.rootID else { throw OperationError.refused("file \(step.fileID) is not in this root") }
                try performResize(step, rule: plan.rule, batch: batch, holdback: holdback, holdbackUntil: until,
                                  fileSystem: fs, transcoder: transcoder, now: now)
                outcome.resizedFileIDs.append(step.fileID)
                outcome.bytesFreed += step.oldBytes - step.newBytes
            } catch {
                outcome.failures.append((step.fileID, error.localizedDescription))
            }
        }
        if try !operations(batch: batch, limit: 1).isEmpty { outcome.batch = batch }
        if plan.releasesImmediately, outcome.batch != nil {
            outcome.released = try releaseOriginals(batch: batch, fileSystem: fs, now: now).released
        }
        try refreshDuplicateGroups()
        return outcome
    }

    func performResize(_ step: PlannedResize, rule: StandardizationRule, batch: String, holdback: HoldbackLocator, holdbackUntil: Date,
                       fileSystem fs: FileSystem, transcoder: ImageTranscoder, now: Date) throws {
        let file = try verifiedFile(id: step.fileID, expectedHash: step.originalHash, fileSystem: fs)
        guard let volume = fs.volume(containing: file.path) else { throw OperationError.refused("the drive holding \(file.path) is not available") }
        let data = try fs.readFile(at: file.path)
        let out: Data
        do { out = try transcoder.encode(data, maxLongEdge: step.maxLongEdge, quality: step.quality, stripLocation: rule.stripLocation) }
        catch { throw OperationError.refused("could not re-encode \(file.path): \(error.localizedDescription)") }
        guard let outInfo = transcoder.inspect(out), rule.isMet(bytes: Int64(out.count), longEdge: outInfo.longEdge), out.count < data.count else {
            throw OperationError.refused("the re-encoded \(file.path) no longer meets the rule; preview it again")
        }

        let directory = holdback.directory(volume) + "/" + batch
        let name = (file.path as NSString).lastPathComponent
        let held = "\(directory)/\(file.id)-\(name)", temp = "\(directory)/\(file.id).new"
        try fs.createDirectory(at: directory)
        guard fs.volume(containing: directory)?.id == volume.id else {
            throw OperationError.refused("the holdback folder is not on the same volume as \(file.path)")
        }
        let opID = try insertOperation(kind: .resize, batch: batch, fileID: file.id, from: file.path, to: file.path, hash: file.hash,
                                       holdbackPath: held, holdbackUntil: holdbackUntil, now: now)
        let resultHash = Data(SHA256.hash(data: out))
        do {
            try fs.createFileExclusively(out, at: temp)
            try fs.move(from: file.path, to: held)                  // the original is kept, not deleted
            do { try fs.move(from: temp, to: file.path) }
            catch { try? fs.move(from: held, to: file.path); throw error }
        } catch {
            try? fs.removeMilesOwnedFile(at: temp)
            try? finishOperation(opID, state: .failed, error: error.localizedDescription)
            throw OperationError.refused("could not replace \(file.path): \(error.localizedDescription)")
        }
        try finishOperation(opID, state: .done, resultHash: resultHash)
        try adoptContent(fileID: file.id, path: file.path, fullHash: resultHash, fileSystem: fs, now: now)
        try database.write { db in
            try db.execute(sql: "INSERT INTO file_link (derivedFileID, originalHash, originalSize, kind, operationID, createdAt) VALUES (?, ?, ?, 'resize', ?, ?)",
                           arguments: [file.id, file.hash, file.size, opID, now])
        }
    }

    /// Updates a file row after its content was swapped: metadata from the disk, hashes known from the swap.
    /// The row keeps its identity, so tags and everything else attached to it stay.
    func adoptContent(fileID: Int64, path: String, fullHash: Data, fileSystem fs: FileSystem, now: Date) throws {
        try syncFileRow(id: fileID, path: path, fileSystem: fs, now: now)
        let size = try database.read { try Int64.fetchOne($0, sql: "SELECT size FROM file WHERE id = ?", arguments: [fileID]) } ?? 0
        let partial = ContentHash.partial(of: path, size: size, fileSystem: fs)
        try database.write { db in
            try db.execute(sql: "UPDATE file SET partialHash = ?, fullHash = ? WHERE id = ?", arguments: [partial, fullHash, fileID])
        }
    }

    // MARK: Links

    /// The originals a file was made from. They live in the holdback (or the Trash), not in any root.
    public func originalsOf(fileID: Int64) throws -> [(hash: Data, size: Int64)] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT originalHash, originalSize FROM file_link WHERE derivedFileID = ? ORDER BY id", arguments: [fileID])
                .map { ($0["originalHash"], $0["originalSize"]) }
        }
    }

    /// True if one file is a derivative of content the other has. Duplicate reporting never pairs such files
    /// (ADR 0006): exact groups need equal hashes, which a derivative never has, and the near-duplicate pass in
    /// Step 8 must use this to leave a file and its own resize out of each other's groups.
    public func areLinked(_ a: Int64, _ b: Int64) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM file_link l JOIN file o ON o.fullHash = l.originalHash
                              WHERE (l.derivedFileID = ? AND o.id = ?) OR (l.derivedFileID = ? AND o.id = ?))
                """, arguments: [a, b, b, a]) ?? false
        }
    }
}
