import Foundation
import Testing
@testable import MilesCore

@Suite("Scanner")
struct ScannerTests {
    /// A real library database (SQLite needs a real file) scanning a fake filesystem.
    struct Env {
        let tmp: TempDir
        let fs = FakeFileSystem()
        let library: Library
        let registry = LibraryRegistry(preferences: InMemoryPreferences())
        let rootPath: String
        let rootID: Int64

        init(rootPath: String = "/Fake/photos") throws {
            tmp = try TempDir()
            library = try Library.create(at: tmp.path + "/lib", fileSystem: RealFileSystem())
            self.rootPath = rootPath
            try fs.createDirectory(at: rootPath)
            rootID = try library.addRoot(at: rootPath, fileSystem: fs, registry: registry).id
        }

        func close() { try? library.close(); tmp.cleanup() }

        @discardableResult
        func scan(_ scope: ScanScope = .full, grace: TimeInterval = 30 * 86400, now: Date = Date()) throws -> ScanResult {
            try library.scan(rootID: rootID, scope: scope, fileSystem: fs, options: ScanOptions(gracePeriod: grace, now: { now }))
        }

        func paths(includeMissing: Bool = false) throws -> [String] {
            try library.files(rootID: rootID, includeMissing: includeMissing).map(\.relativePath)
        }
    }

    @Test func reportsProgressAfterEachBatch() throws {
        let env = try Env(); defer { env.close() }
        for i in 0..<5 { env.fs.addFile("/Fake/photos/f\(i).txt", size: 1) }
        let seen = Locked<[Int]>([])
        try env.library.scan(rootID: env.rootID, fileSystem: env.fs,
                             options: ScanOptions(batchSize: 2, progress: { n in seen.withLock { $0.append(n) } }))
        #expect(seen.withLock { $0 } == [2, 4, 5])
    }

    @Test func removesObsoleteThumbnailSizesOnly() throws {
        let env = try Env(); defer { env.close() }
        let base = env.library.directory + "/thumbnails"
        for size in ["128", "256", "512"] { try FileManager.default.createDirectory(atPath: base + "/" + size, withIntermediateDirectories: true) }
        env.library.removeObsoleteThumbnailSizes()
        let left = try FileManager.default.contentsOfDirectory(atPath: base).sorted()
        #expect(left == ["256"])
    }

    @Test func indexesFilesWithMetadata() throws {
        let env = try Env(); defer { env.close() }
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        env.fs.addFile("/Fake/photos/a.jpg", size: 100, modified: when)
        env.fs.addFile("/Fake/photos/sub/deep/b.mov", size: 2_000)
        env.fs.addFile("/Fake/photos/notes.txt", size: 5)
        env.fs.addFile("/Fake/photos/data.xyzunknown", size: 5)

        let result = try env.scan()
        #expect(result.added == 4)
        let files = try env.library.files(rootID: env.rootID)
        #expect(files.map(\.relativePath) == ["a.jpg", "data.xyzunknown", "notes.txt", "sub/deep/b.mov"])
        let a = try #require(files.first { $0.relativePath == "a.jpg" })
        #expect(a.size == 100)
        #expect(abs(a.modified.timeIntervalSince(when)) < 0.01)
        #expect(a.kind == "image")
        #expect(a.icloudStatus == "local")
        #expect(files.first { $0.relativePath == "sub/deep/b.mov" }?.kind == "video")
        #expect(files.first { $0.relativePath == "notes.txt" }?.kind == "text")
        #expect(files.first { $0.relativePath == "data.xyzunknown" }?.kind == "other")
    }

