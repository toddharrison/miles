import Foundation
import GRDB

public struct RootRecord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var location: VolumeLocation
    public var mode: String
    /// User exclusions (see `Exclusions`). App-owned library packages are always excluded on top of these.
    public var exclusions: [String] = []
    /// Opt-in: download evicted images once to build thumbnails (ADR 0011). Off by default.
    public var fetchOnce: Bool = false
}

extension Library {
    /// Registers a directory as an unmanaged root (ADR 0001). Refuses a root that overlaps, is nested
    /// in, or contains any existing root, in this library or in any other registered library
    /// (ADR 0012). If another library cannot be read, the root is refused rather than risk an overlap.
    @discardableResult
    public func addRoot(at path: String, fileSystem fs: FileSystem, registry: LibraryRegistry) throws -> RootRecord {
        let path = canonicalPath(path)
        guard let meta = try? fs.metadata(at: path), meta.isDirectory else { throw LibraryError.invalidRoot(path) }
        // A root may contain an app-owned library (it is skipped) but never be one or sit inside one (ADR 0004).
        guard !Exclusions.isInsideAppOwnedPackage(path) else { throw LibraryError.appOwnedLibrary(path) }
        guard let candidate = VolumeLocation.make(path: path, fileSystem: fs) else {
            throw LibraryError.locationUnavailable(path)
        }

        for existing in try roots() where existing.location.overlaps(candidate) {
            throw LibraryError.overlappingRoot(candidate: path, existing: existing.location.relativePath, inLibrary: nil)
        }
        for other in try registry.rootsOfOtherLibraries(excluding: id, fileSystem: fs) where other.location.overlaps(candidate) {
            throw LibraryError.overlappingRoot(candidate: path, existing: other.location.relativePath, inLibrary: other.library)
        }

        let id = try database.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO root (volumeID, relativePath, mode, createdAt) VALUES (?, ?, 'unmanaged', ?)",
                           arguments: [candidate.volumeID, candidate.relativePath, Date()])
            return db.lastInsertedRowID
        }
        return RootRecord(id: id, location: candidate, mode: "unmanaged")
    }

    public func roots() throws -> [RootRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, volumeID, relativePath, mode, exclusions, fetchOnce FROM root ORDER BY id").map {
                RootRecord(id: $0["id"], location: VolumeLocation(volumeID: $0["volumeID"], relativePath: $0["relativePath"]),
                           mode: $0["mode"], exclusions: Exclusions.decode($0["exclusions"]).userPatterns,
                           fetchOnce: $0["fetchOnce"])
            }
        }
    }

    /// Stops indexing a root and forgets its file records (cascade). Only Miles' own index data is
    /// removed; nothing on disk is touched. Returns how many file records were dropped.
    @discardableResult
    public func removeRoot(id rootID: Int64) throws -> Int {
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM root WHERE id = ?)", arguments: [rootID]) == true else {
                throw LibraryError.invalidRoot("root \(rootID)")
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file WHERE rootID = ?", arguments: [rootID]) ?? 0
            try db.execute(sql: "DELETE FROM root WHERE id = ?", arguments: [rootID])
            return count
        }
    }

    /// Replaces a root's user exclusions. Files already indexed under a newly excluded path are not
    /// seen by the next scan, so they become missing and are removed after the grace period.
    public func setExclusions(_ patterns: [String], forRoot rootID: Int64) throws {
        let json = Exclusions(userPatterns: patterns).json
        try database.write { db in
            try db.execute(sql: "UPDATE root SET exclusions = ? WHERE id = ?", arguments: [json, rootID])
            guard db.changesCount == 1 else { throw LibraryError.invalidRoot("root \(rootID)") }
        }
    }
}

public struct IndexedFile: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var rootID: Int64
    public var relativePath: String
    public var size: Int64
    public var modified: Date
    public var kind: String?
    public var icloudStatus: String
    public var missingSince: Date?
}

extension Library {
    /// Indexed files, ordered by root then path. Missing files are left out unless asked for.
    public func files(rootID: Int64? = nil, includeMissing: Bool = false, limit: Int? = nil) throws -> [IndexedFile] {
        try database.read { db in
            var sql = "SELECT id, rootID, relativePath, size, modified, kind, icloudStatus, missingSince FROM file WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let rootID { sql += " AND rootID = ?"; args.append(rootID) }
            if !includeMissing { sql += " AND missingSince IS NULL" }
            sql += " ORDER BY rootID, relativePath"
            if let limit { sql += " LIMIT ?"; args.append(limit) }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                IndexedFile(id: $0["id"], rootID: $0["rootID"], relativePath: $0["relativePath"], size: $0["size"],
                            modified: $0["modified"], kind: $0["kind"], icloudStatus: $0["icloudStatus"],
                            missingSince: $0["missingSince"])
            }
        }
    }

    public func fileCount(rootID: Int64? = nil, includeMissing: Bool = false) throws -> Int {
        try database.read { db in
            var sql = "SELECT COUNT(*) FROM file WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let rootID { sql += " AND rootID = ?"; args.append(rootID) }
            if !includeMissing { sql += " AND missingSince IS NULL" }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }
}
