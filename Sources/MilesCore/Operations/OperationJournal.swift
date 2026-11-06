import Foundation
import GRDB

public enum OperationKind: String, Sendable {
    case trash, clone, move, rename, resize
}

public enum OperationState: String, Sendable {
    /// Written before the action runs. Seen after a crash, it means the outcome is unknown until checked.
    case pending
    case done, failed
    /// Written before an undo runs, for the same reason.
    case undoing
    case undone
}

public struct OperationRecord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var batch: String
    public var kind: OperationKind
    public var fileID: Int64?
    public var fromPath: String
    public var toPath: String
    public var holdbackPath: String?
    public var originalHash: Data?
    public var state: OperationState
    public var error: String?
    public var createdAt: Date
    public var undoneAt: Date?
    public var releasedAt: Date?
}

/// A summary of one user action, for "undo the last thing".
public struct OperationBatchInfo: Equatable, Sendable {
    public var batch: String
    public var createdAt: Date
    public var operations: Int
    public var done: Int
    public var undone: Int
    public var canUndo: Bool { done > 0 }
}

public enum OperationError: Error, Equatable, LocalizedError, Sendable {
    /// Nothing was changed. The message says why.
    case refused(String)
    public var errorDescription: String? {
        switch self { case .refused(let why): why }
    }
}

public struct UndoResult: Equatable, Sendable {
    public var undone = 0
    /// Why the undo stopped before reversing everything, if it did. Earlier steps stay undone.
    public var stoppedBecause: String?
}

/// The operation journal (ADR 0004). `operation` is the only way Miles changes a user's files: a row is
/// written before every action runs, and undo is driven from it. Only user-approved plans reach this code
/// (`applyResolution`), so unmanaged roots are never changed in the background (ADR 0007).
extension Library {
    static func operation(_ row: Row) -> OperationRecord {
        OperationRecord(id: row["id"], batch: row["batch"], kind: OperationKind(rawValue: row["kind"]) ?? .move, fileID: row["fileID"],
                        fromPath: row["fromPath"], toPath: row["toPath"], holdbackPath: row["holdbackPath"],
                        originalHash: row["originalHash"], state: OperationState(rawValue: row["state"]) ?? .failed,
                        error: row["error"], createdAt: row["createdAt"], undoneAt: row["undoneAt"], releasedAt: row["releasedAt"])
    }

    // MARK: Reading the journal