    @Test func rescanOfUnchangedTreeChangesNothing() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        env.fs.addFile("/Fake/photos/b.jpg", size: 2)
        try env.scan()
        let before = try env.library.files(rootID: env.rootID)
        let again = try env.scan()
        #expect(again.unchanged == 2)
        #expect(again.added == 0 && again.updated == 0 && again.markedMissing == 0)
        #expect(try env.library.files(rootID: env.rootID) == before)
    }

    @Test func changedFileIsUpdatedAndItsHashesAreCleared() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        try env.library.database.write { try $0.execute(sql: "UPDATE file SET fullHash = x'01', partialHash = x'02'") }

        env.fs.addFile("/Fake/photos/a.jpg", size: 99, modified: Date(timeIntervalSince1970: 5))
        let result = try env.scan()
        #expect(result.updated == 1)
        #expect(try env.library.files(rootID: env.rootID).first?.size == 99)
        let hashes = try env.library.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file WHERE fullHash IS NOT NULL OR partialHash IS NOT NULL") }
        #expect(hashes == 0)
    }

    @Test func unchangedFileKeepsItsHashes() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        try env.library.database.write { try $0.execute(sql: "UPDATE file SET fullHash = x'01'") }
        try env.scan()
        let n = try env.library.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file WHERE fullHash IS NOT NULL") }
        #expect(n == 1)
    }

    // MARK: Exclusions

    @Test func appOwnedLibrariesAreNeverIndexedOrEntered() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/keep.jpg", size: 1)
        env.fs.addFile("/Fake/photos/Pictures/My Photos.photoslibrary/originals/0/x.heic", size: 1)
        env.fs.addFile("/Fake/photos/Music/Music.MUSICLIBRARY/lib.bin", size: 1)
        env.fs.addFile("/Fake/photos/Pictures/ok.png", size: 1)
        try env.scan()
        #expect(try env.paths() == ["Pictures/ok.png", "keep.jpg"])
        #expect(!env.fs.listedDirectories.contains { $0.contains(".photoslibrary") || $0.lowercased().contains(".musiclibrary") })
    }

    @Test func userExclusionsByNameAndByPath() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a/node_modules/x.js", size: 1)
        env.fs.addFile("/Fake/photos/b/node_modules/y.js", size: 1)
        env.fs.addFile("/Fake/photos/raw/old/z.cr2", size: 1)
        env.fs.addFile("/Fake/photos/raw/new/z.cr2", size: 1)
        env.fs.addFile("/Fake/photos/keep.txt", size: 1)
        try env.library.setExclusions(["node_modules", "Raw/Old/"], forRoot: env.rootID)
        #expect(try env.library.roots().first?.exclusions == ["node_modules", "raw/old"])
        try env.scan()
        #expect(try env.paths() == ["keep.txt", "raw/new/z.cr2"])
    }

    @Test func systemJunkAndSymlinksAreSkipped() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/.DS_Store", size: 1)
        env.fs.addFile("/Fake/photos/._a.jpg", size: 1)
        env.fs.addSymlink("/Fake/photos/link.jpg")
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        #expect(try env.paths() == ["a.jpg"])
    }

    @Test func rootCannotBeOrSitInsideAnAppOwnedLibrary() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/lib/Pictures.photoslibrary/originals/x.jpg", size: 1)
        #expect(throws: LibraryError.self) {
            try env.library.addRoot(at: "/Fake/lib/Pictures.photoslibrary", fileSystem: env.fs, registry: env.registry)
        }
        #expect(throws: LibraryError.self) {
            try env.library.addRoot(at: "/Fake/lib/Pictures.photoslibrary/originals", fileSystem: env.fs, registry: env.registry)
        }
        // A root that merely contains one is allowed; the package is skipped when scanning.
        try env.library.addRoot(at: "/Fake/lib", fileSystem: env.fs, registry: env.registry)
    }

    // MARK: Moves

    @Test func renamedAndMovedFilesKeepTheirRow() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 10)
        env.fs.addFile("/Fake/photos/b.jpg", size: 20)
        try env.scan()
        let original = try env.library.files(rootID: env.rootID)
        let idOfA = try #require(original.first { $0.relativePath == "a.jpg" }).id
        let idOfB = try #require(original.first { $0.relativePath == "b.jpg" }).id

        env.fs.move("/Fake/photos/a.jpg", to: "/Fake/photos/renamed.jpg")
        env.fs.move("/Fake/photos/b.jpg", to: "/Fake/photos/new/folder/b.jpg")
        let result = try env.scan()
        #expect(result.moved == 2)
        #expect(result.added == 0 && result.markedMissing == 0)
        let after = try env.library.files(rootID: env.rootID)
        #expect(Set(after.map(\.relativePath)) == ["renamed.jpg", "new/folder/b.jpg"])
        #expect(after.first { $0.relativePath == "renamed.jpg" }?.id == idOfA)
        #expect(after.first { $0.relativePath == "new/folder/b.jpg" }?.id == idOfB)
        #expect(try env.library.fileCount(includeMissing: true) == 2)
    }

    @Test func moveBetweenRootsOfOneLibraryKeepsTheRow() throws {
        let env = try Env(); defer { env.close() }
        try env.fs.createDirectory(at: "/Fake/other")
        let second = try env.library.addRoot(at: "/Fake/other", fileSystem: env.fs, registry: env.registry)
        env.fs.addFile("/Fake/photos/a.jpg", size: 10)
        try env.scan()
        let id = try #require(try env.library.files(rootID: env.rootID).first).id

        env.fs.move("/Fake/photos/a.jpg", to: "/Fake/other/a.jpg")
        try env.library.scan(rootID: second.id, fileSystem: env.fs)
        let moved = try #require(try env.library.files(rootID: second.id).first)
        #expect(moved.id == id)
        try env.scan()
        #expect(try env.paths(includeMissing: true).isEmpty)
    }

    @Test func movedFileIsMatchedByHashWhenItsIdentityChanged() throws {
        let env = try Env(); defer { env.close() }
        let bytes = Data("the same photo bytes".utf8)
        env.fs.addFile("/Fake/photos/a.jpg", content: bytes)
        try env.scan()
        let id = try #require(try env.library.files(rootID: env.rootID).first).id
        let hash = ContentHash.full(of: "/Fake/photos/a.jpg", fileSystem: env.fs)
        try env.library.database.write { try $0.execute(sql: "UPDATE file SET fullHash = ?", arguments: [hash]) }

        // Copied to a new place and the old one removed, as a cross-volume move does: new file ID.
        env.fs.removeItem("/Fake/photos/a.jpg")
        env.fs.addFile("/Fake/photos/elsewhere/copy.jpg", content: bytes)
        let result = try env.scan()
        #expect(result.moved == 1 && result.added == 0)
        #expect(try env.library.files(rootID: env.rootID).first?.id == id)
        #expect(try env.library.files(rootID: env.rootID).first?.relativePath == "elsewhere/copy.jpg")
    }

    @Test func hashMatchIsSkippedWhenWhichCopyMovedIsAmbiguous() throws {
        let env = try Env(); defer { env.close() }
        let bytes = Data("dupe".utf8)
        env.fs.addFile("/Fake/photos/one.jpg", content: bytes)
        env.fs.addFile("/Fake/photos/two.jpg", content: bytes)
        try env.scan()
        let hash = ContentHash.full(of: "/Fake/photos/one.jpg", fileSystem: env.fs)
        try env.library.database.write { try $0.execute(sql: "UPDATE file SET fullHash = ?", arguments: [hash]) }

        env.fs.removeItem("/Fake/photos/one.jpg")
        env.fs.removeItem("/Fake/photos/two.jpg")
        env.fs.addFile("/Fake/photos/three.jpg", content: bytes)
        let result = try env.scan()
        #expect(result.moved == 0 && result.added == 1)
        #expect(result.markedMissing == 2, "\(result)")
    }

    @Test func atomicSaveAtTheSamePathKeepsTheRowEvenThoughTheFileIDChanged() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/doc.txt", size: 1)
        try env.scan()
        let id = try #require(try env.library.files(rootID: env.rootID).first).id
        env.fs.removeItem("/Fake/photos/doc.txt")
        env.fs.addFile("/Fake/photos/doc.txt", size: 2, modified: Date(timeIntervalSince1970: 9))
        try env.scan()
        #expect(try env.library.files(rootID: env.rootID).map(\.id) == [id])
    }

    // MARK: Missing files

    @Test func missingFilesAreMarkedThenRemovedAfterTheGracePeriod() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/gone.jpg", size: 1)
        env.fs.addFile("/Fake/photos/stay.jpg", size: 1)
        let day = 86400.0, t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try env.scan(grace: 30 * day, now: t0)

        env.fs.removeItem("/Fake/photos/gone.jpg")
        let marked = try env.scan(grace: 30 * day, now: t0.addingTimeInterval(day))
        #expect(marked.markedMissing == 1 && marked.removed == 0)
        #expect(try env.paths() == ["stay.jpg"])
        #expect(try env.paths(includeMissing: true) == ["gone.jpg", "stay.jpg"])
        let since = try #require(try env.library.files(rootID: env.rootID, includeMissing: true).first { $0.relativePath == "gone.jpg" }?.missingSince)
        #expect(abs(since.timeIntervalSince(t0.addingTimeInterval(day))) < 0.01)

        // Marked again later without resetting the clock.
        try env.scan(grace: 30 * day, now: t0.addingTimeInterval(10 * day))
        #expect(try env.paths(includeMissing: true) == ["gone.jpg", "stay.jpg"])

        let removed = try env.scan(grace: 30 * day, now: t0.addingTimeInterval(32 * day))
        #expect(removed.removed == 1)
        #expect(try env.paths(includeMissing: true) == ["stay.jpg"])
    }

    @Test func reappearingFileIsNoLongerMissing() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        env.fs.removeItem("/Fake/photos/a.jpg")
        try env.scan()
        #expect(try env.paths().isEmpty)
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        #expect(try env.paths() == ["a.jpg"])
    }

    @Test func unmountedDriveIsUnavailableNotEmpty() throws {
        let fs = FakeFileSystem()
        fs.addVolume(VolumeInfo(id: "USB", mountPoint: "/Volumes/USB", filesystemType: "exfat"))
        fs.addFile("/Volumes/USB/pics/a.jpg", size: 1)
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try Library.create(at: tmp.path + "/lib", fileSystem: RealFileSystem()); defer { try? lib.close() }
        let root = try lib.addRoot(at: "/Volumes/USB/pics", fileSystem: fs, registry: LibraryRegistry(preferences: InMemoryPreferences()))
        try lib.scan(rootID: root.id, fileSystem: fs)
        #expect(try lib.fileCount() == 1)

        fs.setMounted(false, volumeID: "USB")
        let result = try lib.scan(rootID: root.id, fileSystem: fs)
        #expect(result.rootAvailable == false)
        #expect(try lib.fileCount() == 1)   // not marked missing

        // The drive comes back under a different name; the same files are found.
        fs.remount(volumeID: "USB", at: "/Volumes/Renamed")
        let back = try lib.scan(rootID: root.id, fileSystem: fs)
        #expect(back.unchanged == 1 && back.markedMissing == 0)
    }

    @Test func deletedRootFolderOnAMountedVolumeChangesNothing() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        env.fs.removeItem("/Fake/photos")
        let result = try env.scan()
        #expect(result.rootAvailable == false)
        #expect(try env.paths() == ["a.jpg"])
    }

    // MARK: iCloud

    @Test func datalessFilesAreIndexedByMetadataOnly() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/cloud.pdf", size: 4096, dataless: true)
        env.fs.addFile("/Fake/photos/local.pdf", size: 10)
        let result = try env.scan()
        #expect(result.added == 2)
        let files = try env.library.files(rootID: env.rootID)
        #expect(files.first { $0.relativePath == "cloud.pdf" }?.icloudStatus == "dataless")
        #expect(files.first { $0.relativePath == "cloud.pdf" }?.size == 4096)
        #expect(files.first { $0.relativePath == "local.pdf" }?.icloudStatus == "local")
    }

    @Test func scanNeverReadsFileContent() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/cloud.pdf", size: 4096, dataless: true)
        env.fs.addFile("/Fake/photos/local.pdf", content: Data("x".utf8))
        let counting = ReadCountingFileSystem(env.fs)
        try env.library.scan(rootID: env.rootID, fileSystem: counting)
        env.fs.addFile("/Fake/photos/local2.pdf", content: Data("y".utf8))
        try env.library.scan(rootID: env.rootID, fileSystem: counting)
        #expect(counting.reads == 0)
    }

    @Test func datalessDirectoriesAreNotListedAndTheirFilesAreNotMarkedMissing() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/cloudy/a.jpg", size: 1)
        env.fs.addFile("/Fake/photos/b.jpg", size: 1)
        try env.scan()
        #expect(try env.paths() == ["b.jpg", "cloudy/a.jpg"])

        env.fs.setDataless("/Fake/photos/cloudy")
        let listedBefore = env.fs.listedDirectories.count
        let result = try env.scan()
        #expect(result.skippedDirectories == ["cloudy"])
        #expect(result.markedMissing == 0)
        #expect(try env.paths() == ["b.jpg", "cloudy/a.jpg"])
        #expect(!env.fs.listedDirectories.dropFirst(listedBefore).contains("/Fake/photos/cloudy"))
    }

    @Test func fileTurningIntoAPlaceholderUpdatesStatusAndKeepsHashes() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.pdf", size: 10)
        try env.scan()
        try env.library.database.write { try $0.execute(sql: "UPDATE file SET fullHash = x'01'") }
        env.fs.addFile("/Fake/photos/a.pdf", size: 10, dataless: true)
        let result = try env.scan()
        #expect(result.updated == 1)
        #expect(try env.library.files(rootID: env.rootID).first?.icloudStatus == "dataless")
        let n = try env.library.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file WHERE fullHash IS NOT NULL") }
        #expect(n == 1)
    }

    // MARK: Scoped scans

    @Test func subtreeScanOnlyTouchesThatSubtree() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a/1.jpg", size: 1)
        env.fs.addFile("/Fake/photos/b/2.jpg", size: 1)
        try env.scan()

        env.fs.addFile("/Fake/photos/a/new.jpg", size: 1)
        env.fs.addFile("/Fake/photos/b/new.jpg", size: 1)
        env.fs.removeItem("/Fake/photos/b/2.jpg")
        let result = try env.scan(.subtree("a"))
        #expect(result.added == 1 && result.markedMissing == 0)
        #expect(try env.paths() == ["a/1.jpg", "a/new.jpg", "b/2.jpg"])
    }

    @Test func subtreeScanOfAGoneDirectoryMarksEverythingUnderItMissing() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a/x/1.jpg", size: 1)
        env.fs.addFile("/Fake/photos/a/2.jpg", size: 1)
        env.fs.addFile("/Fake/photos/ab/3.jpg", size: 1)   // shares a name prefix with "a"
        try env.scan()
        env.fs.removeItem("/Fake/photos/a")
        env.fs.removeItem("/Fake/photos/ab")
        let result = try env.scan(.subtree("a"))
        #expect(result.markedMissing == 2)
        #expect(try env.paths() == ["ab/3.jpg"])
    }

    @Test func subtreeScanOfOneFile() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        env.fs.addFile("/Fake/photos/a.jpg", size: 7, modified: Date(timeIntervalSince1970: 3))
        env.fs.addFile("/Fake/photos/other.jpg", size: 1)
        let result = try env.scan(.subtree("a.jpg"))
        #expect(result.updated == 1 && result.added == 0)
        #expect(try env.paths() == ["a.jpg"])
    }

    @Test func subtreeScanRefusesPathsOutsideTheRoot() throws {
        let env = try Env(); defer { env.close() }
        #expect(throws: LibraryError.self) { try env.scan(.subtree("../elsewhere")) }
    }

    @Test func subtreeInsideAnExcludedPathIsIgnored() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/Photos.photoslibrary/x.jpg", size: 1)
        let result = try env.scan(.subtree("Photos.photoslibrary/x.jpg"))
        #expect(result.added == 0)
        #expect(try env.paths().isEmpty)
    }

    // MARK: Roots

    @Test func removingARootForgetsItsFilesAndTouchesNothingOnDisk() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        try env.scan()
        let dropped = try env.library.removeRoot(id: env.rootID)
        #expect(dropped == 1)
        #expect(try env.library.roots().isEmpty)
        #expect(try env.library.fileCount(includeMissing: true) == 0)
        #expect(env.fs.exists("/Fake/photos/a.jpg"))
        #expect(throws: LibraryError.self) { try env.library.removeRoot(id: env.rootID) }
    }

    @Test func aRemovedRootCanBeAddedAgain() throws {
        let env = try Env(); defer { env.close() }
        try env.library.removeRoot(id: env.rootID)
        try env.library.addRoot(at: env.rootPath, fileSystem: env.fs, registry: env.registry)
    }
}

