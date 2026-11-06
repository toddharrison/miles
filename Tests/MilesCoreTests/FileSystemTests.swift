import Foundation
import Testing
@testable import MilesCore

@Suite("FileSystem fake")
struct FakeFileSystemTests {
    @Test func placeholdersReportDatalessWithSizeAndNoContent() throws {
        let fs = FakeFileSystem()
        fs.addFile("/Users/a/cloud.pdf", size: 4096, dataless: true)
        fs.addFile("/Users/a/local.pdf", size: 10)
        #expect(try fs.metadata(at: "/Users/a/cloud.pdf").isDataless)
        #expect(try fs.metadata(at: "/Users/a/cloud.pdf").size == 4096)
        #expect(try !fs.metadata(at: "/Users/a/local.pdf").isDataless)
    }

    @Test func moveKeepsFileIdentity() throws {
        let fs = FakeFileSystem()
        fs.addFile("/Users/a/one.txt", size: 1)
        let before = try fs.metadata(at: "/Users/a/one.txt")
        fs.move("/Users/a/one.txt", to: "/Users/a/sub/two.txt")
        #expect(!fs.exists("/Users/a/one.txt"))
        #expect(try fs.metadata(at: "/Users/a/sub/two.txt").fileID == before.fileID)
    }

    @Test func unmountedVolumeHasNoVolumeAndNoMountedLookup() {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Ext", filesystemType: "apfs"))
        #expect(fs.volume(containing: "/Volumes/Ext/x")?.id == "EXT")
        fs.setMounted(false, volumeID: "EXT")
        #expect(fs.mountedVolume(withID: "EXT") == nil)
        #expect(fs.volume(containing: "/Volumes/Ext/x")?.id == "BOOT")
    }

    @Test func exclusiveCreateRefusesExisting() throws {
        let fs = FakeFileSystem()
        try fs.createDirectory(at: "/d")
        try fs.createFileExclusively(Data([1]), at: "/d/f")
        #expect(throws: FileSystemError.alreadyExists("/d/f")) {
            try fs.createFileExclusively(Data([2]), at: "/d/f")
        }
    }
}

@Suite("RealFileSystem")
struct RealFileSystemTests {
    let fs = RealFileSystem()

    @Test func metadataAndExclusiveCreate() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let file = tmp.path + "/a.txt"
        try fs.createFileExclusively(Data("hello".utf8), at: file)
        #expect(throws: FileSystemError.alreadyExists(file)) { try fs.createFileExclusively(Data(), at: file) }

        let meta = try fs.metadata(at: file)
        #expect(meta.size == 5)
        #expect(!meta.isDirectory)
        #expect(!meta.isDataless)
        #expect(try fs.metadata(at: tmp.path).isDirectory)
        #expect(try fs.contentsOfDirectory(at: tmp.path) == ["a.txt"])
        #expect(throws: FileSystemError.notFound(tmp.path + "/nope")) { try fs.metadata(at: tmp.path + "/nope") }
    }

    @Test func temporaryDirectoryIsLocalApfsAndNotSynced() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let volume = try #require(fs.volume(containing: tmp.path))
        #expect(volume.isLocal)
        #expect(LocationValidator.allowedFilesystems.contains(volume.filesystemType))
        #expect(!fs.isInSyncedFolder(tmp.path))
        #expect(fs.mountedVolume(withID: volume.id)?.id == volume.id)
    }

    @Test func iCloudDriveIsSynced() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(fs.isInSyncedFolder(home + "/Library/Mobile Documents/com~apple~CloudDocs/x"))
        #expect(fs.isInSyncedFolder(home + "/Library/CloudStorage/Dropbox/x"))
    }
}
