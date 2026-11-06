import Foundation
import Testing
@testable import MilesCore

@Suite("Library registry")
struct LibraryRegistryTests {
    let fs = RealFileSystem()

    @Test func firstLibraryBecomesDefaultAndPersists() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefs = InMemoryPreferences()
        let registry = LibraryRegistry(preferences: prefs)
        let library = try Library.create(at: tmp.path + "/Home", fileSystem: fs)
        defer { try? library.close() }
        registry.register(library, name: "Home")

        let again = LibraryRegistry(preferences: prefs) // a fresh instance reads the same preferences
        #expect(again.libraries.map(\.name) == ["Home"])
        #expect(again.defaultLibraryID == library.id)
    }

    @Test func setDefaultRequiresKnownLibrary() throws {
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let unknown = UUID()
        #expect(throws: LibraryError.unknownLibrary(unknown)) { try registry.setDefault(unknown) }
    }

    @Test func unregisterMovesDefaultAndKeepsFilesOnDisk() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let a = try Library.create(at: tmp.path + "/A", fileSystem: fs)
        let b = try Library.create(at: tmp.path + "/B", fileSystem: fs)
        defer { try? a.close(); try? b.close() }
        registry.register(a, name: "A"); registry.register(b, name: "B")
        registry.unregister(a.id)
        #expect(registry.defaultLibraryID == b.id)
        #expect(fs.exists(a.databasePath))
    }

    @Test func openByIDResolvesLocationThroughVolumeIdentity() throws {
        // The registry stores volume ID plus relative path and resolves it through the filesystem at open time.
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let library = try Library.create(at: tmp.path + "/Portable", fileSystem: fs)
        let id = library.id
        let volume = try #require(fs.volume(containing: tmp.path))
        try library.close()

        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        registry.register(LibraryRecord(id: id, name: "Portable", location: VolumeLocation.make(path: tmp.path + "/Portable", fileSystem: fs)!))
        let reopened = try registry.open(id, fileSystem: fs)
        defer { try? reopened.close() }
        #expect(reopened.id == id)
        #expect(registry.libraries.first?.location.volumeID == volume.id)
    }

    @Test func unmountedDriveIsReportedAndNothingIsCreated() {
        let fake = FakeFileSystem()
        let id = UUID()
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        registry.register(LibraryRecord(id: id, name: "Travel", location: VolumeLocation(volumeID: "EXT", relativePath: "Miles")))
        #expect(throws: LibraryError.locationUnavailable("Travel")) { try registry.open(id, fileSystem: fake) }
        #expect(!fake.exists("/Volumes/Travel"))
    }

    @Test func registeredPathFollowsRemount() {
        let fake = FakeFileSystem()
        fake.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Travel", filesystemType: "apfs"))
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let record = LibraryRecord(id: UUID(), name: "Travel", location: VolumeLocation(volumeID: "EXT", relativePath: "Miles"))
        registry.register(record)
        #expect(registry.path(of: record, fileSystem: fake) == "/Volumes/Travel/Miles")
        fake.remount(volumeID: "EXT", at: "/Volumes/Other Mac")
        #expect(registry.path(of: record, fileSystem: fake) == "/Volumes/Other Mac/Miles")
        fake.setMounted(false, volumeID: "EXT")
        #expect(registry.path(of: record, fileSystem: fake) == nil)
    }
}

@Suite("Library availability and drive reconnect")
struct LibraryAvailabilityTests {
    let fs = RealFileSystem()

    @Test func driveNotMountedThenReconnectedAtAnotherMountPoint() throws {
        // SQLite needs a real file, so the fake volume only stands in for where the library folder is.
        let fake = FakeFileSystem()
        fake.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Travel", filesystemType: "apfs"))
        fake.addFile("/Volumes/Travel/Miles/library.sqlite", size: 1)
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let record = LibraryRecord(id: UUID(), name: "Travel", location: VolumeLocation(volumeID: "EXT", relativePath: "Miles"))
        registry.register(record)
        #expect(registry.availability(of: record, fileSystem: fake) == .ready(path: "/Volumes/Travel/Miles"))

        fake.setMounted(false, volumeID: "EXT")
        #expect(registry.availability(of: record, fileSystem: fake) == .driveNotMounted)
        #expect(throws: LibraryError.locationUnavailable("Travel")) { try registry.open(record.id, fileSystem: fake) }

        fake.remount(volumeID: "EXT", at: "/Volumes/Other Mac")
        #expect(registry.availability(of: record, fileSystem: fake) == .ready(path: "/Volumes/Other Mac/Miles"))
    }

