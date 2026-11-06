import Foundation
import GRDB
import Testing
@testable import MilesCore

@Suite("Backup and restore")
struct BackupTests {
    let fs = RealFileSystem()

    /// A library with one root, one file and one tag.
    func makeLibrary(_ tmp: TempDir) throws -> (Library, fileID: Int64) {
        let library = try Library.create(at: tmp.path + "/Lib", fileSystem: fs)
        try library.database.write { db in
            try db.execute(sql: "INSERT INTO root (volumeID, relativePath, mode, createdAt) VALUES ('v', 'photos', 'unmanaged', ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO file (rootID, relativePath, volumeID, fileID, size, modified, firstSeen, lastSeen) VALUES (1, 'a/cat.jpg', 'v', 1, 10, ?, ?, ?)",
                           arguments: [Date(), Date(), Date()])
        }
        let id = try library.database.read { try Int64.fetchOne($0, sql: "SELECT id FROM file")! }
        try library.addTag("animal:cat", toFile: id)
        return (library, id)
    }

    func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    @Test func snapshotIsVerifiedNamedAndExported() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp); defer { try? library.close() }
        let info = try library.createBackup(kind: .manual)

        #expect(info.path.hasPrefix(library.directory + "/backups/"))
        #expect(info.schemaVersion == LibraryDatabase.currentSchemaVersion)
        #expect(try library.backups().map(\.name) == [info.name])
        try Library.verifyIntegrity(atPath: info.path)

        let export = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try #require(info.exportPath)))) as! [String: Any]
        let fileTags = export["fileTags"] as! [[String: Any]]
        #expect(fileTags.count == 1)
        #expect(fileTags[0]["tag"] as? String == "animal:cat")
        #expect(fileTags[0]["path"] as? String == "a/cat.jpg")
        #expect(export["formatVersion"] as? Int == 1)
    }

    @Test func safetySnapshotsHaveNoExportAndNoPartialFilesRemain() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp); defer { try? library.close() }
        let info = try library.createBackup(kind: .preBulk)
        #expect(info.exportPath == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: library.backupsDirectory)
        #expect(!names.contains { $0.hasSuffix(".partial") })
    }

    @Test func scheduleTakesASnapshotOnlyWhenDue() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp); defer { try? library.close() }
        let t0 = day(0)
        #expect(try library.runScheduledBackupIfDue(now: t0) != nil)
        #expect(try library.runScheduledBackupIfDue(now: t0.addingTimeInterval(3600)) == nil)
        #expect(try library.runScheduledBackupIfDue(now: t0.addingTimeInterval(25 * 3600)) != nil)
        #expect(try library.backups().count == 2)
    }

    @Test func rotationKeepsDailiesAndWeekliesAndSafetyAndManual() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp); defer { try? library.close() }
        var policy = BackupPolicy()
        policy.dailies = 3; policy.weeklies = 2; policy.safetyKept = 1
        for n in 0..<30 { try library.createBackup(kind: .scheduled, now: day(n)) }
        try library.createBackup(kind: .manual, now: day(0))
        try library.createBackup(kind: .preBulk, now: day(1))
        try library.createBackup(kind: .preBulk, now: day(2))
        try library.rotateBackups(policy: policy, now: day(30))

        let kept = try library.backups()
        let scheduled = kept.filter { $0.kind == .scheduled }
        // The newest three days are kept, plus the newest of each of the last two weeks.
        #expect(Set(scheduled.map(\.createdAt)).isSuperset(of: [day(29), day(28), day(27)]))
        #expect(scheduled.count >= 3 && scheduled.count <= 5)
        #expect(!scheduled.contains { $0.createdAt == day(0) })
        #expect(kept.filter { $0.kind == .manual }.count == 1)
        #expect(kept.filter { $0.kind == .preBulk }.map(\.createdAt) == [day(2)])
        // Exports go with their snapshots.
        let jsons = try FileManager.default.contentsOfDirectory(atPath: library.backupsDirectory).filter { $0.hasSuffix(".json") }
        #expect(jsons.count == kept.filter { $0.exportPath != nil }.count)
    }

    @Test func removingARootSnapshotsFirstAndReusesItWithinTheWindow() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp); defer { try? library.close() }
        #expect(try library.removeRoot(id: 1) == 1)
        let backups = try library.backups()
        #expect(backups.map(\.kind) == [.preBulk])
        // The snapshot still has what the removal dropped.
        let files = try DatabaseQueue(path: backups[0].path, configuration: LibraryDatabase.configuration(readonly: true))
            .read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file")! }
        #expect(files == 1)
    }

    @Test func removingAnEmptyRootNeedsNoSnapshot() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let library = try Library.create(at: tmp.path + "/Lib", fileSystem: fs); defer { try? library.close() }
        try library.database.write { try $0.execute(sql: "INSERT INTO root (volumeID, relativePath, mode, createdAt) VALUES ('v', 'x', 'unmanaged', ?)", arguments: [Date()]) }
        try library.removeRoot(id: 1)
        #expect(try library.backups().isEmpty)
    }

    /// Writes a library folder whose database stops at an older schema.
    func makeOldLibrary(_ dir: String, upTo migration: String, version: Int) throws -> UUID {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = UUID()
        let pool = try DatabasePool(path: dir + "/library.sqlite", configuration: LibraryDatabase.configuration())
        try LibraryDatabase.makeMigrator().migrate(pool, upTo: migration)
        try pool.write { db in
            try db.execute(sql: "INSERT INTO library_meta (key, value) VALUES (?, ?)", arguments: [LibraryDatabase.metaLibraryIDKey, id.uuidString])
            try db.execute(sql: "INSERT OR REPLACE INTO library_meta (key, value) VALUES (?, ?)", arguments: [LibraryDatabase.metaSchemaVersionKey, String(version)])
        }
        try pool.close()
        return id
    }

    @Test func openingAnOlderLibraryTakesAPreMigrationSnapshotFirst() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Old"
        _ = try makeOldLibrary(dir, upTo: "v1-root-file-meta", version: 1)
        let library = try Library.open(at: dir, fileSystem: fs, owner: testOwner()); defer { try? library.close() }
        #expect(try library.schemaVersion == LibraryDatabase.currentSchemaVersion)
        let backups = try library.backups()
        #expect(backups.count == 1)
        #expect(backups[0].kind == .preMigration)
        #expect(backups[0].schemaVersion == 1)
        #expect(try LibraryRestore.preview(snapshotPath: backups[0].path).willMigrate)
    }

    @Test func openingAnUpToDateLibraryTakesNoSnapshot() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp)
        try library.close()
        let reopened = try Library.open(at: tmp.path + "/Lib", fileSystem: fs, owner: testOwner()); defer { try? reopened.close() }
        #expect(try reopened.backups().isEmpty)
    }

    @Test func restoreBringsBackDeletedDataAndKeepsWhatItReplaced() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, fileID) = try makeLibrary(tmp)
        let snapshot = try library.createBackup(kind: .manual)
        try library.removeTag("animal:cat", fromFile: fileID)
        try library.addTag("later:tag", toFile: fileID)
        // A cached thumbnail whose file id may mean something else after the rollback.
        let thumb = library.thumbnailPath(fileID: fileID, size: .medium)
        try FileManager.default.createDirectory(atPath: (thumb as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: thumb))
        let dir = library.directory
        try library.close()

        let result = try LibraryRestore.restore(snapshotPath: snapshot.path, toLibraryAt: dir, fileSystem: fs, owner: testOwner())
        #expect(!result.migrated)
        let kept = try #require(result.safetyBackup)
        #expect(kept.contains("pre-restore"))

        let restored = try Library.open(at: dir, fileSystem: fs, owner: testOwner()); defer { try? restored.close() }
        #expect(try restored.tags(forFile: fileID).map(\.name.description) == ["animal:cat"])
        #expect(!FileManager.default.fileExists(atPath: thumb))
        // The database it replaced is still there, with the later tag.
        let before = try DatabaseQueue(path: kept, configuration: LibraryDatabase.configuration(readonly: true))
            .read { try String.fetchAll($0, sql: "SELECT n.name || ':' || t.name FROM tag t JOIN namespace n ON n.id = t.namespaceID ORDER BY 1") }
        #expect(before.contains("later:tag"))
    }

    @Test func restoringAnOlderSnapshotMigratesForward() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let oldDir = tmp.path + "/Old"
        let id = try makeOldLibrary(oldDir, upTo: "v1-root-file-meta", version: 1)
        // A real snapshot of it, as a pre-migration backup would be (VACUUM INTO, not a live WAL database).
        let oldSnapshot = tmp.path + "/old-snapshot.sqlite"
        try DatabaseQueue(path: oldDir + "/library.sqlite").writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [oldSnapshot]) }

        // The live library has the same identity but is a current-schema database.
        let dir = tmp.path + "/Lib"
        let live = try Library.create(at: dir, fileSystem: fs)
        try live.database.write { try $0.execute(sql: "UPDATE library_meta SET value = ? WHERE key = 'library_id'", arguments: [id.uuidString]) }
        try live.close()

        let preview = try LibraryRestore.preview(snapshotPath: oldSnapshot)
        #expect(preview.schemaVersion == 1 && preview.willMigrate)
        let result = try LibraryRestore.restore(snapshotPath: oldSnapshot, toLibraryAt: dir, fileSystem: fs, owner: testOwner())
        #expect(result.migrated)

        let library = try Library.open(at: dir, fileSystem: fs, owner: testOwner()); defer { try? library.close() }
        #expect(try library.schemaVersion == LibraryDatabase.currentSchemaVersion)
        let tables = try library.database.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        #expect(tables.contains("tag") && tables.contains("thumbnail") && tables.contains("file_fts"))
        // Restoring is not a pre-migration event: the open found nothing left to migrate.
        #expect(try library.backups().allSatisfy { $0.kind == .preRestore })
    }

    @Test func restoreRefusesANewerSnapshotAndAnotherLibrarysSnapshot() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp)
        let dir = library.directory
        let mine = try library.createBackup(kind: .manual)
        try library.close()

        // Another library's snapshot.
        let other = try Library.create(at: tmp.path + "/Other", fileSystem: fs)
        let theirs = try other.createBackup(kind: .manual)
        try other.close()
        #expect(throws: BackupError.snapshotFromDifferentLibrary) {
            try LibraryRestore.restore(snapshotPath: theirs.path, toLibraryAt: dir, fileSystem: fs, owner: testOwner())
        }

        // A snapshot from a newer schema.
        let newer = tmp.path + "/newer.sqlite"
        try FileManager.default.copyItem(atPath: mine.path, toPath: newer)
        try DatabaseQueue(path: newer).write {
            try $0.execute(sql: "UPDATE library_meta SET value = '999' WHERE key = 'schema_version'")
        }
        #expect(throws: LibraryError.newerSchema(found: 999, supported: LibraryDatabase.currentSchemaVersion)) {
            try LibraryRestore.restore(snapshotPath: newer, toLibraryAt: dir, fileSystem: fs, owner: testOwner())
        }
        // The live database is untouched by both refusals.
        let again = try Library.open(at: dir, fileSystem: fs, owner: testOwner()); defer { try? again.close() }
        #expect(try again.fileCount() == 1)
    }

    @Test func aCorruptSnapshotIsRefusedAndAnUnreadableLiveDatabaseIsKeptRaw() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp)
        let dir = library.directory
        let good = try library.createBackup(kind: .manual)
        try library.close()

        let bad = tmp.path + "/bad.sqlite"
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: bad))
        #expect(throws: BackupError.self) {
            try LibraryRestore.restore(snapshotPath: bad, toLibraryAt: dir, fileSystem: fs, owner: testOwner())
        }

        // Damage the live database, then restore the good snapshot over it.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dir + "/library.sqlite" + suffix) }
        try Data("garbage garbage garbage".utf8).write(to: URL(fileURLWithPath: dir + "/library.sqlite"))
        let result = try LibraryRestore.restore(snapshotPath: good.path, toLibraryAt: dir, fileSystem: fs, owner: testOwner())
        #expect(try #require(result.safetyBackup).contains("damaged-"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(result.safetyBackup))) == Data("garbage garbage garbage".utf8))
        let restored = try Library.open(at: dir, fileSystem: fs, owner: testOwner()); defer { try? restored.close() }
        #expect(try restored.fileCount() == 1)
    }

    @Test func restoreNeedsTheLibraryClosed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp); defer { try? library.close() }
        let snapshot = try library.createBackup(kind: .manual)
        #expect(throws: LibraryError.self) {
            try LibraryRestore.restore(snapshotPath: snapshot.path, toLibraryAt: library.directory, fileSystem: fs, owner: testOwner(host: "other-mac"))
        }
    }

    @Test func resolveSnapshotByNameLatestAndMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (library, _) = try makeLibrary(tmp); defer { try? library.close() }
        _ = try library.createBackup(kind: .manual, now: day(0))
        let newest = try library.createBackup(kind: .manual, now: day(1))
        #expect(try LibraryRestore.resolveSnapshot("latest", libraryDirectory: library.directory) == newest.path)
        #expect(try LibraryRestore.resolveSnapshot(newest.name, libraryDirectory: library.directory) == newest.path)
        #expect(throws: BackupError.snapshotNotFound("nope")) { try LibraryRestore.resolveSnapshot("nope", libraryDirectory: library.directory) }
    }
}
