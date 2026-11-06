import Foundation
import GRDB

public struct ReleaseResult: Equatable, Sendable {
    public var released = 0
    public var failures: [String] = []
}

/// A standardization original waiting in the holdback.
public struct HeldOriginal: Equatable, Sendable {
    public var operationID: Int64
    public var batch: String
    public var fileID: Int64?
    /// Where the resized file lives.
    public var path: String
    public var holdbackPath: String
    public var originalHash: Data?
    public var createdAt: Date
    /// When it goes to the Trash if nobody releases it earlier.
    public var holdbackUntil: Date?
}

/// Holdback retention and release (ADR 0006). An original leaves the holdback only for the Trash, never by deletion,
/// and Miles' undo for that operation ends there.
extension Library {
    /// Originals still in the holdback, oldest first.
    public func heldOriginals() throws -> [HeldOriginal] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, batch, fileID, fromPath, holdbackPath, originalHash, createdAt, holdbackUntil FROM operation
                WHERE kind = 'resize' AND state = 'done' AND releasedAt IS NULL AND undoneAt IS NULL AND holdbackPath IS NOT NULL
                ORDER BY id
                """).map {
                HeldOriginal(operationID: $0["id"], batch: $0["batch"], fileID: $0["fileID"], path: $0["fromPath"],
                             holdbackPath: $0["holdbackPath"], originalHash: $0["originalHash"], createdAt: $0["createdAt"],
                             holdbackUntil: $0["holdbackUntil"])
            }
        }
    }

    /// Sends held originals to the Trash early: a whole batch, chosen operations, or (with neither) all of them.
    /// Always a user choice. After this the Trash is the last recovery point.
    @discardableResult
    public func releaseOriginals(batch: String? = nil, operationIDs: [Int64]? = nil, fileSystem fs: FileSystem,
                                 now: Date = Date()) throws -> ReleaseResult {
        let chosen = operationIDs.map(Set.init)
        return try release(try heldOriginals().filter { (batch == nil || $0.batch == batch) && (chosen?.contains($0.operationID) ?? true) },
                           fileSystem: fs, now: now)
    }

    /// Sends originals past their retention to the Trash. Safe to run in the background: it only touches
    /// Miles' own holdback copies, and only once the retention the user configured has passed.
    @discardableResult
    public func releaseExpiredHoldbacks(fileSystem fs: FileSystem, now: Date = Date()) throws -> ReleaseResult {
        try release(try heldOriginals().filter { ($0.holdbackUntil ?? .distantFuture) <= now }, fileSystem: fs, now: now)
    }

    private func release(_ held: [HeldOriginal], fileSystem fs: FileSystem, now: Date) throws -> ReleaseResult {
        var result = ReleaseResult()
        for item in held {
            var note: String?
            var location = item.holdbackPath
            if fs.exists(item.holdbackPath) {
                do { location = try fs.trash(at: item.holdbackPath) }
                catch { result.failures.append("\(item.holdbackPath): \(error.localizedDescription)"); continue }
            } else {
                note = "the original was no longer in the holdback"
            }
            try database.write { db in
                try db.execute(sql: "UPDATE operation SET releasedAt = ?, holdbackPath = ?, error = COALESCE(?, error) WHERE id = ?",
                               arguments: [now, location, note, item.operationID])
            }
            if let note { result.failures.append("\(item.path): \(note)") } else { result.released += 1 }
            removeIfEmpty((item.holdbackPath as NSString).deletingLastPathComponent, fileSystem: fs)
        }
        return result
    }

    /// Tidies the per-batch holdback folder once it has nothing in it. Miles made it, so Miles may remove it.
    private func removeIfEmpty(_ directory: String, fileSystem fs: FileSystem) {
        if let entries = try? fs.contentsOfDirectory(at: directory), entries.isEmpty { try? fs.removeMilesOwnedFile(at: directory) }
    }

    // MARK: Undo

    func setOperationState(_ id: Int64, _ state: OperationState, now: Date) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE operation SET state = ?, undoneAt = CASE WHEN ? = 'undone' THEN ? END WHERE id = ?",
                           arguments: [state.rawValue, state.rawValue, now, id])
        }
    }

    /// Puts the original back. The resized file goes to the Trash (never deleted) and only if it is still as
    /// Miles left it; the original comes back with its own identity.
    func undoResize(_ op: OperationRecord, fileSystem fs: FileSystem, now: Date) throws {
        guard op.releasedAt == nil else { throw OperationError.refused("the original of \(op.fromPath) was released to the Trash; that is the last recovery point") }
        guard let held = op.holdbackPath, fs.exists(held) else { throw OperationError.refused("the original of \(op.fromPath) is no longer in the holdback") }
        guard fs.exists(op.fromPath), let hash = op.resultHash, ContentHash.full(of: op.fromPath, fileSystem: fs) == hash else {
            throw OperationError.refused("\(op.fromPath) was changed after it was standardized; not replacing it")
        }
        try setOperationState(op.id, .undoing, now: now)
        var trashed: String?
        do {
            trashed = try fs.trash(at: op.fromPath)
            try fs.move(from: held, to: op.fromPath)
        } catch {
            if let trashed, !fs.exists(op.fromPath) { try? fs.move(from: trashed, to: op.fromPath) }
            try? setOperationState(op.id, .done, now: now)
            throw OperationError.refused("could not restore the original of \(op.fromPath): \(error.localizedDescription)")
        }
        try setOperationState(op.id, .undone, now: now)
        try restoreOriginalRow(op, fileSystem: fs, now: now)
        removeIfEmpty((held as NSString).deletingLastPathComponent, fileSystem: fs)
    }

    /// The file row goes back to describing the original, and its link to it is gone.
    func restoreOriginalRow(_ op: OperationRecord, fileSystem fs: FileSystem, now: Date) throws {
        guard let fileID = op.fileID else { return }
        if let hash = op.originalHash { try adoptContent(fileID: fileID, path: op.fromPath, fullHash: hash, fileSystem: fs, now: now) }
        try database.write { db in try db.execute(sql: "DELETE FROM file_link WHERE operationID = ?", arguments: [op.id]) }
    }

    // MARK: Crash recovery

    /// Settles a resize a crash left half-way, by looking at the disk. Returns the state and a note.
    func settleResize(_ op: OperationRecord, fileSystem fs: FileSystem, now: Date) throws -> (OperationState, String?) {
        let held = op.holdbackPath
        let heldThere = held.map { fs.exists($0) } ?? false
        let liveThere = fs.exists(op.fromPath)
        if let held { try? fs.removeMilesOwnedFile(at: (held as NSString).deletingLastPathComponent + "/\(op.fileID.map(String.init) ?? "0").new") }
        switch op.state {
        case .pending:
            if heldThere, liveThere {
                // The swap finished; only the bookkeeping is missing.
                let hash = ContentHash.full(of: op.fromPath, fileSystem: fs)
                try finishOperation(op.id, state: .done, resultHash: hash)
                if let fileID = op.fileID, let hash {
                    try adoptContent(fileID: fileID, path: op.fromPath, fullHash: hash, fileSystem: fs, now: now)
                    try database.write { db in
                        let has = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM file_link WHERE operationID = ?)", arguments: [op.id]) ?? false
                        if !has, let original = op.originalHash {
                            try db.execute(sql: "INSERT INTO file_link (derivedFileID, originalHash, originalSize, kind, operationID, createdAt) VALUES (?, ?, 0, 'resize', ?, ?)",
                                           arguments: [fileID, original, op.id, now])
                        }
                    }
                }
                return (.done, nil)
            }
            if heldThere, !liveThere, let held {
                try? fs.move(from: held, to: op.fromPath)
                if let fileID = op.fileID { try syncFileRow(id: fileID, path: op.fromPath, fileSystem: fs, now: now) }
                return (.failed, "interrupted; the original was put back")
            }
            return (.failed, "interrupted before it ran; the file was not touched")
        case .undoing:
            if heldThere, !liveThere, let held {
                try fs.move(from: held, to: op.fromPath)
                try restoreOriginalRow(op, fileSystem: fs, now: now)
                return (.undone, nil)
            }
            if !heldThere, liveThere { try restoreOriginalRow(op, fileSystem: fs, now: now); return (.undone, nil) }
            return (.done, nil)
        default:
            return (op.state, nil)
        }
    }
}
