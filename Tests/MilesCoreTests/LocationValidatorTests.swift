import Testing
@testable import MilesCore

@Suite("Library location validation")
struct LocationValidatorTests {
    @Test func acceptsLocalApfs() throws {
        let fs = FakeFileSystem()
        try fs.createDirectory(at: "/Users/a/Library/Application Support")
        try LocationValidator.validate("/Users/a/Library/Application Support/Miles", fileSystem: fs)
    }

    @Test func refusesUnmountedDriveInsteadOfWritingToBootVolume() {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Travel", filesystemType: "apfs"), mounted: false)
        #expect(throws: LibraryError.locationUnavailable("/Volumes/Travel/Miles")) {
            try LocationValidator.validate("/Volumes/Travel/Miles", fileSystem: fs)
        }
    }

    @Test func refusesSyncedFolders() throws {
        let fs = FakeFileSystem()
        try fs.createDirectory(at: "/Users/a/iCloud")
        fs.markSynced("/Users/a/iCloud")
        #expect(throws: LibraryError.syncedFolder(path: "/Users/a/iCloud/Miles")) {
            try LocationValidator.validate("/Users/a/iCloud/Miles", fileSystem: fs)
        }
    }

    @Test func refusesNetworkShares() {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "NAS", mountPoint: "/Volumes/NAS", filesystemType: "smbfs", isLocal: false))
        #expect(throws: LibraryError.notLocalFilesystem(path: "/Volumes/NAS/Miles")) {
            try LocationValidator.validate("/Volumes/NAS/Miles", fileSystem: fs)
        }
    }

    @Test func refusesExFAT() {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "X", mountPoint: "/Volumes/Stick", filesystemType: "exfat"))
        #expect(throws: LibraryError.unsupportedFilesystem(path: "/Volumes/Stick/Miles", type: "exfat")) {
            try LocationValidator.validate("/Volumes/Stick/Miles", fileSystem: fs)
        }
    }

    @Test func acceptsMountedExternalApfs() throws {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Travel", filesystemType: "apfs"))
        let v = try LocationValidator.validate("/Volumes/Travel/Miles", fileSystem: fs)
        #expect(v.id == "EXT")
    }
}
