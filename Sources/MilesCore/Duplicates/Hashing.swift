import Foundation
import GRDB

/// Staged hashing for exact duplicates, cheapest first (ADR 0007):
/// 1. a file with a unique size cannot be a duplicate, so it is never read;
/// 2. files that share a size get a partial hash (start, middle, end);
/// 3. files that also share a partial hash get the full content hash, which alone decides equality.
/// Hashes are cached on `file` and cleared by the scanner when a file changes. Placeholders are skipped
/// until they are local, and nothing here ever downloads.
public struct HashJobHandler: JobHandler {
    public enum Stage: Sendable { case partial, full }

    let library: Library
    let fileSystem: FileSystem
    let stage: Stage

    public init(library: Library, fileSystem: FileSystem, stage: Stage) {
        self.library = library
        self.fileSystem = fileSystem
        self.stage = stage
    }

    struct HashError: LocalizedError {
        let path: String
        var errorDescription: String? { "could not read \(path)" }
    }

    public func run(_ job: Job) async throws {
        struct Indexed: Sendable { var size: Int64; var modified: Date; var local: Bool; var missing: Bool }
        guard let fileID = job.fileID, let row = try await library.database.read({ db -> Indexed? in
            try Row.fetchOne(db, sql: "SELECT size, modified, icloudStatus, missingSince FROM file WHERE id = ?", arguments: [fileID])
                .map { Indexed(size: $0["size"], modified: $0["modified"], local: ($0["icloudStatus"] as String) == "local",
                               missing: ($0["missingSince"] as Date?) != nil) }
        }), row.local, !row.missing else { return }
        let size = row.size
        let modified = row.modified
        guard size > 0, let file = try library.file(id: fileID),
              let path = try? library.absolutePath(of: file, fileSystem: fileSystem) else { return }

        // The index may be behind the disk. Hash only a file that still looks as indexed; a scan fixes the row.
        func unchanged() -> Bool {
            guard let live = try? fileSystem.metadata(at: path), !live.isDirectory, !live.isSymlink, !live.isDataless else { return false }
            return live.size == size && abs(live.modified.timeIntervalSince(modified)) < 0.01
        }
        guard unchanged() else { return }

        let hash: Data?
        switch stage {
        case .partial: hash = ContentHash.partial(of: path, size: size, fileSystem: fileSystem)
        case .full: hash = ContentHash.full(of: path, fileSystem: fileSystem)
        }
        guard let hash else { throw HashError(path: path) }
        guard unchanged() else { return }    // edited while it was being read: the result may mix two versions

        let column = stage == .partial ? "partialHash" : "fullHash"
        let stored = try await library.database.write { db -> Bool in
            try db.execute(sql: "UPDATE file SET \(column) = ? WHERE id = ? AND size = ? AND modified = ? AND missingSince IS NULL",
                           arguments: [hash, fileID, size, modified])
            return db.changesCount == 1
        }
        guard stored else { return }
        switch stage {
        case .partial: try library.queueFullHashesForMatches(size: size, partialHash: hash)
        case .full: try library.syncExactGroup(fullHash: hash)
        }
    }
}

extension Library {
    /// Queues the hashing that is due: a partial hash for every unhashed local file that shares its size
    /// with another file, and a full hash for every file whose partial hash matches another's. Files that are
    /// the same file (hard links) do not count as each other's peers. Returns the number of jobs added.
    @discardableResult
    public func enqueueHashingJobs(rootID: Int64? = nil, now: Date = Date()) throws -> Int {
        try database.write { db in
            let scope = rootID == nil ? "" : "AND f.rootID = ?"
            let args: [DatabaseValueConvertible] = rootID.map { [$0] } ?? []
            var added = 0
            try db.execute(sql: """
                INSERT OR IGNORE INTO job (kind, fileID, state, attempts, createdAt, updatedAt)
                SELECT ?, f.id, 'queued', 0, ?, ? FROM file f
                WHERE f.missingSince IS NULL AND f.icloudStatus = 'local' AND f.size > 0 AND f.partialHash IS NULL \(scope)
                  AND EXISTS (SELECT 1 FROM file g WHERE g.size = f.size AND g.id <> f.id AND g.missingSince IS NULL
                              AND NOT (g.volumeID = f.volumeID AND g.fileID = f.fileID)
                              AND (g.icloudStatus = 'local' OR g.partialHash IS NOT NULL))
                ORDER BY f.id
                """, arguments: StatementArguments([JobKind.hashPartial.rawValue, now, now] + args))
            added += db.changesCount
            try db.execute(sql: """
                INSERT OR IGNORE INTO job (kind, fileID, state, attempts, createdAt, updatedAt)
                SELECT ?, f.id, 'queued', 0, ?, ? FROM file f
                WHERE f.missingSince IS NULL AND f.icloudStatus = 'local' AND f.fullHash IS NULL AND f.partialHash IS NOT NULL \(scope)
                  AND EXISTS (SELECT 1 FROM file g WHERE g.size = f.size AND g.partialHash = f.partialHash AND g.id <> f.id
                              AND g.missingSince IS NULL AND NOT (g.volumeID = f.volumeID AND g.fileID = f.fileID))
                ORDER BY f.id
                """, arguments: StatementArguments([JobKind.hashFull.rawValue, now, now] + args))
            added += db.changesCount
            return added
        }
    }

    /// Called after a partial hash is stored: if another file now shares it, both need a full hash.
    /// Whichever file finishes its partial hash last is the one that finds the match.
    func queueFullHashesForMatches(size: Int64, partialHash: Data, now: Date = Date()) throws {
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, volumeID, fileID, fullHash IS NULL AS needsFull, icloudStatus FROM file
                WHERE size = ? AND partialHash = ? AND missingSince IS NULL
                """, arguments: [size, partialHash])
            guard Set(rows.map { "\($0["volumeID"] as String):\($0["fileID"] as Int64)" }).count >= 2 else { return }
            for row in rows where (row["needsFull"] as Bool) && (row["icloudStatus"] as String) == "local" {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO job (kind, fileID, state, attempts, createdAt, updatedAt) VALUES (?, ?, 'queued', 0, ?, ?)
                    """, arguments: [JobKind.hashFull.rawValue, row["id"] as Int64, now, now])
            }
        }
    }
}