    public func operations(batch: String? = nil, limit: Int = 200) throws -> [OperationRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM operation \(batch == nil ? "" : "WHERE batch = ?") ORDER BY id DESC LIMIT ?",
                             arguments: batch.map { [$0, limit] } ?? [limit]).map(Self.operation).reversed()
        }
    }

    /// Recent actions, newest first.
    public func operationBatches(limit: Int = 20) throws -> [OperationBatchInfo] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT batch, MIN(createdAt) AS createdAt, COUNT(*) AS n,
                       SUM(state = 'done') AS done, SUM(state = 'undone') AS undone
                FROM operation GROUP BY batch ORDER BY MAX(id) DESC LIMIT ?
                """, arguments: [limit]).map {
                OperationBatchInfo(batch: $0["batch"], createdAt: $0["createdAt"], operations: $0["n"], done: $0["done"], undone: $0["undone"])
            }
        }
    }

    // MARK: Writing the journal

    private func insertOperation(kind: OperationKind, batch: String, fileID: Int64, from: String, to: String,
                                 hash: Data?, now: Date) throws -> Int64 {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO operation (batch, kind, fileID, fromPath, toPath, originalHash, state, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
                """, arguments: [batch, kind.rawValue, fileID, from, to, hash, now])
            return db.lastInsertedRowID
        }
    }

    private func finishOperation(_ id: Int64, state: OperationState, toPath: String? = nil, error: String? = nil) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE operation SET state = ?, toPath = COALESCE(?, toPath), error = ? WHERE id = ?",
                           arguments: [state.rawValue, toPath, error, id])
        }
    }

    // MARK: Checks before touching a file

    struct VerifiedFile {
        var id: Int64
        var path: String
        var hash: Data
        var volumeID: String
        var fileIdentity: Int64
        var size: Int64
    }

    /// A file may only be acted on while it is still the file that was indexed: local (never downloaded to be
    /// checked), at its path, with the indexed size and time, and with the full hash it was grouped by.
    /// The hash is read again, so a file edited since it was hashed is refused.
    func verifiedFile(id: Int64, fileSystem fs: FileSystem) throws -> VerifiedFile {
        guard let row = try database.read({ db in
            try Row.fetchOne(db, sql: "SELECT size, modified, icloudStatus, missingSince, fullHash, volumeID, fileID FROM file WHERE id = ?", arguments: [id])
        }), let file = try file(id: id) else { throw OperationError.refused("file \(id) is not indexed") }
        guard file.missingSince == nil else { throw OperationError.refused("\(file.relativePath) is missing") }
        guard (row["icloudStatus"] as String) == "local" else { throw OperationError.refused("\(file.relativePath) is not downloaded; Miles does not download files to act on them") }
        guard let hash: Data = row["fullHash"] else { throw OperationError.refused("\(file.relativePath) has no full hash yet") }
        let path: String
        do { path = try absolutePath(of: file, fileSystem: fs) }
        catch { throw OperationError.refused("the drive holding \(file.relativePath) is not available") }
        guard let live = try? fs.metadata(at: path), !live.isDirectory, !live.isSymlink else {
            throw OperationError.refused("\(path) is no longer there; scan again")
        }
        guard !live.isDataless else { throw OperationError.refused("\(path) is not downloaded; Miles does not download files to act on them") }
        guard live.size == file.size, abs(live.modified.timeIntervalSince(file.modified)) < 0.01 else {
            throw OperationError.refused("\(path) changed since it was indexed; scan again")
        }
        guard ContentHash.full(of: path, fileSystem: fs) == hash else { throw OperationError.refused("\(path) no longer matches its recorded content") }
        return VerifiedFile(id: id, path: path, hash: hash, volumeID: row["volumeID"], fileIdentity: row["fileID"], size: file.size)
    }

    /// Brings a file record in step with what is on disk after an operation or undo, keeping its identity
    /// (and so its tags). `missing` marks it missing without touching the disk record.
    func syncFileRow(id: Int64, path: String, fileSystem fs: FileSystem, now: Date) throws {
        try database.write { db in
            if let live = try? fs.metadata(at: path), !live.isDirectory {
                try db.execute(sql: """
                    UPDATE file SET volumeID = ?, fileID = ?, size = ?, modified = ?, missingSince = NULL, lastSeen = ? WHERE id = ?
                    """, arguments: [live.volumeID, Int64(bitPattern: live.fileID), live.size, live.modified, now, id])
            } else {
                try db.execute(sql: "UPDATE file SET missingSince = COALESCE(missingSince, ?) WHERE id = ?", arguments: [now, id])
            }
        }
    }

    // MARK: Actions

    /// Sends one verified file to the Trash. Journaled before it runs.
    func performTrash(fileID: Int64, batch: String, fileSystem fs: FileSystem, now: Date) throws -> OperationRecord {
        let file = try verifiedFile(id: fileID, fileSystem: fs)
        let opID = try insertOperation(kind: .trash, batch: batch, fileID: fileID, from: file.path, to: "", hash: file.hash, now: now)
        do {
            let trashed = try fs.trash(at: file.path)
            try finishOperation(opID, state: .done, toPath: trashed)
        } catch {
            try? finishOperation(opID, state: .failed, error: error.localizedDescription)
            throw OperationError.refused("could not move \(file.path) to the Trash: \(error.localizedDescription)")
        }
        try syncFileRow(id: fileID, path: file.path, fileSystem: fs, now: now)
        return try operations(batch: batch).last { $0.id == opID }!
    }

    /// Puts an APFS clone of the verified `keptID` at the path of `replacedID`, whose file has just been
    /// trashed in the same batch. If the clone cannot be made, the trash is undone at once.
    func performClone(keptID: Int64, replacedID: Int64, replacedPath: String, trashOperation: OperationRecord,
                      batch: String, fileSystem fs: FileSystem, now: Date) throws {
        let kept = try verifiedFile(id: keptID, fileSystem: fs)
        let opID = try insertOperation(kind: .clone, batch: batch, fileID: replacedID, from: kept.path, to: replacedPath, hash: kept.hash, now: now)
        do {
            guard let from = fs.volume(containing: kept.path), let to = fs.volume(containing: (replacedPath as NSString).deletingLastPathComponent), from.id == to.id else {
                throw FileSystemError.other("a clone needs both copies on the same volume")
            }
            try fs.clone(from: kept.path, to: replacedPath)
            try finishOperation(opID, state: .done)
        } catch {
            try? finishOperation(opID, state: .failed, error: error.localizedDescription)
            // The original is in the Trash and nothing replaced it: put it back.
            try? undo(operation: trashOperation, fileSystem: fs, now: now)
            throw OperationError.refused("could not clone onto \(replacedPath): \(error.localizedDescription); the original was restored")
        }
        try syncFileRow(id: replacedID, path: replacedPath, fileSystem: fs, now: now)
    }

    // MARK: Undo

    /// Reverses every completed operation of a batch, newest first. Stops at the first one that cannot be
    /// reversed (for example the Trash was emptied) and says why; what was undone stays undone.
    public func undoBatch(_ batch: String, fileSystem fs: FileSystem, now: Date = Date()) throws -> UndoResult {
        var result = UndoResult()
        var touched: [Int64] = []
        for op in try operations(batch: batch, limit: 10_000).reversed() where op.state == .done {
            do {
                try undo(operation: op, fileSystem: fs, now: now)
                result.undone += 1
                if let id = op.fileID { touched.append(id) }
            } catch {
                result.stoppedBecause = error.localizedDescription
                break
            }
        }
        if result.undone > 0 {
            try refreshDuplicateGroups()
            // The resolution was taken back, so its groups need a decision again.
            try database.write { db in
                for id in touched {
                    try db.execute(sql: "UPDATE dup_group SET status = 'open', updatedAt = ? WHERE id IN (SELECT groupID FROM dup_member WHERE fileID = ?)",
                                   arguments: [now, id])
                }
            }
        }
        return result
    }

    /// Undoes the most recent action that still has something to undo.
    public func undoLatestBatch(fileSystem fs: FileSystem, now: Date = Date()) throws -> UndoResult? {
        guard let batch = try operationBatches(limit: 100).first(where: \.canUndo) else { return nil }
        return try undoBatch(batch.batch, fileSystem: fs, now: now)
    }

    func undo(operation op: OperationRecord, fileSystem fs: FileSystem, now: Date) throws {
        guard op.state == .done else { throw OperationError.refused("operation \(op.id) is not done") }
        let setState = { (state: OperationState, holdback: String?) in
            try self.database.write { db in
                try db.execute(sql: """
                    UPDATE operation SET state = ?, holdbackPath = COALESCE(?, holdbackPath),
                        undoneAt = CASE WHEN ? = 'undone' THEN ? END WHERE id = ?
                    """, arguments: [state.rawValue, holdback, state.rawValue, now, op.id])
            }
        }
        switch op.kind {
        case .trash:
            guard fs.exists(op.toPath) else { throw OperationError.refused("\(op.fromPath) is no longer in the Trash") }
            guard !fs.exists(op.fromPath) else { throw OperationError.refused("something else is now at \(op.fromPath); not replacing it") }
            try setState(.undoing, nil)
            do { try fs.move(from: op.toPath, to: op.fromPath) }
            catch { try? setState(.done, nil); throw OperationError.refused("could not restore \(op.fromPath): \(error.localizedDescription)") }
            try setState(.undone, nil)
            if let fileID = op.fileID { try syncFileRow(id: fileID, path: op.fromPath, fileSystem: fs, now: now) }
        case .clone:
            // The clone goes to the Trash like any removal. Only an untouched clone is removed.
            guard fs.exists(op.toPath) else { throw OperationError.refused("\(op.toPath) is no longer there") }
            guard let hash = op.originalHash, ContentHash.full(of: op.toPath, fileSystem: fs) == hash else {
                throw OperationError.refused("\(op.toPath) was changed after it was cloned; not removing it")
            }
            try setState(.undoing, nil)
            let holdback: String
            do { holdback = try fs.trash(at: op.toPath) }
            catch { try? setState(.done, nil); throw OperationError.refused("could not remove the clone at \(op.toPath): \(error.localizedDescription)") }
            try setState(.undone, holdback)
            if let fileID = op.fileID { try syncFileRow(id: fileID, path: op.toPath, fileSystem: fs, now: now) }
        case .move, .rename, .resize:
            throw OperationError.refused("\(op.kind.rawValue) operations arrive with managed roots")
        }
    }

    // MARK: Crash recovery

    /// Settles operations a crash or quit left half-way, by looking at the disk. Call when a library opens.
    /// Returns how many rows changed.
    @discardableResult
    public func recoverInterruptedOperations(fileSystem fs: FileSystem, now: Date = Date()) throws -> Int {
        let stuck = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM operation WHERE state IN ('pending', 'undoing') ORDER BY id").map(Self.operation)
        }
        for op in stuck {
            var state: OperationState = .failed
            var note: String? = "interrupted before it finished"
            var settledPath: String?
            switch (op.state, op.kind) {
            case (.pending, .trash):
                if fs.exists(op.fromPath) { note = "interrupted before it ran; the file was not touched" }
                else { note = "interrupted; the file may be in the Trash" }
            case (.pending, .clone):
                if fs.exists(op.toPath) { state = .done; note = nil; settledPath = op.toPath }
            case (.undoing, .trash):
                if fs.exists(op.fromPath), !fs.exists(op.toPath) { state = .undone; note = nil; settledPath = op.fromPath }
                else { state = .done; note = nil }
            case (.undoing, .clone):
                if !fs.exists(op.toPath) { state = .undone; note = nil; settledPath = op.toPath } else { state = .done; note = nil }
            default: break
            }
            try database.write { db in
                try db.execute(sql: """
                    UPDATE operation SET state = ?, error = ?, undoneAt = CASE WHEN ? = 'undone' THEN ? END WHERE id = ?
                    """, arguments: [state.rawValue, note, state.rawValue, now, op.id])
            }
            if let fileID = op.fileID {
                switch (state, op.kind) {
                case (.done, .clone), (.undone, .trash): try syncFileRow(id: fileID, path: settledPath ?? op.toPath, fileSystem: fs, now: now)
                case (.undone, .clone): try syncFileRow(id: fileID, path: op.toPath, fileSystem: fs, now: now)
                default: break
                }
            }
        }
        if !stuck.isEmpty { try refreshDuplicateGroups() }
        return stuck.count
    }
}
