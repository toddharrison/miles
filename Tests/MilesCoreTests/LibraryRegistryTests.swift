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
