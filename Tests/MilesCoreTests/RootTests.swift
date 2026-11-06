import Foundation
import Testing
@testable import MilesCore

@Suite("Roots")
struct RootTests {
    let fs = RealFileSystem()

    struct Env {
        let tmp: TempDir
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
    }

    func library(_ name: String, in env: Env, register: Bool = true) throws -> Library {
        let lib = try Library.create(at: env.tmp.path + "/libs/" + name, fileSystem: fs)
        if register { env.registry.register(lib, name: name) }
        return lib
    }

    @Test func addsRootStoredAsVolumePlusRelativePath() throws {
        let env = Env(tmp: try TempDir()); defer { env.tmp.cleanup() }
        let lib = try library("A", in: env); defer { try? lib.close() }
        let dir = try env.tmp.subdirectory("photos")
        let root = try lib.addRoot(at: dir, fileSystem: fs, registry: env.registry)
        #expect(root.mode == "unmanaged")
        #expect(root.location.resolve(fileSystem: fs) == dir)
        #expect(try lib.roots() == [root])
    }

    @Test func refusesNonDirectories() throws {
        let env = Env(tmp: try TempDir()); defer { env.tmp.cleanup() }
        let lib = try library("A", in: env); defer { try? lib.close() }
        let missing = env.tmp.path + "/nope"
        #expect(throws: LibraryError.invalidRoot(missing)) { try lib.addRoot(at: missing, fileSystem: fs, registry: env.registry) }
    }

    @Test func refusesSameNestedAndContainingRootsInOneLibrary() throws {
        let env = Env(tmp: try TempDir()); defer { env.tmp.cleanup() }
        let lib = try library("A", in: env); defer { try? lib.close() }
        let parent = try env.tmp.subdirectory("data")
        let child = try env.tmp.subdirectory("data/sub")
        let sibling = try env.tmp.subdirectory("database") // shares a name prefix, not a path prefix
        try lib.addRoot(at: parent, fileSystem: fs, registry: env.registry)

        #expect(throws: LibraryError.self) { try lib.addRoot(at: parent, fileSystem: fs, registry: env.registry) }
        #expect(throws: LibraryError.self) { try lib.addRoot(at: child, fileSystem: fs, registry: env.registry) }
        try lib.addRoot(at: sibling, fileSystem: fs, registry: env.registry)
        #expect(try lib.roots().count == 2)
    }

    @Test func refusesContainingRoot() throws {
        let env = Env(tmp: try TempDir()); defer { env.tmp.cleanup() }
        let lib = try library("A", in: env); defer { try? lib.close() }
        let child = try env.tmp.subdirectory("data/sub")
        try lib.addRoot(at: child, fileSystem: fs, registry: env.registry)
        #expect(throws: LibraryError.self) {
            try lib.addRoot(at: env.tmp.path + "/data", fileSystem: fs, registry: env.registry)
        }
    }

    @Test func refusesRootsOverlappingAnotherLibraryEvenWhenItIsClosed() throws {
        let env = Env(tmp: try TempDir()); defer { env.tmp.cleanup() }
        let a = try library("A", in: env)
        let dir = try env.tmp.subdirectory("shared/inner")
        try a.addRoot(at: env.tmp.path + "/shared", fileSystem: fs, registry: env.registry)
        try a.close()

        let b = try library("B", in: env); defer { try? b.close() }
        do {
            try b.addRoot(at: dir, fileSystem: fs, registry: env.registry)
            Issue.record("expected an overlap with library A")
        } catch let LibraryError.overlappingRoot(_, _, inLibrary) {
            #expect(inLibrary == "A")
        }
        #expect(try b.roots().isEmpty)
    }

    @Test func refusesWhenAnotherLibraryCannotBeRead() throws {
        let env = Env(tmp: try TempDir()); defer { env.tmp.cleanup() }
        let b = try library("B", in: env); defer { try? b.close() }
        env.registry.register(LibraryRecord(id: UUID(), name: "Drive", location: VolumeLocation(volumeID: "NOT-MOUNTED", relativePath: "Miles")))
        let dir = try env.tmp.subdirectory("anything")
        #expect(throws: LibraryError.otherLibraryUnavailable(name: "Drive")) {
            try b.addRoot(at: dir, fileSystem: fs, registry: env.registry)
        }
        #expect(try b.roots().isEmpty)
    }

    @Test func rootsInDifferentLibrariesWithoutOverlapAreFine() throws {
        let env = Env(tmp: try TempDir()); defer { env.tmp.cleanup() }
        let a = try library("A", in: env); defer { try? a.close() }
        let b = try library("B", in: env); defer { try? b.close() }
        try a.addRoot(at: try env.tmp.subdirectory("one"), fileSystem: fs, registry: env.registry)
        try b.addRoot(at: try env.tmp.subdirectory("two"), fileSystem: fs, registry: env.registry)
    }
}