    @Test func mountedDriveWithoutLibraryIsNotALibrary() {
        let fake = FakeFileSystem()
        fake.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Travel", filesystemType: "apfs"))
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let record = LibraryRecord(id: UUID(), name: "Travel", location: VolumeLocation(volumeID: "EXT", relativePath: "Miles"))
        registry.register(record)
        #expect(registry.availability(of: record, fileSystem: fake) == .notALibrary(path: "/Volumes/Travel/Miles"))
        #expect(!fake.exists("/Volumes/Travel/Miles"))
    }

    @Test func lockStatesAreReportedWithoutTakingTheLock() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let crashed = try Library.create(at: dir, fileSystem: fs, owner: testOwner(host: "mac-a", pid: 5))
        _ = crashed // never closed: the lock file stays
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let record = LibraryRecord(id: crashed.id, name: "Lib", location: VolumeLocation.make(path: dir, fileSystem: fs)!)
        registry.register(record)

        // Another Mac: cannot be verified, so it needs the user's confirmation.
        let other = registry.availability(of: record, fileSystem: fs, owner: testOwner(host: "mac-b", pid: 1))
        guard case .locked(_, .unknown) = other else { Issue.record("expected unknown lock, got \(other)"); return }
        #expect(other.needsTakeOverConfirmation && !other.canOpen)

        // Same Mac, process alive: still needs confirmation. Process gone: reclaimed without asking.
        #expect(registry.availability(of: record, fileSystem: fs, owner: testOwner(host: "mac-a", pid: 1)).needsTakeOverConfirmation)
        let dead = registry.availability(of: record, fileSystem: fs, owner: testOwner(host: "mac-a", pid: 1, alive: { _ in false }))
        #expect(dead.canOpen && !dead.needsTakeOverConfirmation)

        // Looking never changed the lock.
        #expect(LibraryLock.inspect(directory: dir, fileSystem: fs, owner: testOwner())?.holder?.pid == 5)

        // The user confirms: takeover opens it and the lock is theirs.
        let taken = try registry.open(record.id, fileSystem: fs, owner: testOwner(host: "mac-b", pid: 1), takeOverLock: true)
        #expect(LibraryLock.inspect(directory: dir, fileSystem: fs, owner: testOwner())?.holder?.host == "mac-b")
        try taken.close()
    }

    @Test func newerSchemaIsReportedAndNothingIsTouched() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.path + "/Lib"
        let library = try Library.create(at: dir, fileSystem: fs)
        try library.database.write { try $0.execute(sql: "UPDATE library_meta SET value = '99' WHERE key = 'schema_version'") }
        let id = library.id
        try library.close()
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let record = LibraryRecord(id: id, name: "Lib", location: VolumeLocation.make(path: dir, fileSystem: fs)!)
        registry.register(record)

        let availability = registry.availability(of: record, fileSystem: fs)
        #expect(availability == .newerSchema(found: 99, supported: LibraryDatabase.currentSchemaVersion))
        #expect(!availability.canOpen && !availability.needsTakeOverConfirmation)
        #expect(throws: LibraryError.newerSchema(found: 99, supported: LibraryDatabase.currentSchemaVersion)) {
            try registry.open(id, fileSystem: fs, takeOverLock: true)   // takeover never overrides the version gate
        }
        #expect(try LibraryDatabase.recordedSchemaVersion(atPath: dir + "/library.sqlite") == 99)
    }

    @Test func unmountedRootKeepsItsFilesAndReconnects() throws {
        let fake = FakeFileSystem()
        fake.addVolume(VolumeInfo(id: "USB", mountPoint: "/Volumes/USB", filesystemType: "apfs"))
        fake.addFile("/Volumes/USB/pics/a.jpg", size: 1)
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try Library.create(at: tmp.path + "/lib", fileSystem: fs); defer { try? lib.close() }
        let root = try lib.addRoot(at: "/Volumes/USB/pics", fileSystem: fake, registry: LibraryRegistry(preferences: InMemoryPreferences()))
        try lib.scan(rootID: root.id, fileSystem: fake)

        fake.setMounted(false, volumeID: "USB")
        #expect(try lib.rootStatuses(fileSystem: fake).map(\.isAvailable) == [false])
        #expect(try lib.fileCount() == 1)
        fake.remount(volumeID: "USB", at: "/Volumes/USB 2")
        #expect(try lib.rootStatuses(fileSystem: fake).first?.path == "/Volumes/USB 2/pics")
    }
}
