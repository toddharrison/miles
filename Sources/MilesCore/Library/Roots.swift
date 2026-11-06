import Foundation
import GRDB

public struct RootRecord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var location: VolumeLocation
    public var mode: String
}

extension Library {
    /// Registers a directory as an unmanaged root (ADR 0001). Refuses a root that overlaps, is nested
    /// in, or contains any existing root, in this library or in any other registered library
    /// (ADR 0012). If another library cannot be read, the root is refused rather than risk an overlap.
    @discardableResult
    public func addRoot(at path: String, fileSystem fs: FileSystem, registry: LibraryRegistry) throws -> RootRecord {
        let path = canonicalPath(path)
        guard let meta = try? fs.metadata(at: path), meta.isDirectory else { throw LibraryError.invalidRoot(path) }
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
            try Row.fetchAll(db, sql: "SELECT id, volumeID, relativePath, mode FROM root ORDER BY id").map {
                RootRecord(id: $0["id"], location: VolumeLocation(volumeID: $0["volumeID"], relativePath: $0["relativePath"]), mode: $0["mode"])
            }
        }
    }
}
