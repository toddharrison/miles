import Foundation
@testable import MilesCore

/// A read-only filesystem that generates `directories` folders of `filesPerDirectory` files on demand
/// under `/Synth/root`, so scale tests need no storage and no disk walk. File and directory IDs are
/// stable, so a rescan sees an unchanged tree.
final class SyntheticFileSystem: FileSystem, @unchecked Sendable {
    let directories: Int
    let filesPerDirectory: Int
    private let volumeInfo = VolumeInfo(id: "SYNTH", mountPoint: "/", filesystemType: "apfs")
    private let rootPath = "/Synth/root"
    private let lock = NSLock()
    private var removedDirectories: Set<Int> = []

    init(directories: Int, filesPerDirectory: Int) {
        self.directories = directories
        self.filesPerDirectory = filesPerDirectory
    }

    var totalFiles: Int { directories * filesPerDirectory }

    /// Makes a whole directory disappear, as if the user deleted it.
    func removeDirectory(_ index: Int) { lock.withLock { _ = removedDirectories.insert(index) } }

    private enum Node { case root, directory(Int), file(dir: Int, index: Int) }

    private func parse(_ path: String) -> Node? {
        if path == "/Synth" || path == rootPath { return .root }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let parts = path.dropFirst(rootPath.count + 1).split(separator: "/")
        guard let first = parts.first, first.hasPrefix("d"), let d = Int(first.dropFirst()), d < directories,
              !lock.withLock({ removedDirectories.contains(d) }) else { return nil }
        if parts.count == 1 { return .directory(d) }
        guard parts.count == 2, parts[1].hasPrefix("f"), let f = Int(parts[1].dropFirst().prefix { $0 != "." }), f < filesPerDirectory else { return nil }
        return .file(dir: d, index: f)
    }

    func volume(containing path: String) -> VolumeInfo? { volumeInfo }
    func mountedVolume(withID id: String) -> VolumeInfo? { id == volumeInfo.id ? volumeInfo : nil }
    func isInSyncedFolder(_ path: String) -> Bool { false }
    func exists(_ path: String) -> Bool { parse(path) != nil }

    func metadata(at path: String) throws -> FileMetadata {
        switch parse(path) {
        case .root: return FileMetadata(size: 0, modified: Date(timeIntervalSince1970: 0), isDirectory: true, volumeID: "SYNTH", fileID: 1)
        case .directory(let d): return FileMetadata(size: 0, modified: Date(timeIntervalSince1970: 0), isDirectory: true, volumeID: "SYNTH", fileID: UInt64(10 + d))
        case .file(let d, let f):
            let n = d * filesPerDirectory + f
            return FileMetadata(size: Int64(1000 + n % 5000), modified: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
                                isDirectory: false, volumeID: "SYNTH", fileID: UInt64(1_000_000 + n))
        case nil: throw FileSystemError.notFound(path)
        }
    }

    func contentsOfDirectory(at path: String) throws -> [String] {
        switch parse(path) {
        case .root:
            let gone = lock.withLock { removedDirectories }
            return (0 ..< directories).filter { !gone.contains($0) }.map { "d" + String($0) }
        case .directory: return (0 ..< filesPerDirectory).map { "f\($0).jpg" }
        default: throw FileSystemError.notFound(path)
        }
    }

    func createDirectory(at path: String) throws { throw FileSystemError.other("read-only") }
    func readFile(at path: String) throws -> Data { throw FileSystemError.other("synthetic files have no content") }
    func readRange(at path: String, offset: Int64, length: Int) throws -> Data { throw FileSystemError.other("synthetic files have no content") }
    func writeFile(_ data: Data, to path: String) throws { throw FileSystemError.other("read-only") }
    func createFileExclusively(_ data: Data, at path: String) throws { throw FileSystemError.other("read-only") }
    func removeMilesOwnedFile(at path: String) throws { throw FileSystemError.other("read-only") }
}
