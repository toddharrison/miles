import Foundation
@testable import MilesCore

/// In-memory `FileSystem` for tests: volumes that mount and unmount, synced folders,
/// iCloud placeholders and moves that keep file identity.
final class FakeFileSystem: FileSystem, @unchecked Sendable {
    private struct Node {
        var data: Data?            // nil for directories
        var meta: FileMetadata
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var volumes: [(info: VolumeInfo, mounted: Bool)] = []
    private var syncedRoots: [String] = []
    private var nextFileID: UInt64 = 1

    init() {
        addVolume(VolumeInfo(id: "BOOT", mountPoint: "/", filesystemType: "apfs"))
        nodes["/"] = Node(data: nil, meta: dirMeta(volume: "BOOT"))
    }

    // MARK: Test setup

    @discardableResult
    func addVolume(_ info: VolumeInfo, mounted: Bool = true) -> VolumeInfo {
        lock.withLock {
            volumes.append((info, mounted))
            if mounted, nodes[info.mountPoint] == nil {
                nodes[info.mountPoint] = Node(data: nil, meta: dirMeta(volume: info.id))
            }
        }
        return info
    }

    func setMounted(_ mounted: Bool, volumeID: String) {
        lock.withLock {
            guard let i = volumes.firstIndex(where: { $0.info.id == volumeID }) else { return }
            volumes[i].mounted = mounted
        }
    }

    /// Re-mounts a volume somewhere else, as when a drive appears under a different name or on another Mac.
    func remount(volumeID: String, at newMountPoint: String) {
        lock.withLock {
            guard let i = volumes.firstIndex(where: { $0.info.id == volumeID }) else { return }
            let old = volumes[i].info.mountPoint
            volumes[i].info.mountPoint = newMountPoint
            volumes[i].mounted = true
            for key in nodes.keys where key == old || key.hasPrefix(old + "/") {
                nodes[newMountPoint + key.dropFirst(old.count)] = nodes.removeValue(forKey: key)
            }
        }
    }

    func markSynced(_ path: String) { lock.withLock { syncedRoots.append(path) } }

    /// Adds a file. `content` sets real bytes (and the size) for hashing; otherwise it is empty
    /// with the stated `size`. Re-adding a path keeps its file ID, as an in-place edit does.
    func addFile(_ path: String, size: Int64 = 0, content: Data? = nil, dataless: Bool = false,
                 modified: Date = Date(timeIntervalSince1970: 0)) {
        lock.withLock {
            ensureParents(of: path)
            let volume = volumeLocked(containing: path)?.id ?? "BOOT"
            let id = nodes[path]?.meta.fileID ?? takeID()
            let meta = FileMetadata(size: content.map { Int64($0.count) } ?? size, modified: modified, isDirectory: false,
                                    volumeID: volume, fileID: id, isDataless: dataless)
            nodes[path] = Node(data: content ?? Data(), meta: meta)
        }
    }

    func addSymlink(_ path: String) {
        lock.withLock {
            ensureParents(of: path)
            let volume = volumeLocked(containing: path)?.id ?? "BOOT"
            nodes[path] = Node(data: Data(), meta: FileMetadata(size: 0, modified: Date(timeIntervalSince1970: 0), isDirectory: false,
                                                                volumeID: volume, fileID: takeID(), isSymlink: true))
        }
    }

    /// Turns a directory into an evicted placeholder.
    func setDataless(_ path: String) {
        lock.withLock { nodes[path]?.meta.isDataless = true }
    }

    /// Simulates a removal by the user outside Miles (tests only).
    func removeItem(_ path: String) {
        lock.withLock { for key in nodes.keys where key == path || key.hasPrefix(path + "/") { nodes.removeValue(forKey: key) } }
    }

    /// Paths whose directory listing was read, to assert nothing was enumerated that should not be.
    var listedDirectories: [String] { lock.withLock { listed } }
    private var listed: [String] = []

    /// Moves or renames, keeping the file ID, as a same-volume `rename(2)` does.
    func move(_ from: String, to: String) {
        lock.withLock {
            ensureParents(of: to)
            for key in nodes.keys.sorted() where key == from || key.hasPrefix(from + "/") {
                nodes[to + key.dropFirst(from.count)] = nodes.removeValue(forKey: key)
            }
        }
    }

    // MARK: FileSystem

    func volume(containing path: String) -> VolumeInfo? { lock.withLock { volumeLocked(containing: path) } }

    func mountedVolume(withID id: String) -> VolumeInfo? {
        lock.withLock { volumes.first { $0.mounted && $0.info.id == id }?.info }
    }

