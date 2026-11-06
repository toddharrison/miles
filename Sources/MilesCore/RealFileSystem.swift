import Foundation

/// `FileSystem` backed by the real disk. Uses lstat and statfs only, so reading
/// metadata never materializes an iCloud placeholder.
public final class RealFileSystem: FileSystem, @unchecked Sendable {
    public init() {}

    /// Volume identity by device number. Resolving it costs a statfs plus a resource lookup, which
    /// would dominate a large scan, so it is cached briefly. The short lifetime keeps a drive that is
    /// swapped for another from being mistaken for the old one for long.
    private let volumeCacheLock = NSLock()
    private var volumeCache: [Int32: (id: String, expires: Date)] = [:]
    private static let volumeCacheLifetime: TimeInterval = 2

    private func volumeID(forDevice dev: Int32, path: String) -> String {
        let now = Date()
        if let hit = volumeCacheLock.withLock({ volumeCache[dev] }), hit.expires > now { return hit.id }
        let id = volume(containing: path)?.id ?? "dev-\(dev)"
        volumeCacheLock.withLock { volumeCache[dev] = (id, now.addingTimeInterval(Self.volumeCacheLifetime)) }
        return id
    }

    /// `SF_DATALESS` from <sys/stat.h>: set on evicted iCloud (and other File Provider) files.
    private static let sfDataless: UInt32 = 0x4000_0000

    /// Path prefixes (under the home directory) used by cloud providers.
    private static let syncedPrefixes = ["Library/Mobile Documents", "Library/CloudStorage"]

    public func volume(containing path: String) -> VolumeInfo? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mount = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let type = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let uuid = try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        let id = uuid ?? "fsid-\(fs.f_fsid.val.0)-\(fs.f_fsid.val.1)"
        let isLocal = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
        // User files (/Users, /var, ...) live on the Data volume, which statfs reports at
        // /System/Volumes/Data. Firmlinks make "/" + path the same file, so present it as "/" to
        // keep stored relative paths free of that prefix. The volume ID stays the Data volume's.
        let presentedMount = mount == "/System/Volumes/Data" ? "/" : mount
        return VolumeInfo(id: id, mountPoint: presentedMount, filesystemType: type.lowercased(), isLocal: isLocal)
    }

    public func mountedVolume(withID id: String) -> VolumeInfo? {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        for url in urls {
            if let info = volume(containing: url.path), info.id == id { return info }
        }
        return nil
    }

    public func isInSyncedFolder(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        for prefix in Self.syncedPrefixes {
            let full = home + "/" + prefix
            if resolved == full || resolved.hasPrefix(full + "/") { return true }
        }
        // Synced Desktop/Documents and other ubiquitous folders: check each existing ancestor.
        var url = URL(fileURLWithPath: resolved)
        while url.path != "/" {
            if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
               values.isUbiquitousItem == true { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    public func download(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        do { try FileManager.default.startDownloadingUbiquitousItem(at: url) } catch { throw wrap(error, path) }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let meta = try? metadata(at: path), !meta.isDataless { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw FileSystemError.other("timed out downloading \(path)")
    }

    public func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public func metadata(at path: String) throws -> FileMetadata {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw map(errno, path) }
        let volumeIdentity = volumeID(forDevice: st.st_dev, path: path)
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return FileMetadata(
            size: Int64(st.st_size),
            modified: modified,
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR,
            volumeID: volumeIdentity,
            fileID: UInt64(st.st_ino),
            isDataless: (st.st_flags & Self.sfDataless) != 0,
            isSymlink: (st.st_mode & S_IFMT) == S_IFLNK
        )
    }

    public func contentsOfDirectory(at path: String) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: path) }
        catch { throw wrap(error, path) }
    }

    public func createDirectory(at path: String) throws {
        do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        catch { throw wrap(error, path) }
    }

    public func readFile(at path: String) throws -> Data {
        do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw wrap(error, path) }
    }

    public func readRange(at path: String, offset: Int64, length: Int) throws -> Data {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw map(errno, path) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: length)
        let n = pread(fd, &buffer, length, off_t(offset))
        guard n >= 0 else { throw map(errno, path) }
        return Data(buffer.prefix(n))
    }

    public func writeFile(_ data: Data, to path: String) throws {
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { throw wrap(error, path) }
    }

    public func createFileExclusively(_ data: Data, at path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw map(errno, path) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw FileSystemError.other("short write to \(path)") }
    }

    public func removeMilesOwnedFile(at path: String) throws {
        do { try FileManager.default.removeItem(atPath: path) }
        catch { throw wrap(error, path) }
    }

    private func map(_ code: Int32, _ path: String) -> FileSystemError {
        switch code {
        case ENOENT: .notFound(path)
        case EEXIST: .alreadyExists(path)
        case ENOTDIR: .notADirectory(path)
        default: .other("\(path): \(String(cString: strerror(code)))")
        }
    }

    private func wrap(_ error: Error, _ path: String) -> FileSystemError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return .notFound(path)
        }
        return .other("\(path): \(error.localizedDescription)")
    }
}
