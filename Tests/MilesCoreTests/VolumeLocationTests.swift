import Testing
@testable import MilesCore

@Suite("VolumeLocation")
struct VolumeLocationTests {
    @Test func externalPathIsStoredRelativeToVolume() {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Photos", filesystemType: "apfs"))
        let loc = VolumeLocation.make(path: "/Volumes/Photos/Trips/2024", fileSystem: fs)
        #expect(loc == VolumeLocation(volumeID: "EXT", relativePath: "Trips/2024"))
    }

    @Test func bootVolumePathIsRelativeToRoot() {
        let fs = FakeFileSystem()
        let loc = VolumeLocation.make(path: "/Users/a/Pictures", fileSystem: fs)
        #expect(loc == VolumeLocation(volumeID: "BOOT", relativePath: "Users/a/Pictures"))
        #expect(loc?.resolve(fileSystem: fs) == "/Users/a/Pictures")
    }

    @Test func survivesDriveMountingElsewhere() throws {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Photos", filesystemType: "apfs"))
        let loc = try #require(VolumeLocation.make(path: "/Volumes/Photos/Trips", fileSystem: fs))
        fs.remount(volumeID: "EXT", at: "/Volumes/Photos 2")
        #expect(loc.resolve(fileSystem: fs) == "/Volumes/Photos 2/Trips")
    }

    @Test func unmountedVolumeDoesNotResolve() throws {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Photos", filesystemType: "apfs"))
        let loc = try #require(VolumeLocation.make(path: "/Volumes/Photos/Trips", fileSystem: fs))
        fs.setMounted(false, volumeID: "EXT")
        #expect(loc.resolve(fileSystem: fs) == nil)
    }

    @Test func overlapIsComponentWiseAndCaseInsensitive() {
        func loc(_ p: String, vol: String = "V") -> VolumeLocation { VolumeLocation(volumeID: vol, relativePath: p) }
        #expect(loc("a/b").overlaps(loc("a/b")))
        #expect(loc("a/b").overlaps(loc("a/b/c")))
        #expect(loc("a/b/c").overlaps(loc("a/b")))
        #expect(loc("A/B").overlaps(loc("a/b/c")))
        #expect(loc("").overlaps(loc("anything")))
        #expect(!loc("a/b").overlaps(loc("a/bc")))
        #expect(!loc("a/b").overlaps(loc("a/c")))
        #expect(!loc("a").overlaps(loc("a", vol: "OTHER")))
    }
}
