import Foundation
import GRDB

/// What the user chose for a group. There is no default: Miles never picks an action (ADR 0007).
public enum ResolutionAction: String, CaseIterable, Sendable {
    /// Move the extra copies to the Trash.
    case trash
    /// Replace each extra copy with an APFS clone of the kept one: both paths stay valid and the space is
    /// reclaimed. Same volume only.
    case clone
    /// Leave every copy and mark the group reviewed.
    case keepAll = "keep-all"
}

/// One step of a preview: what would happen to one file.
public struct PlannedStep: Equatable, Sendable {
    public var kind: OperationKind
    public var fileID: Int64
    public var path: String
    public var summary: String
    /// Space this step frees, 0 when it frees none (a second name for one file).
    public var bytes: Int64
}

/// The preview of a duplicate resolution (ADR 0004, 0007). Nothing has changed when you hold one. A plan can
/// only be made by `planResolution` and run by `applyResolution`, so there is no way to act on files without
/// showing what will happen first. Everything is checked again when it is applied.
public struct ResolutionPlan: Sendable {
    public let groupID: Int64
    public let action: ResolutionAction
    public let keepFileID: Int64?
    public let mergeTags: Bool
    public let steps: [PlannedStep]
    /// Copies the action cannot touch, with the reason. They are left alone.
    public let skipped: [(fileID: Int64, path: String, reason: String)]
    /// Tags the kept copy would gain from the other copies.
    public let tagsToMerge: [String]

    public var bytesFreed: Int64 { steps.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { steps.isEmpty }
}

public struct ResolutionOutcome: Sendable {
    /// The journal batch to pass to `undoBatch`; nil when no file was changed.
    public var batch: String?
    public var resolvedFileIDs: [Int64] = []
    public var failures: [(fileID: Int64, reason: String)] = []
    public var tagsMerged = 0
}

extension Library {
    /// Previews resolving a group. `keep` is required for trash and clone: the user names the copy to keep.
    /// Reads the index and the disk's metadata; changes nothing and reads no file content.
    public func planResolution(groupID: Int64, action: ResolutionAction, keep: Int64?, mergeTags: Bool = false,
                               fileSystem fs: FileSystem) throws -> ResolutionPlan {
        guard let group = try duplicateGroup(id: groupID) else { throw DuplicateError.noSuchGroup(groupID) }
        guard group.kind == .exact else { throw OperationError.refused("only exact duplicate groups can be resolved") }
        guard group.members.count >= 2 else { throw OperationError.refused("group \(groupID) no longer has duplicates; refresh it") }
        if action == .keepAll {
            return ResolutionPlan(groupID: groupID, action: action, keepFileID: nil, mergeTags: false, steps: [], skipped: [], tagsToMerge: [])
        }
        guard let keep else { throw OperationError.refused("choose which copy to keep") }
        guard let kept = group.members.first(where: { $0.id == keep }) else { throw OperationError.refused("file \(keep) is not in group \(groupID)") }
        guard kept.icloudStatus == "local" else { throw OperationError.refused("the copy to keep is not downloaded") }
        guard let file = try file(id: keep), (try? absolutePath(of: file, fileSystem: fs)) != nil else {
            throw OperationError.refused("the drive holding the copy to keep is not available")
        }

        var steps: [PlannedStep] = []
        var skipped: [(fileID: Int64, path: String, reason: String)] = []
        let keptVolume = fs.volume(containing: try absolutePath(of: file, fileSystem: fs))
        for member in group.members where member.id != keep {
            guard let extra = try self.file(id: member.id), let path = try? absolutePath(of: extra, fileSystem: fs) else {
                skipped.append((member.id, member.relativePath, "its drive is not available")); continue
            }
            if member.icloudStatus != "local" || (try? fs.metadata(at: path))?.isDataless == true {
                skipped.append((member.id, path, "not downloaded (Miles never downloads files to act on them)")); continue
            }
            guard fs.exists(path) else { skipped.append((member.id, path, "no longer at its indexed path; scan again")); continue }
            let sameFile = member.volumeID == kept.volumeID && member.fileIdentity == kept.fileIdentity
            let freed = sameFile ? 0 : member.size
            switch action {
            case .trash:
                steps.append(PlannedStep(kind: .trash, fileID: member.id, path: path,
                                         summary: sameFile ? "move to the Trash (the same file as the kept copy, frees no space)" : "move to the Trash",
                                         bytes: freed))
            case .clone:
                if sameFile { skipped.append((member.id, path, "the same file as the kept copy")); continue }
                guard let volume = fs.volume(containing: path), volume.id == keptVolume?.id, volume.filesystemType == "apfs" else {
                    skipped.append((member.id, path, "on a different volume, or not APFS: a clone needs the same APFS volume")); continue
                }
                steps.append(PlannedStep(kind: .clone, fileID: member.id, path: path,
                                         summary: "move to the Trash, then replace with an APFS clone of the kept copy (the path stays valid)",
                                         bytes: freed))
            case .keepAll: break
            }
        }
        let tags = mergeTags ? try tagsToMerge(from: steps.map(\.fileID), into: keep) : []
        return ResolutionPlan(groupID: groupID, action: action, keepFileID: keep, mergeTags: mergeTags, steps: steps,
                              skipped: skipped, tagsToMerge: tags)
    }

