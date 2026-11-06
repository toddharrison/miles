import Foundation
import GRDB

/// An open library: one database plus the lock that guards it (ADR 0012).
/// Layout of a library folder: `library.sqlite`, `lock.json`, and later `thumbnails/` and `backups/`.
public final class Library: @unchecked Sendable {
    public static let databaseFileName = "library.sqlite"

    public let id: UUID
    public let directory: String
    public let volume: VolumeLocation
    public let database: DatabasePool
    private let lock: LibraryLock

    private init(id: UUID, directory: String, volume: VolumeLocation, database: DatabasePool, lock: LibraryLock) {
        self.id = id
        self.directory = directory
        self.volume = volume
        self.database = database
        self.lock = lock
    }

    public var databasePath: String { directory + "/" + Self.databaseFileName }

    // MARK: Create

    /// Creates a new library at `directory`. Refuses unavailable, non-local and synced locations,
    /// and never overwrites an existing library.
    public static func create(at directory: String, fileSystem fs: FileSystem, owner: LockOwner = .current()) throws -> Library {
        let directory = canonicalPath(directory)
        try LocationValidator.validate(directory, fileSystem: fs)
        let dbPath = directory + "/" + databaseFileName
        guard !fs.exists(dbPath) else { throw LibraryError.alreadyExists(directory) }

        try fs.createDirectory(at: directory)
        guard let location = VolumeLocation.make(path: directory, fileSystem: fs) else {
            throw LibraryError.locationUnavailable(directory)
        }
        let lock = try LibraryLock.acquire(directory: directory, fileSystem: fs, owner: owner)
        do {
            let pool = try DatabasePool(path: dbPath, configuration: LibraryDatabase.configuration())
            try LibraryDatabase.migrate(pool)
            let id = UUID()
            try pool.write { db in
                try db.execute(sql: "INSERT INTO library_meta (key, value) VALUES (?, ?), (?, ?)",
                               arguments: [LibraryDatabase.metaLibraryIDKey, id.uuidString,
                                           LibraryDatabase.metaCreatedAtKey, ISO8601DateFormatter().string(from: Date())])
            }
            return Library(id: id, directory: directory, volume: location, database: pool, lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    // MARK: Open

    /// Opens an existing library. A missing folder or database is reported, never recreated.
    /// A library written by a newer schema is refused. `takeOverLock` is for a stale lock the user confirmed.
    public static func open(at directory: String, fileSystem fs: FileSystem, owner: LockOwner = .current(), takeOverLock: Bool = false) throws -> Library {
        let directory = canonicalPath(directory)
        guard fs.exists(directory) else { throw LibraryError.locationUnavailable(directory) }
        try LocationValidator.validate(directory, fileSystem: fs)
        let dbPath = directory + "/" + databaseFileName
        guard fs.exists(dbPath) else { throw LibraryError.notALibrary(directory) }
        guard let location = VolumeLocation.make(path: directory, fileSystem: fs) else {
            throw LibraryError.locationUnavailable(directory)
        }

        let lock = try LibraryLock.acquire(directory: directory, fileSystem: fs, owner: owner, takeOver: takeOverLock)
        do {
            // Gate on version before touching the schema. An older app must never migrate or write a newer database.
            if let found = try LibraryDatabase.recordedSchemaVersion(atPath: dbPath),
               found > LibraryDatabase.currentSchemaVersion {
                throw LibraryError.newerSchema(found: found, supported: LibraryDatabase.currentSchemaVersion)
            }
            let pool = try DatabasePool(path: dbPath, configuration: LibraryDatabase.configuration())
            if try LibraryDatabase.hasBeenSuperseded(pool) {
                throw LibraryError.newerSchema(found: LibraryDatabase.currentSchemaVersion + 1,
                                               supported: LibraryDatabase.currentSchemaVersion)
            }
            // TODO(PLAN Step 4): snapshot the database before applying pending migrations.
            try LibraryDatabase.migrate(pool)
            let idString = try pool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM library_meta WHERE key = ?",
                                    arguments: [LibraryDatabase.metaLibraryIDKey])
            }
            guard let id = idString.flatMap(UUID.init) else { throw LibraryError.notALibrary(directory) }
            return Library(id: id, directory: directory, volume: location, database: pool, lock: lock)
        } catch {
            lock.release()
            throw error
        }
    }

    /// Closes the database (checkpointing the WAL so a portable drive is consistent) and releases the lock.
    public func close() throws {
        try database.close()
        lock.release()
    }

    public var schemaVersion: Int {
        get throws {
            try database.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM library_meta WHERE key = ?",
                                    arguments: [LibraryDatabase.metaSchemaVersionKey]).flatMap(Int.init) ?? 0
            }
        }
    }
}