    func isInSyncedFolder(_ path: String) -> Bool {
        lock.withLock { syncedRoots.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }

    func exists(_ path: String) -> Bool { lock.withLock { nodes[path] != nil } }

    func metadata(at path: String) throws -> FileMetadata {
        try lock.withLock {
            guard let node = nodes[path] else { throw FileSystemError.notFound(path) }
            return node.meta
        }
    }

    func contentsOfDirectory(at path: String) throws -> [String] {
        try lock.withLock {
            guard let node = nodes[path] else { throw FileSystemError.notFound(path) }
            guard node.data == nil else { throw FileSystemError.notADirectory(path) }
            listed.append(path)
            let prefix = path == "/" ? "/" : path + "/"
            return nodes.keys.compactMap { key -> String? in
                guard key != path, key.hasPrefix(prefix) else { return nil }
                let rest = key.dropFirst(prefix.count)
                return rest.contains("/") ? nil : String(rest)
            }.sorted()
        }
    }

    func createDirectory(at path: String) throws {
        try lock.withLock {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent == path || nodes[parent] != nil || volumeLocked(containing: path) != nil else { throw FileSystemError.notFound(parent) }
            ensureParents(of: path)
            if nodes[path] == nil {
                nodes[path] = Node(data: nil, meta: dirMeta(volume: volumeLocked(containing: path)?.id ?? "BOOT"))
            }
        }
    }

    func readFile(at path: String) throws -> Data {
        try lock.withLock {
            guard let node = nodes[path], let data = node.data else { throw FileSystemError.notFound(path) }
            return data
        }
    }

    func readRange(at path: String, offset: Int64, length: Int) throws -> Data {
        let data = try readFile(at: path)
        guard offset < data.count else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
    }

    func writeFile(_ data: Data, to path: String) throws {
        try lock.withLock {
            let parent = (path as NSString).deletingLastPathComponent
            guard nodes[parent] != nil else { throw FileSystemError.notFound(parent) }
            var meta = nodes[path]?.meta ?? FileMetadata(size: 0, modified: Date(), isDirectory: false, volumeID: volumeLocked(containing: path)?.id ?? "BOOT", fileID: takeID())
            meta.size = Int64(data.count)
            nodes[path] = Node(data: data, meta: meta)
        }
    }

    func createFileExclusively(_ data: Data, at path: String) throws {
        try lock.withLock {
            guard nodes[path] == nil else { throw FileSystemError.alreadyExists(path) }
            let parent = (path as NSString).deletingLastPathComponent
            guard nodes[parent] != nil else { throw FileSystemError.notFound(parent) }
            let meta = FileMetadata(size: Int64(data.count), modified: Date(), isDirectory: false, volumeID: volumeLocked(containing: path)?.id ?? "BOOT", fileID: takeID())
            nodes[path] = Node(data: data, meta: meta)
        }
    }

    /// Paths passed to `download`, so tests can assert nothing was fetched.
    var downloads: [String] { lock.withLock { downloaded } }
    private var downloaded: [String] = []

    func download(at path: String) throws {
        try lock.withLock {
            guard nodes[path] != nil else { throw FileSystemError.notFound(path) }
            downloaded.append(path)
            nodes[path]?.meta.isDataless = false
        }
    }

    func removeMilesOwnedFile(at path: String) throws {
        try lock.withLock {
            guard nodes.removeValue(forKey: path) != nil else { throw FileSystemError.notFound(path) }
        }
    }

    // MARK: Helpers (call with lock held)

    private func volumeLocked(containing path: String) -> VolumeInfo? {
        volumes.filter { $0.mounted && ($0.info.mountPoint == "/" || path == $0.info.mountPoint || path.hasPrefix($0.info.mountPoint + "/")) }
            .max { $0.info.mountPoint.count < $1.info.mountPoint.count }?.info
    }

    private func ensureParents(of path: String) {
        var parent = (path as NSString).deletingLastPathComponent
        var chain: [String] = []
        while parent != "/", nodes[parent] == nil { chain.append(parent); parent = (parent as NSString).deletingLastPathComponent }
        for dir in chain.reversed() {
            nodes[dir] = Node(data: nil, meta: dirMeta(volume: volumeLocked(containing: dir)?.id ?? "BOOT"))
        }
    }

    private func dirMeta(volume: String) -> FileMetadata {
        FileMetadata(size: 0, modified: Date(timeIntervalSince1970: 0), isDirectory: true, volumeID: volume, fileID: takeID())
    }

    private func takeID() -> UInt64 { defer { nextFileID += 1 }; return nextFileID }
}
