import Foundation
import GRDB

/// A requested move or rename. `toRelativePath` is relative to the destination root (the file's own root unless
/// `toRootID` is given), so a rename is just a new last component.
public struct MoveRequest: Equatable, Sendable {
    public var fileID: Int64
    public var toRootID: Int64?
    public var toRelativePath: String
    public init(fileID: Int64, toRootID: Int64? = nil, toRelativePath: String) {
        self.fileID = fileID; self.toRootID = toRootID; self.toRelativePath = toRelativePath
    }
}

/// One step of a move preview: old path to new path.
public struct PlannedMove: Equatable, Sendable {
    public var kind: OperationKind
    public var fileID: Int64
    public var fromPath: String
    public var toPath: String
    public var toRootID: Int64
    public var toRelativePath: String
    public var summary: String { "\(fromPath) -> \(toPath)" }
}

/// The preview of a bulk move or rename (ADR 0004). Nothing has changed when you hold one. Only `planMoves`
/// makes one and only `applyMoves` runs it.
public struct MovePlan: Sendable {
    public let steps: [PlannedMove]
    /// Requests Miles will not carry out, with the reason.
    public let skipped: [(fileID: Int64, reason: String)]
    public var isEmpty: Bool { steps.isEmpty }
}

public struct MoveOutcome: Sendable {
    public var batch: String?
    public var movedFileIDs: [Int64] = []
    public var failures: [(fileID: Int64, reason: String)] = []
}

extension Library {
    /// The root that holds an absolute path, and the path relative to it.
    func locate(path: String, fileSystem fs: FileSystem) throws -> (rootID: Int64, relativePath: String)? {
        var best: (rootID: Int64, relativePath: String, depth: Int)?
        for root in try roots() {
            guard let base = root.location.resolve(fileSystem: fs) else { continue }
            let prefix = base == "/" ? "/" : base + "/"
            guard path.hasPrefix(prefix), path.count > prefix.count, best == nil || base.count > best!.depth else { continue }
            best = (root.id, String(path.dropFirst(prefix.count)), base.count)
        }
        return best.map { ($0.rootID, $0.relativePath) }
    }

    /// Points a file row at its new path, keeping its identity (so tags stay), and refreshes its metadata.
    func relocateFileRow(id: Int64, path: String, fileSystem fs: FileSystem, now: Date) throws {
        guard let place = try locate(path: path, fileSystem: fs) else { throw OperationError.refused("\(path) is not inside a root") }
        try database.write { db in
            try db.execute(sql: "UPDATE file SET rootID = ?, relativePath = ?, missingSince = NULL, lastSeen = ? WHERE id = ?",
                           arguments: [place.rootID, place.relativePath, now, id])
        }
        try syncFileRow(id: id, path: path, fileSystem: fs, now: now)
    }

    // MARK: Preview

    /// Previews moving and renaming files in managed roots. Reads the index and the disk's metadata only.
    public func planMoves(_ requests: [MoveRequest], fileSystem fs: FileSystem) throws -> MovePlan {
        let roots = try roots()
        var steps: [PlannedMove] = []
        var skipped: [(fileID: Int64, reason: String)] = []
        var claimed = Set<String>()
        for request in requests {
            func skip(_ why: String) { skipped.append((request.fileID, why)) }
            guard let file = try file(id: request.fileID) else { skip("not indexed"); continue }
            guard let source = roots.first(where: { $0.id == file.rootID }), source.isManaged else { skip("its root is not managed"); continue }
            guard let target = roots.first(where: { $0.id == (request.toRootID ?? file.rootID) }), target.isManaged else { skip("the destination root is not managed"); continue }
            guard let relative = Self.cleanRelativePath(request.toRelativePath) else { skip("\"\(request.toRelativePath)\" is not a valid path inside a root"); continue }
            guard let from = try? absolutePath(of: file, fileSystem: fs), let base = target.location.resolve(fileSystem: fs) else { skip("its drive is not available"); continue }
            guard target.location.volumeID == source.location.volumeID else { skip("moving between volumes is not supported"); continue }
            let to = (base == "/" ? "" : base) + "/" + relative
            guard to != from else { skip("already named that"); continue }
            let excluded = Exclusions(userPatterns: target.exclusions)
            let parts = relative.split(separator: "/").map(String.init)
            var isExcluded = Exclusions.isIgnoredFileName(parts.last ?? "")
            for i in parts.indices where excluded.excludes(name: parts[i], relativePath: parts[...i].joined(separator: "/")) { isExcluded = true }
            guard !isExcluded else { skip("the destination is excluded from the index"); continue }
            guard file.missingSince == nil, file.icloudStatus == "local" else { skip("not downloaded or missing"); continue }
            guard let live = try? fs.metadata(at: from), !live.isDirectory, !live.isSymlink, !live.isDataless,
                  live.size == file.size, abs(live.modified.timeIntervalSince(file.modified)) < 0.01 else { skip("changed or gone since it was indexed; scan again"); continue }
            guard !fs.exists(to), claimed.insert(to).inserted else { skip("\(to) already exists"); continue }
            let sameFolder = (from as NSString).deletingLastPathComponent == (to as NSString).deletingLastPathComponent
            steps.append(PlannedMove(kind: sameFolder ? .rename : .move, fileID: file.id, fromPath: from, toPath: to,
                                     toRootID: target.id, toRelativePath: relative))
        }
        return MovePlan(steps: steps, skipped: skipped)
    }

