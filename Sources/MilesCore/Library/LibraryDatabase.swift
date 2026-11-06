import Foundation
import GRDB

/// Schema and migrations for a library database (ADR 0002). Schema changes are migrations only.
enum LibraryDatabase {
    /// Highest schema version this build understands. Bump with every migration added below,
    /// and add the migration. An older app refuses a database with a higher version (ADR 0012).
    static let currentSchemaVersion = 6

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

        // Tags, search index and saved searches (ADR 0008, 0009).
        migrator.registerMigration("v2-tags-search") { db in
            try db.create(table: "namespace") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("isDefault", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "INSERT INTO namespace (name, isDefault) VALUES (?, 1)", arguments: [TagName.defaultNamespace])

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("namespaceID", .integer).notNull().references("namespace", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["namespaceID", "name"])
            }
            try db.create(table: "tag_alias") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("namespaceID", .integer).notNull().references("namespace", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("tagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.uniqueKey(["namespaceID", "name"])
            }
            try db.create(index: "tag_alias_on_tag", on: "tag_alias", columns: ["tagID"])
            try db.create(table: "tag_implication") { t in
                t.column("tagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.column("impliesTagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.primaryKey(["tagID", "impliesTagID"])
                t.check(sql: "tagID <> impliesTagID")
            }
            try db.create(index: "tag_implication_on_implied", on: "tag_implication", columns: ["impliesTagID"])
            try db.create(table: "file_tag") { t in
                t.column("fileID", .integer).notNull().references("file", onDelete: .cascade)
                t.column("tagID", .integer).notNull().references("tag", onDelete: .cascade)
                t.column("source", .text).notNull().check { $0 == "user" || $0 == "rule" || $0 == "ai" }
                t.column("confidence", .double)
                t.column("status", .text).notNull().defaults(to: "accepted")
                    .check { $0 == "accepted" || $0 == "suggested" || $0 == "rejected" }
                t.column("provider", .text)
                t.column("model", .text)
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["fileID", "tagID"])
            }
            try db.create(index: "file_tag_on_tag", on: "file_tag", columns: ["tagID", "status"])

            try db.create(table: "saved_search") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("query", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // FTS5 over file name, path and accepted tags. Rowid is file.id. Triggers keep it in step
            // so the scanner and the tag store never have to think about it.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE file_fts USING fts5(name, path, tags, tokenize = 'unicode61 remove_diacritics 2')
                """)
            try db.execute(sql: """
                INSERT INTO file_fts (rowid, name, path, tags)
                SELECT id, \(nameSQL("relativePath")), relativePath, '' FROM file
                """)
            try db.execute(sql: """
                CREATE TRIGGER file_fts_insert AFTER INSERT ON file BEGIN
                  INSERT INTO file_fts (rowid, name, path, tags) VALUES (NEW.id, \(nameSQL("NEW.relativePath")), NEW.relativePath, '');
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER file_fts_path AFTER UPDATE OF relativePath ON file WHEN OLD.relativePath <> NEW.relativePath BEGIN
                  UPDATE file_fts SET name = \(nameSQL("NEW.relativePath")), path = NEW.relativePath WHERE rowid = NEW.id;
                END
                """)
            try db.execute(sql: "CREATE TRIGGER file_fts_delete AFTER DELETE ON file BEGIN DELETE FROM file_fts WHERE rowid = OLD.id; END")
            for (event, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                try db.execute(sql: """
                    CREATE TRIGGER file_tag_fts_\(event.lowercased()) AFTER \(event) ON file_tag BEGIN
                      UPDATE file_fts SET tags = COALESCE((
                        SELECT group_concat(n.name || ':' || t.name, ' ')
                        FROM file_tag ft JOIN tag t ON t.id = ft.tagID JOIN namespace n ON n.id = t.namespaceID
                        WHERE ft.fileID = \(row).fileID AND ft.status = 'accepted'), '')
                      WHERE rowid = \(row).fileID;
                    END
                    """)
            }
        }

        // Thumbnail cache bookkeeping and the per-root fetch-once setting (ADR 0011).
        migrator.registerMigration("v3-thumbnails") { db in
            try db.alter(table: "root") { t in
                t.add(column: "fetchOnce", .boolean).notNull().defaults(to: false)
            }
            // One row per file whose thumbnails (all sizes) exist on disk, with the file version they came from.
            try db.create(table: "thumbnail") { t in
                t.primaryKey("fileID", .integer).references("file", onDelete: .cascade)
                t.column("sourceSize", .integer).notNull()
                t.column("sourceModified", .datetime).notNull()
                t.column("generatedAt", .datetime).notNull()
            }
        }

        // Job queue, automated tagging layers and path rules (ADR 0003, 0010, 0014).
        migrator.registerMigration("v4-jobs-layers-rules") { db in
            // Namespaces the layers write to are labelled system-managed. The user may still add tags in them.
            try db.alter(table: "namespace") { t in t.add(column: "isSystem", .boolean).notNull().defaults(to: false) }
            // Which layer (1 metadata, 2 path rules, ...) made a rule or AI row, so a layer can be re-run alone.
            try db.alter(table: "file_tag") { t in t.add(column: "layer", .integer) }
            // Bumped on every rule change; layer 2 re-runs for files whose last run saw an older revision.
            try db.alter(table: "root") { t in t.add(column: "ruleRevision", .integer).notNull().defaults(to: 0) }

            try db.create(table: "tag_rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rootID", .integer).notNull().references("root", onDelete: .cascade)
                t.column("pattern", .text).notNull()        // folder pattern, relative to the root
                t.column("tag", .text).notNull()            // tag template; {1}, {2} insert what the wildcards matched
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["rootID", "pattern", "tag"])
            }

            // What each layer last saw for each file; a difference means the layer is due again.
            try db.create(table: "file_layer_run") { t in
                t.column("fileID", .integer).notNull().references("file", onDelete: .cascade)
                t.column("layer", .integer).notNull()
                t.column("version", .integer).notNull()
                t.column("sourceSize", .integer).notNull()
                t.column("sourceModified", .datetime).notNull()
                t.column("sourcePath", .text).notNull()
                t.column("complete", .boolean).notNull().defaults(to: true)   // false: content was not readable (placeholder)
                t.column("doneAt", .datetime).notNull()
                t.primaryKey(["fileID", "layer"])
            }

            try db.create(table: "job") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("fileID", .integer).references("file", onDelete: .cascade)
                t.column("state", .text).notNull().defaults(to: "queued")
                    .check { $0 == "queued" || $0 == "running" || $0 == "failed" }
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("provider", .text)
                t.column("model", .text)
                t.column("error", .text)
                t.column("notBefore", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // A file has at most one waiting or running job of a kind. Finished jobs are deleted.
            try db.execute(sql: "CREATE UNIQUE INDEX job_one_pending ON job(kind, fileID) WHERE state IN ('queued', 'running')")
            try db.create(index: "job_on_state", on: "job", columns: ["state", "id"])
        }

        // Operation journal and exact duplicate groups (ADR 0004, 0007).
        migrator.registerMigration("v5-operations-duplicates") { db in
            try db.create(table: "operation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("batch", .text).notNull()          // one user action; undone together, newest first
                t.column("kind", .text).notNull().check { $0 == "trash" || $0 == "clone" || $0 == "move" || $0 == "rename" || $0 == "resize" }
                // The row outlives the file record: undo then restores the file on disk and the next scan indexes it again.
                t.column("fileID", .integer).references("file", onDelete: .setNull)
                t.column("fromPath", .text).notNull()       // trash: the file; clone: the kept copy that is cloned
                t.column("toPath", .text).notNull()         // trash: where it went (filled in once known); clone: the new file
                t.column("holdbackPath", .text)             // where undo put the clone it replaced
                t.column("originalHash", .blob)             // full hash checked just before the action
                t.column("state", .text).notNull()
                    .check { ["pending", "done", "failed", "undoing", "undone"].contains($0) }
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("undoneAt", .datetime)
                t.column("releasedAt", .datetime)           // Step 7: holdback released to the Trash
            }
            try db.create(index: "operation_on_batch", on: "operation", columns: ["batch", "id"])
            try db.create(index: "operation_on_state", on: "operation", columns: ["state"])

            try db.create(table: "dup_group") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull().check { $0 == "exact" || $0 == "near" }
                t.column("contentHash", .blob)              // exact groups: the shared full hash
                t.column("status", .text).notNull().defaults(to: "open").check { $0 == "open" || $0 == "reviewed" }
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["kind", "contentHash"])
            }
            try db.create(table: "dup_member") { t in
                t.column("groupID", .integer).notNull().references("dup_group", onDelete: .cascade)
                t.column("fileID", .integer).notNull().references("file", onDelete: .cascade)
                t.column("similarity", .double)
                t.primaryKey(["groupID", "fileID"])
            }
            try db.create(index: "dup_member_on_file", on: "dup_member", columns: ["fileID"])
        }

        // Managed roots: standardization rule, holdback settings, file links (ADR 0004, 0006).
        migrator.registerMigration("v6-managed-standardization") { db in
            try db.alter(table: "root") { t in
                t.add(column: "standardization", .text)                                  // JSON rule; null = none (opt-in)
                t.add(column: "holdbackDays", .integer).notNull().defaults(to: 30)
                t.add(column: "releaseImmediately", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "operation") { t in
                t.add(column: "resultHash", .blob)          // resize: full hash of the derivative, checked before undo
                t.add(column: "holdbackUntil", .datetime)   // resize: when the original goes to the Trash
            }
            // The original of a resize lives in the holdback, outside any root. The file row stays with the
            // derivative (so tags carry over); this records what it was made from.
            try db.create(table: "file_link") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("derivedFileID", .integer).notNull().references("file", onDelete: .cascade)
                t.column("originalHash", .blob).notNull()
                t.column("originalSize", .integer).notNull()
                t.column("kind", .text).notNull().check { $0 == "resize" }
                t.column("operationID", .integer).references("operation", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "file_link_on_derived", on: "file_link", columns: ["derivedFileID"])
            try db.create(index: "file_link_on_original", on: "file_link", columns: ["originalHash"])
        }

        return migrator
    }

    /// SQL for the last path component of `path`, since SQLite has no basename. Removes the leading
    /// directory part, which ends in a slash and so cannot occur inside the name.
    static func nameSQL(_ path: String) -> String {
        "replace(\(path), rtrim(\(path), replace(\(path), '/', '')), '')"
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

    /// True if a database that already has data (some migration applied) still has migrations to run.
    /// A brand-new database has nothing to back up.
    static func hasPendingMigrationsOnExistingDatabase(_ writer: some DatabaseWriter) throws -> Bool {
        let migrator = makeMigrator()
        return try writer.read { db in
            let completed = try migrator.completedMigrations(db)
            return !completed.isEmpty && completed.count < migrator.migrations.count
        }
    }

    /// True if the database has migrations this build does not know about.
    static func hasBeenSuperseded(_ writer: some DatabaseWriter) throws -> Bool {
        try writer.read { db in try makeMigrator().hasBeenSuperseded(db) }
    }
}