    /// Runs a previewed plan. Every file is verified again just before it is touched (local, unchanged, same
    /// content hash). Each copy succeeds or fails on its own; a failure never stops the others, and anything
    /// that changed a file is journaled first and can be undone with the returned batch.
    public func applyResolution(_ plan: ResolutionPlan, fileSystem fs: FileSystem, now: Date = Date()) throws -> ResolutionOutcome {
        var outcome = ResolutionOutcome()
        if plan.action == .keepAll {
            try setDuplicateGroupReviewed(plan.groupID, reviewed: true, now: now)
            return outcome
        }
        guard let keep = plan.keepFileID, let group = try duplicateGroup(id: plan.groupID),
              group.members.contains(where: { $0.id == keep }) else {
            throw OperationError.refused("the group changed since the preview; preview it again")
        }
        guard !plan.steps.isEmpty else { return outcome }
        // A plan may be stale: only copies that are still in the group are touched, and never the kept one.
        let members = Set(group.members.map(\.id))
        let steps = plan.steps.filter { $0.fileID != keep && members.contains($0.fileID) }
        for stale in plan.steps where !steps.contains(stale) { outcome.failures.append((stale.fileID, "no longer in the group")) }

        if steps.count > 1 { _ = try backupBeforeBulkOperation(now: now) }   // refuses to go on if the backup fails
        let batch = UUID().uuidString
        for step in steps {
            do {
                let trash = try performTrash(fileID: step.fileID, batch: batch, fileSystem: fs, now: now)
                if plan.action == .clone {
                    try performClone(keptID: keep, replacedID: step.fileID, replacedPath: step.path, trashOperation: trash,
                                     batch: batch, fileSystem: fs, now: now)
                }
                if plan.mergeTags { outcome.tagsMerged += try mergeTags(from: step.fileID, into: keep) }
                outcome.resolvedFileIDs.append(step.fileID)
            } catch {
                outcome.failures.append((step.fileID, error.localizedDescription))
            }
        }
        if !outcome.resolvedFileIDs.isEmpty || !outcome.failures.isEmpty { outcome.batch = batch }
        if outcome.batch != nil, try operations(batch: batch, limit: 1).isEmpty { outcome.batch = nil }
        try refreshDuplicateGroups()
        // Clones leave the paths (and so the group) in place; a fully resolved group is reviewed.
        if plan.action == .clone, outcome.failures.isEmpty, !outcome.resolvedFileIDs.isEmpty {
            try setDuplicateGroupReviewed(plan.groupID, reviewed: true, now: now)
        }
        return outcome
    }

    // MARK: Tag merge

    /// Tags on `sources` that `target` does not have (and has not rejected), as `namespace:name`.
    func tagsToMerge(from sources: [Int64], into target: Int64) throws -> [String] {
        try database.read { db in
            guard !sources.isEmpty else { return [] }
            let marks = sources.map { _ in "?" }.joined(separator: ", ")
            return try String.fetchAll(db, sql: """
                SELECT DISTINCT n.name || ':' || t.name FROM file_tag ft
                JOIN tag t ON t.id = ft.tagID JOIN namespace n ON n.id = t.namespaceID
                WHERE ft.fileID IN (\(marks)) AND ft.status = 'accepted'
                  AND NOT EXISTS (SELECT 1 FROM file_tag k WHERE k.fileID = ? AND k.tagID = ft.tagID)
                ORDER BY 1
                """, arguments: StatementArguments(sources.map { $0 as DatabaseValueConvertible } + [target]))
        }
    }

    /// Copies the accepted tags of `source` onto `target` (same source, confidence and provider), skipping any
    /// tag `target` already has or has rejected, so a user's choice on the kept copy wins. Returns how many.
    @discardableResult
    func mergeTags(from source: Int64, into target: Int64, now: Date = Date()) throws -> Int {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO file_tag (fileID, tagID, source, confidence, status, provider, model, createdAt, layer)
                SELECT ?, tagID, source, confidence, 'accepted', provider, model, ?, layer FROM file_tag
                WHERE fileID = ? AND status = 'accepted'
                """, arguments: [target, now, source])
            return db.changesCount
        }
    }
}
