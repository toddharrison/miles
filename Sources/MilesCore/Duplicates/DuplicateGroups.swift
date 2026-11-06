import Foundation
import GRDB

public struct DuplicateMember: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var rootID: Int64
    public var relativePath: String
    public var size: Int64
    public var modified: Date
    public var icloudStatus: String
    public var volumeID: String
    /// Volume file ID. Two members with the same volume and file ID are one file with two names (a hard link).
    public var fileIdentity: Int64
    /// Accepted tags on this copy. Tags are per file, so copies can differ.
    public var tagCount: Int
    public var similarity: Double?
}

public struct DuplicateGroup: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case exact, near }
    public enum Status: String, Sendable { case open, reviewed }

    public var id: Int64
    public var kind: Kind
    public var status: Status
    public var contentHash: Data?
    public var members: [DuplicateMember]

    /// Space the extra copies take, as an upper bound: copies that already share storage (clones, hard links) free less.
    public var extraBytes: Int64 { members.dropFirst().reduce(0) { $0 + $1.size } }
}

/// Which copy to keep, as a suggestion only: Miles never picks for the user (ADR 0007).
public struct KeepSuggestion: Equatable, Sendable {
    public var fileID: Int64
    public var reason: String
}

extension Library {
    // MARK: Building groups

    /// Rebuilds the exact-duplicate groups from the cached full hashes. A group is a set of live files that
    /// share a full hash and are at least two different files on disk. A group keeps its review status while
    /// its members stay the same; a new or lost member reopens it. Groups that are no longer duplicates are dropped.
    public func refreshDuplicateGroups() throws {
        try database.write { db in
            let hashes = try Data.fetchAll(db, sql: """
                SELECT fullHash FROM file WHERE fullHash IS NOT NULL AND missingSince IS NULL AND size > 0
                GROUP BY fullHash HAVING COUNT(DISTINCT volumeID || ':' || fileID) >= 2
                """)
            for hash in hashes { try Self.syncExactGroup(db, fullHash: hash) }
            let keep = Set(hashes)
            for row in try Row.fetchAll(db, sql: "SELECT id, contentHash FROM dup_group WHERE kind = 'exact'")
            where !keep.contains(row["contentHash"] as Data) {
                try db.execute(sql: "DELETE FROM dup_group WHERE id = ?", arguments: [row["id"] as Int64])
            }
        }
    }

    /// Updates the one exact group for `fullHash`. Called when a full hash is stored.
    func syncExactGroup(fullHash: Data) throws {
        try database.write { try Self.syncExactGroup($0, fullHash: fullHash) }
    }

