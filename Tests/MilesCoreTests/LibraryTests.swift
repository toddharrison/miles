import Foundation
import GRDB
import Testing
@testable import MilesCore

@Suite("Library create and open")
struct LibraryTests {
    let fs = RealFileSystem()

    @Test func createMakesDatabaseWithInitialSchema() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let library = try Library.create(at: tmp.path + "/Lib", fileSystem: fs)
        defer { try? library.close() }

        #expect(fs.exists(library.databasePath))
        #expect(try library.schemaVersion == 1)
        let tables = try library.database.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        #expect(tables.contains("root"))
        #expect(tables.contains("file"))
        #expect(tables.contains("library_meta"))
        #expect(tables.contains("grdb_migrations"))
    }

    @Test func fileTableStoresTheFieldsInDataModel() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let library = try Library.create(at: tmp.path + "/Lib", fileSystem: fs)
        defer { try? library.close() }
        let columns = try library.database.read { try Row.fetchAll($0, sql: "PRAGMA table_info(file)").map { $0["name"] as String } }
        for name in ["rootID", "relativePath", "volumeID", "fileID", "size", "modified", "kind", "icloudStatus",
                     "partialHash", "fullHash", "firstSeen", "lastSeen", "missingSince"] {
            #expect(columns.contains(name), "file.\(name) missing")
        }
    }

    @Test func createRefusesToOverwriteExistingLibrary() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        try Library.create(at: dir, fileSystem: fs).close()
        #expect(throws: LibraryError.alreadyExists(dir)) { try Library.create(at: dir, fileSystem: fs) }
    }

    @Test func openRoundTripsIdentity() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let created = try Library.create(at: dir, fileSystem: fs)
        let id = created.id
        try created.close()
        let reopened = try Library.open(at: dir, fileSystem: fs)
        defer { try? reopened.close() }
        #expect(reopened.id == id)
        #expect(fs.exists(dir + "/lock.json")) // lock held while open
    }

    @Test func closeReleasesLock() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let library = try Library.create(at: dir, fileSystem: fs)
        #expect(fs.exists(dir + "/lock.json"))
        try library.close()
        #expect(!fs.exists(dir + "/lock.json"))
    }

    @Test func secondOpenerIsRefused() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let first = try Library.create(at: dir, fileSystem: fs)
        defer { try? first.close() }
        do {
            _ = try Library.open(at: dir, fileSystem: fs)
            Issue.record("expected the second open to be refused")
        } catch let LibraryError.locked(_, staleness) {
            #expect(staleness == .live)
        }
    }

    @Test func staleLockCanBeTakenOver() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let crashed = try Library.create(at: dir, fileSystem: fs, owner: testOwner(host: "other-mac", pid: 5))
        _ = crashed // never closed: simulates a crash on another Mac, lock file stays

        let me = testOwner(host: "this-mac", pid: 9)
        #expect(throws: LibraryError.locked(holder: LibraryLock.inspect(directory: dir, fileSystem: fs, owner: me)?.holder, staleness: .unknown)) {
            try Library.open(at: dir, fileSystem: fs, owner: me)
        }
        let taken = try Library.open(at: dir, fileSystem: fs, owner: me, takeOverLock: true)
        try taken.close()
    }

    @Test func refusesNewerSchemaAndLeavesDatabaseUntouched() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let library = try Library.create(at: dir, fileSystem: fs)
        try library.database.write { db in
            try db.execute(sql: "UPDATE library_meta SET value = '99' WHERE key = 'schema_version'")
        }
        try library.close()

        #expect(throws: LibraryError.newerSchema(found: 99, supported: 1)) { try Library.open(at: dir, fileSystem: fs) }
        // Refusal released the lock, and nothing was migrated or rewritten.
        #expect(!fs.exists(dir + "/lock.json"))
        #expect(try LibraryDatabase.recordedSchemaVersion(atPath: dir + "/library.sqlite") == 99)
    }

    @Test func refusesDatabaseWithUnknownMigration() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let library = try Library.create(at: dir, fileSystem: fs)
        try library.database.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v2-from-the-future')")
        }
        try library.close()
        #expect(throws: LibraryError.self) { try Library.open(at: dir, fileSystem: fs) }
        #expect(!fs.exists(dir + "/lock.json"))
    }

    @Test func openingMissingLocationNeverCreatesLibrary() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Gone"
        #expect(throws: LibraryError.locationUnavailable(dir)) { try Library.open(at: dir, fileSystem: fs) }
        #expect(!fs.exists(dir))
    }

    @Test func openingFolderWithoutDatabaseIsNotALibrary() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try tmp.subdirectory("Empty")
        #expect(throws: LibraryError.notALibrary(dir)) { try Library.open(at: dir, fileSystem: fs) }
        #expect(!fs.exists(dir + "/library.sqlite"))
    }

    @Test func createOnUnmountedDriveWritesNothing() {
        let fake = FakeFileSystem()
        fake.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Travel", filesystemType: "apfs"), mounted: false)
        #expect(throws: LibraryError.locationUnavailable("/Volumes/Travel/Miles")) {
            try Library.create(at: "/Volumes/Travel/Miles", fileSystem: fake)
        }
        #expect(!fake.exists("/Volumes/Travel"))
    }

    @Test func createInSyncedFolderIsRefused() throws {
        let fake = FakeFileSystem()
        try fake.createDirectory(at: "/Users/a/iCloud")
        fake.markSynced("/Users/a/iCloud")
        #expect(throws: LibraryError.syncedFolder(path: "/Users/a/iCloud/Miles")) {
            try Library.create(at: "/Users/a/iCloud/Miles", fileSystem: fake)
        }
        #expect(!fake.exists("/Users/a/iCloud/Miles"))
    }
}
