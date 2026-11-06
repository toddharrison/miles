import Foundation

/// Identity and properties of a mounted volume.
public struct VolumeInfo: Equatable, Sendable {
    /// Stable volume identity (the volume UUID), the same across Macs and mount points.
    public var id: String
    public var mountPoint: String
    /// Filesystem type name as reported by the OS, lowercased (`apfs`, `hfs`, `exfat`, `smbfs`, ...).
    public var filesystemType: String
    public var isLocal: Bool

    public init(id: String, mountPoint: String, filesystemType: String, isLocal: Bool = true) {
        self.id = id
        self.mountPoint = mountPoint
        self.filesystemType = filesystemType
        self.isLocal = isLocal
    }
}

/// Metadata for one file or directory. Reading it must never trigger an iCloud download.
public struct FileMetadata: Equatable, Sendable {
    public var size: Int64
    public var modified: Date
    public var isDirectory: Bool
    public var volumeID: String
    public var fileID: UInt64
    /// True for an evicted iCloud placeholder: metadata only, content not on disk.
    public var isDataless: Bool
    /// True for a symbolic link. Links are never followed or indexed.
    public var isSymlink: Bool

    public init(size: Int64, modified: Date, isDirectory: Bool, volumeID: String, fileID: UInt64, isDataless: Bool = false, isSymlink: Bool = false) {
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
        self.volumeID = volumeID
        self.fileID = fileID
        self.isDataless = isDataless
        self.isSymlink = isSymlink
    }
}

public enum FileSystemError: Error, Equatable, Sendable {
    case notFound(String)
    case alreadyExists(String)
    case notADirectory(String)
    case other(String)
}

/// All filesystem access in MilesCore goes through this protocol so tests can fake
/// placeholders, missing drives and moves (ADR 0013).
///
/// There is deliberately no general delete. User files are removed only via the Trash
/// (ARCHITECTURE.md); `removeMilesOwnedFile` exists for Miles' own bookkeeping files such as locks.
public protocol FileSystem: Sendable {
    /// The mounted volume containing `path`, or nil if its volume is not mounted or the path is unreachable.
    func volume(containing path: String) -> VolumeInfo?
    /// A currently mounted volume by identity, or nil if it is not mounted.
    func mountedVolume(withID id: String) -> VolumeInfo?
    /// True if `path` is inside iCloud Drive or another synced folder (Dropbox, OneDrive, Drive, synced Desktop/Documents).
    func isInSyncedFolder(_ path: String) -> Bool

    func exists(_ path: String) -> Bool
    func metadata(at path: String) throws -> FileMetadata
    func contentsOfDirectory(at path: String) throws -> [String]
    func createDirectory(at path: String) throws
    func readFile(at path: String) throws -> Data
    /// Reads up to `length` bytes from `offset`; shorter or empty at end of file. For hashing large files in chunks.
    func readRange(at path: String, offset: Int64, length: Int) throws -> Data
    func writeFile(_ data: Data, to path: String) throws
    /// Creates the file only if it does not exist (O_EXCL); throws `alreadyExists` otherwise.
    func createFileExclusively(_ data: Data, at path: String) throws
    /// Removes a file Miles itself created (lock files). Never use for user files.
    func removeMilesOwnedFile(at path: String) throws
}