    private static func syncExactGroup(_ db: Database, fullHash: Data, now: Date = Date()) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, volumeID, fileID FROM file WHERE fullHash = ? AND missingSince IS NULL AND size > 0 ORDER BY id
            """, arguments: [fullHash])
        let ids = rows.map { $0["id"] as Int64 }
        let distinct = Set(rows.map { "\($0["volumeID"] as String):\($0["fileID"] as Int64)" })
        let existing = try Int64.fetchOne(db, sql: "SELECT id FROM dup_group WHERE kind = 'exact' AND contentHash = ?", arguments: [fullHash])

        guard distinct.count >= 2 else {
            if let existing { try db.execute(sql: "DELETE FROM dup_group WHERE id = ?", arguments: [existing]) }
            return
        }
        guard let groupID = existing else {
            try db.execute(sql: "INSERT INTO dup_group (kind, contentHash, status, createdAt, updatedAt) VALUES ('exact', ?, 'open', ?, ?)",
                           arguments: [fullHash, now, now])
            let id = db.lastInsertedRowID
            for fileID in ids { try db.execute(sql: "INSERT INTO dup_member (groupID, fileID) VALUES (?, ?)", arguments: [id, fileID]) }
            return
        }
        let current = try Int64.fetchAll(db, sql: "SELECT fileID FROM dup_member WHERE groupID = ? ORDER BY fileID", arguments: [groupID])
        guard current != ids else { return }
        try db.execute(sql: "DELETE FROM dup_member WHERE groupID = ?", arguments: [groupID])
        for fileID in ids { try db.execute(sql: "INSERT INTO dup_member (groupID, fileID) VALUES (?, ?)", arguments: [groupID, fileID]) }
        try db.execute(sql: "UPDATE dup_group SET status = 'open', updatedAt = ? WHERE id = ?", arguments: [now, groupID])
    }

    // MARK: Reading groups

    /// Duplicate groups, largest waste first. Reviewed groups are left out unless asked for. Missing files are never listed.
    public func duplicateGroups(includeReviewed: Bool = false, limit: Int? = nil) throws -> [DuplicateGroup] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT g.id FROM dup_group g
                JOIN dup_member m ON m.groupID = g.id JOIN file f ON f.id = m.fileID AND f.missingSince IS NULL
                \(includeReviewed ? "" : "WHERE g.status = 'open'")
                GROUP BY g.id HAVING COUNT(DISTINCT f.volumeID || ':' || f.fileID) >= 2
                ORDER BY (COUNT(*) - 1) * MAX(f.size) DESC, g.id
                \(limit == nil ? "" : "LIMIT \(max(limit ?? 0, 0))")
                """)
            return try rows.compactMap { try Self.loadGroup(db, id: $0["id"]) }
        }
    }

    public func duplicateGroup(id: Int64) throws -> DuplicateGroup? {
        try database.read { try Self.loadGroup($0, id: id) }
    }

    private static func loadGroup(_ db: Database, id: Int64) throws -> DuplicateGroup? {
        guard let g = try Row.fetchOne(db, sql: "SELECT id, kind, status, contentHash FROM dup_group WHERE id = ?", arguments: [id]) else { return nil }
        let members = try Row.fetchAll(db, sql: """
            SELECT f.id, f.rootID, f.relativePath, f.size, f.modified, f.icloudStatus, f.volumeID, f.fileID, m.similarity,
                   (SELECT COUNT(*) FROM file_tag ft WHERE ft.fileID = f.id AND ft.status = 'accepted') AS tagCount
            FROM dup_member m JOIN file f ON f.id = m.fileID
            WHERE m.groupID = ? AND f.missingSince IS NULL ORDER BY f.id
            """, arguments: [id]).map {
            DuplicateMember(id: $0["id"], rootID: $0["rootID"], relativePath: $0["relativePath"], size: $0["size"],
                            modified: $0["modified"], icloudStatus: $0["icloudStatus"], volumeID: $0["volumeID"],
                            fileIdentity: $0["fileID"], tagCount: $0["tagCount"], similarity: $0["similarity"])
        }
        return DuplicateGroup(id: id, kind: DuplicateGroup.Kind(rawValue: g["kind"]) ?? .exact,
                              status: DuplicateGroup.Status(rawValue: g["status"]) ?? .open,
                              contentHash: g["contentHash"], members: members)
    }

    /// Marks a group reviewed (or open again). Does not touch any file.
    public func setDuplicateGroupReviewed(_ id: Int64, reviewed: Bool, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE dup_group SET status = ?, updatedAt = ? WHERE id = ?",
                           arguments: [reviewed ? "reviewed" : "open", now, id])
            guard db.changesCount == 1 else { throw DuplicateError.noSuchGroup(id) }
        }
    }

    /// A suggestion for which copy to keep: most tags, then shortest path, then oldest, then first indexed.
    /// Only a suggestion; the user chooses (ADR 0007).
    public func suggestKeep(in group: DuplicateGroup) -> KeepSuggestion? {
        let ranked = group.members.sorted { a, b in
            if a.tagCount != b.tagCount { return a.tagCount > b.tagCount }
            if a.relativePath.count != b.relativePath.count { return a.relativePath.count < b.relativePath.count }
            if a.modified != b.modified { return a.modified < b.modified }
            return a.id < b.id
        }
        guard let best = ranked.first else { return nil }
        guard let next = ranked.dropFirst().first else { return KeepSuggestion(fileID: best.id, reason: "only copy") }
        let reason: String
        if best.tagCount != next.tagCount { reason = "most tags" }
        else if best.relativePath.count != next.relativePath.count { reason = "shortest path" }
        else if best.modified != next.modified { reason = "oldest" }
        else { reason = "first indexed" }
        return KeepSuggestion(fileID: best.id, reason: reason)
    }
}

public enum DuplicateError: Error, Equatable, LocalizedError, Sendable {
    case noSuchGroup(Int64)
    public var errorDescription: String? {
        switch self { case .noSuchGroup(let id): "no duplicate group \(id)" }
    }
}
