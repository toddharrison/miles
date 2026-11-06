import Foundation
import GRDB

/// Schema and migrations for a library database (ADR 0002). Schema changes are migrations only.
enum LibraryDatabase {
    /// Highest schema version this build understands. Bump with every migration added below,
    /// and add the migration. An older app refuses a database with a higher version (ADR 0012).
    static let currentSchemaVersion = 1

    static let metaSchemaVersionKey = "schema_version"
    static let metaLibraryIDKey = "library_id"
    static let metaCreatedAtKey = "created_at"

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-root-file-meta") { db in
            try db.create(table: "library_meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            try db.create(table: "root") { t in
                t.autoIncrementedPrimaryKey("id")
                // Volume identity plus path relative to the volume's mount point (ADR 0012).
                t.column("volumeID", .text).notNull()
                t.column("relativePath", .text).notNull()
                t.column("bookmark", .blob)
                t.column("mode", .text).notNull().defaults(to: "unmanaged")
                    .check { $0 == "managed" || $0 == "unmanaged" }
                t.column("exclusions", .text)               // JSON array, filled in by Step 1
                t.column("standardizationRule", .text)      // JSON, ADR 0006 (Step 7)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["volumeID", "relativePath"])
            }

            try db.create(table: "file") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rootID", .integer).notNull().references("root", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("volumeID", .text).notNull()
                t.column("fileID", .integer).notNull()
                t.column("size", .integer).notNull()
                t.column("modified", .datetime).notNull()
                t.column("kind", .text)
                t.column("icloudStatus", .text).notNull().defaults(to: "local")
                t.column("partialHash", .blob)
                t.column("fullHash", .blob)                 // nullable until computed
                t.column("firstSeen", .datetime).notNull()
                t.column("lastSeen", .datetime).notNull()
                t.column("missingSince", .datetime)
                t.uniqueKey(["rootID", "relativePath"])
            }
            // Re-matching moved files (volume and file ID first, then hash) and duplicate detection (ADR 0007).
            try db.create(index: "file_on_identity", on: "file", columns: ["volumeID", "fileID"])
            try db.create(index: "file_on_size", on: "file", columns: ["size"])
            try db.create(index: "file_on_fullHash", on: "file", columns: ["fullHash"])

            try db.execute(sql: "INSERT INTO library_meta (key, value) VALUES (?, ?)",
                           arguments: [metaSchemaVersionKey, "1"])
        }

        return migrator
    }

    static func configuration(readonly: Bool = false) -> Configuration {
        var config = Configuration()
        config.readonly = readonly
        config.foreignKeysEnabled = true
        return config
    }

    /// The schema version recorded in an existing database, without migrating it. Nil for a
    /// database that has no version record yet.
    static func recordedSchemaVersion(atPath path: String) throws -> Int? {
        let queue = try DatabaseQueue(path: path, configuration: configuration(readonly: true))
        return try queue.read { db in
            guard try db.tableExists("library_meta") else { return nil }
            let value = try String.fetchOne(db, sql: "SELECT value FROM library_meta WHERE key = ?",
                                            arguments: [metaSchemaVersionKey])
            return value.flatMap(Int.init)
        }
    }

    /// Applies pending migrations and keeps the recorded schema version in step.
    static func migrate(_ writer: some DatabaseWriter) throws {
        let migrator = makeMigrator()
        try migrator.migrate(writer)
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO library_meta (key, value) VALUES (?, ?)",
                           arguments: [metaSchemaVersionKey, String(currentSchemaVersion)])
        }
    }

    /// True if the database has migrations this build does not know about.
    static func hasBeenSuperseded(_ writer: some DatabaseWriter) throws -> Bool {
        try writer.read { db in try makeMigrator().hasBeenSuperseded(db) }
    }
}