    /// Previews renaming one file in place.
    public func planRename(fileID: Int64, to newName: String, fileSystem fs: FileSystem) throws -> MovePlan {
        guard !newName.contains("/"), let file = try file(id: fileID) else {
            return MovePlan(steps: [], skipped: [(fileID, "a name cannot contain /")])
        }
        let folder = (file.relativePath as NSString).deletingLastPathComponent
        return try planMoves([MoveRequest(fileID: fileID, toRelativePath: folder.isEmpty ? newName : folder + "/" + newName)], fileSystem: fs)
    }

    /// Normalises a relative path, or nil if it is empty, absolute, or climbs out of the root.
    static func cleanRelativePath(_ path: String) -> String? {
        guard !path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") && $0.utf8.count <= 255 }),
              !parts.contains(where: Exclusions.isAppOwnedPackage(name:)) else { return nil }
        return parts.joined(separator: "/")
    }

    // MARK: Apply

    /// Runs a previewed plan. Each file is checked again just before it moves (still indexed, local, unchanged,
    /// destination still free). Each succeeds or fails alone, and each is journaled first and undoable.
    public func applyMoves(_ plan: MovePlan, fileSystem fs: FileSystem, now: Date = Date()) throws -> MoveOutcome {
        var outcome = MoveOutcome()
        guard !plan.steps.isEmpty else { return outcome }
        if plan.steps.count > 1 { _ = try backupBeforeBulkOperation(now: now) }
        let batch = UUID().uuidString
        for step in plan.steps {
            do {
                try performMove(step, batch: batch, fileSystem: fs, now: now)
                outcome.movedFileIDs.append(step.fileID)
            } catch {
                outcome.failures.append((step.fileID, error.localizedDescription))
            }
        }
        if try !operations(batch: batch, limit: 1).isEmpty { outcome.batch = batch }
        return outcome
    }

    func performMove(_ step: PlannedMove, batch: String, fileSystem fs: FileSystem, now: Date) throws {
        guard let file = try file(id: step.fileID), let current = try? absolutePath(of: file, fileSystem: fs), current == step.fromPath else {
            throw OperationError.refused("\(step.fromPath) changed since the preview; preview it again")
        }
        guard try managedRoot(file.rootID).isManaged, try managedRoot(step.toRootID).isManaged else { throw OperationError.refused("managed mode was turned off") }
        guard file.missingSince == nil, file.icloudStatus == "local",
              let live = try? fs.metadata(at: current), !live.isDirectory, !live.isSymlink, !live.isDataless,
              live.size == file.size, abs(live.modified.timeIntervalSince(file.modified)) < 0.01 else {
            throw OperationError.refused("\(current) is missing, not downloaded or changed since it was indexed; scan again")
        }
        guard !fs.exists(step.toPath) else { throw OperationError.refused("\(step.toPath) already exists") }
        try fs.createDirectory(at: (step.toPath as NSString).deletingLastPathComponent)   // new folders stay if this is undone

        let opID = try insertOperation(kind: step.kind, batch: batch, fileID: file.id, from: current, to: step.toPath, hash: nil, now: now)
        do { try fs.move(from: current, to: step.toPath) }
        catch {
            try? finishOperation(opID, state: .failed, error: error.localizedDescription)
            throw OperationError.refused("could not move \(current): \(error.localizedDescription)")
        }
        do { try relocateFileRow(id: file.id, path: step.toPath, fileSystem: fs, now: now) }
        catch {
            try? fs.move(from: step.toPath, to: current)
            try? finishOperation(opID, state: .failed, error: error.localizedDescription)
            throw OperationError.refused("could not record the move of \(current): \(error.localizedDescription); it was put back")
        }
        try finishOperation(opID, state: .done)
    }

    // MARK: Undo and recovery

    func undoMove(_ op: OperationRecord, fileSystem fs: FileSystem, now: Date) throws {
        guard fs.exists(op.toPath) else { throw OperationError.refused("\(op.toPath) is no longer there") }
        guard !fs.exists(op.fromPath) else { throw OperationError.refused("something else is now at \(op.fromPath); not replacing it") }
        try setOperationState(op.id, .undoing, now: now)
        do { try fs.move(from: op.toPath, to: op.fromPath) }
        catch { try? setOperationState(op.id, .done, now: now); throw OperationError.refused("could not move \(op.toPath) back: \(error.localizedDescription)") }
        try setOperationState(op.id, .undone, now: now)
        if let fileID = op.fileID { try relocateFileRow(id: fileID, path: op.fromPath, fileSystem: fs, now: now) }
    }

    func settleMove(_ op: OperationRecord, fileSystem fs: FileSystem, now: Date) throws -> (OperationState, String?) {
        let fromThere = fs.exists(op.fromPath), toThere = fs.exists(op.toPath)
        switch op.state {
        case .pending:
            if toThere, !fromThere {
                if let fileID = op.fileID { try relocateFileRow(id: fileID, path: op.toPath, fileSystem: fs, now: now) }
                return (.done, nil)
            }
            return (.failed, "interrupted before it ran; the file was not touched")
        case .undoing:
            if fromThere, !toThere {
                if let fileID = op.fileID { try relocateFileRow(id: fileID, path: op.fromPath, fileSystem: fs, now: now) }
                return (.undone, nil)
            }
            return (.done, nil)
        default:
            return (op.state, nil)
        }
    }
}
