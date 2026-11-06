import Foundation
import GRDB

/// What restoring a snapshot would do, from reading the snapshot alone.
public struct RestorePreview: Equatable, Sendable {
    public var snapshotPath: String
    public var schemaVersion: Int
    public var currentSchemaVersion: Int
    public var libraryID: UUID?
    public var roots: Int
    public var files: Int
    public var tags: Int
    /// The snapshot is older than this build's schema and is migrated forward as part of the restore.
    public var willMigrate: Bool { schemaVersion < currentSchemaVersion }
}

public struct RestoreResult: Equatable, Sendable {
    public var restoredFrom: String
    public var fromSchemaVersion: Int
    public var migrated: Bool
    /// Snapshot of the database as it was before the restore (nil only when there was none).
    public var safetyBackup: String?
}

/// Restore (ADR 0005): a supported, tested operation, not a file copy. The library must be closed.
/// The snapshot is verified, migrated forward on a scratch copy, verified again, and only then
/// swapped in. The database it replaces is first kept as a pre-restore snapshot, or as a raw copy
/// when it is too damaged to snapshot.
public enum LibraryRestore {
    /// Resolves `name` as a snapshot in the library's `backups/` folder, "latest", or a file path.
    public static func resolveSnapshot(_ name: String, libraryDirectory: String) throws -> String {
        let dir = canonicalPath(libraryDirectory) + "/" + BackupNaming.folder
        if name == "latest" {
            guard let newest = Library.listBackups(in: dir).first else { throw BackupError.snapshotNotFound(name) }
            return newest.path
        }
        if FileManager.default.fileExists(atPath: dir + "/" + name) { return dir + "/" + name }
        if name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) { return name }
        throw BackupError.snapshotNotFound(name)
    }

    /// Snapshots in a library folder's `backups/`, newest first. Works without opening the library.
    public static func snapshots(inLibraryAt directory: String) -> [BackupInfo] {
        Library.listBackups(in: canonicalPath(directory) + "/" + BackupNaming.folder)
    }

    public static func preview(snapshotPath: String) throws -> RestorePreview {
        try Library.verifyIntegrity(atPath: snapshotPath)
        do {
            let queue = try DatabaseQueue(path: snapshotPath, configuration: LibraryDatabase.configuration(readonly: true))
            return try queue.read { db in
                func meta(_ key: String) throws -> String? {
                    try String.fetchOne(db, sql: "SELECT value FROM library_meta WHERE key = ?", arguments: [key])
                }
                guard try db.tableExists("library_meta"), let version = try meta(LibraryDatabase.metaSchemaVersionKey).flatMap(Int.init) else {
                    throw BackupError.snapshotUnreadable(path: snapshotPath, detail: "no schema version recorded")
                }
                func count(_ table: String) throws -> Int {
                    try db.tableExists(table) ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 : 0
                }
                return RestorePreview(snapshotPath: snapshotPath, schemaVersion: version,
                                      currentSchemaVersion: LibraryDatabase.currentSchemaVersion,
                                      libraryID: try meta(LibraryDatabase.metaLibraryIDKey).flatMap(UUID.init),
                                      roots: try count("root"), files: try count("file"), tags: try count("tag"))
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.snapshotUnreadable(path: snapshotPath, detail: error.localizedDescription)
        }
    }

    @discardableResult
    public static func restore(snapshotPath: String, toLibraryAt directory: String, fileSystem fs: FileSystem,
                               owner: LockOwner = .current(), takeOverLock: Bool = false, now: Date = Date()) throws -> RestoreResult {
        let directory = canonicalPath(directory)
        guard fs.exists(directory) else { throw LibraryError.locationUnavailable(directory) }
        try LocationValidator.validate(directory, fileSystem: fs)

        let info = try preview(snapshotPath: snapshotPath)
        if info.schemaVersion > info.currentSchemaVersion {
            throw LibraryError.newerSchema(found: info.schemaVersion, supported: info.currentSchemaVersion)
        }

        let lock = try LibraryLock.acquire(directory: directory, fileSystem: fs, owner: owner, takeOver: takeOverLock)
        defer { lock.release() }

        let fm = FileManager.default
        let dbPath = directory + "/" + Library.databaseFileName
        let backups = directory + "/" + BackupNaming.folder
        var safety: String?

        if fm.fileExists(atPath: dbPath) {
            let current = try? DatabaseQueue(path: dbPath, configuration: LibraryDatabase.configuration())
            let currentID: String? = (try? current?.read { try String.fetchOne($0, sql: "SELECT value FROM library_meta WHERE key = ?",
                                                                                 arguments: [LibraryDatabase.metaLibraryIDKey]) }) ?? nil
            if let currentID, let snapshotID = info.libraryID, currentID != snapshotID.uuidString {
                throw BackupError.snapshotFromDifferentLibrary
            }
            let version = (try? current?.read { try String.fetchOne($0, sql: "SELECT value FROM library_meta WHERE key = ?",
                                                                     arguments: [LibraryDatabase.metaSchemaVersionKey]) }.flatMap(Int.init)) ?? 0
            // SQLite treats a file shorter than a page as an empty database, so a readable library identity
            // and a clean integrity check are required before the live file is trusted enough to snapshot.
            let readable = currentID != nil && (try? current?.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }) == ["ok"]
            if readable, let current, let kept = try? Library.snapshot(of: current, into: backups, kind: .preRestore,
                                                             schemaVersion: version, now: now) {
                safety = kept.path
            } else {
                // Too damaged to snapshot: keep the raw files so nothing is lost by restoring.
                try fm.createDirectory(atPath: backups, withIntermediateDirectories: true)
                let base = backups + "/damaged-\(BackupNaming.timestamp(now)).sqlite"
                for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: dbPath + suffix) {
                    try fm.copyItem(atPath: dbPath + suffix, toPath: base + suffix)
                }
                safety = base
            }
            try? current?.close()
        }

        // Build the replacement beside the live database (same volume, so the swap is a rename).
        let scratch = dbPath + ".restoring"
        for suffix in ["", "-wal", "-shm", "-journal"] { try? fm.removeItem(atPath: scratch + suffix) }
        try fm.copyItem(atPath: snapshotPath, toPath: scratch)
        do {
            let queue = try DatabaseQueue(path: scratch, configuration: LibraryDatabase.configuration())
            if try LibraryDatabase.hasBeenSuperseded(queue) {
                throw LibraryError.newerSchema(found: info.schemaVersion, supported: info.currentSchemaVersion)
            }
            try LibraryDatabase.migrate(queue)
            // Thumbnail files are named by file id and ids are not stable across a rollback, so the
            // derived cache is dropped and rebuilt (ADR 0011).
            try queue.write { try $0.execute(sql: "DELETE FROM thumbnail") }
            try queue.close()
            try Library.verifyIntegrity(atPath: scratch)
        } catch {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? fm.removeItem(atPath: scratch + suffix) }
            throw error
        }

        // A leftover WAL from the old database must never be replayed onto the restored one.
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: dbPath + suffix) }
        if fm.fileExists(atPath: dbPath) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: dbPath), withItemAt: URL(fileURLWithPath: scratch))
        } else {
            try fm.moveItem(atPath: scratch, toPath: dbPath)
        }
        try? fm.removeItem(atPath: directory + "/thumbnails")
        return RestoreResult(restoredFrom: snapshotPath, fromSchemaVersion: info.schemaVersion,
                             migrated: info.willMigrate, safetyBackup: safety)
    }
}