/// Wraps a filesystem and counts content reads.
final class ReadCountingFileSystem: FileSystem, @unchecked Sendable {
    private let base: FileSystem
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    init(_ base: FileSystem) { self.base = base }
    private func bump() { lock.withLock { count += 1 } }

    func volume(containing path: String) -> VolumeInfo? { base.volume(containing: path) }
    func mountedVolume(withID id: String) -> VolumeInfo? { base.mountedVolume(withID: id) }
    func isInSyncedFolder(_ path: String) -> Bool { base.isInSyncedFolder(path) }
    func exists(_ path: String) -> Bool { base.exists(path) }
    func metadata(at path: String) throws -> FileMetadata { try base.metadata(at: path) }
    func contentsOfDirectory(at path: String) throws -> [String] { try base.contentsOfDirectory(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func readFile(at path: String) throws -> Data { bump(); return try base.readFile(at: path) }
    func readRange(at path: String, offset: Int64, length: Int) throws -> Data { bump(); return try base.readRange(at: path, offset: offset, length: length) }
    func writeFile(_ data: Data, to path: String) throws { try base.writeFile(data, to: path) }
    func createFileExclusively(_ data: Data, at path: String) throws { try base.createFileExclusively(data, at: path) }
    func removeMilesOwnedFile(at path: String) throws { try base.removeMilesOwnedFile(at: path) }
}

/// The same behaviours against a real directory tree, to catch what the fake cannot (lstat, inode identity, symlinks).
@Suite("Scanner on disk")
struct RealDiskScannerTests {
    @Test func scansARealTreeAndFollowsRenames() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fs = RealFileSystem()
        let lib = try Library.create(at: tmp.path + "/lib", fileSystem: fs); defer { try? lib.close() }
        let root = try tmp.subdirectory("tree")
        _ = try tmp.subdirectory("tree/sub")
        _ = try tmp.subdirectory("tree/Photos.photoslibrary")
        try Data("jpeg".utf8).write(to: URL(fileURLWithPath: root + "/a.jpg"))
        try Data("text".utf8).write(to: URL(fileURLWithPath: root + "/sub/b.txt"))
        try Data("heic".utf8).write(to: URL(fileURLWithPath: root + "/Photos.photoslibrary/x.heic"))
        try Data("ds".utf8).write(to: URL(fileURLWithPath: root + "/.DS_Store"))
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/sub")
        try FileManager.default.createSymbolicLink(atPath: root + "/loop", withDestinationPath: root)

        let record = try lib.addRoot(at: root, fileSystem: fs, registry: LibraryRegistry(preferences: InMemoryPreferences()))
        let first = try lib.scan(rootID: record.id, fileSystem: fs)
        #expect(first.added == 2)
        #expect(try lib.files().map(\.relativePath) == ["a.jpg", "sub/b.txt"])
        #expect(try lib.files().first?.size == 4)

        let idOfA = try #require(try lib.files().first { $0.relativePath == "a.jpg" }).id
        try FileManager.default.moveItem(atPath: root + "/a.jpg", toPath: root + "/sub/renamed.jpg")
        let second = try lib.scan(rootID: record.id, fileSystem: fs)
        #expect(second.moved == 1 && second.added == 0)
        #expect(try lib.files().first { $0.relativePath == "sub/renamed.jpg" }?.id == idOfA)

        // The scan wrote nothing into the tree.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root).sorted() == [".DS_Store", "Photos.photoslibrary", "link", "loop", "sub"])
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
