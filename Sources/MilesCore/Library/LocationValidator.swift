import Foundation

/// Decides whether a folder may hold a library (ADR 0002, 0012): local APFS/HFS+ volume,
/// not iCloud or any synced folder, and never an unmounted drive's mount-point stand-in.
enum LocationValidator {
    static let allowedFilesystems: Set<String> = ["apfs", "hfs"]

    /// Validates `directory`, which may not exist yet. Returns the volume it lives on.
    @discardableResult
    static func validate(_ directory: String, fileSystem fs: FileSystem) throws -> VolumeInfo {
        let ancestor = nearestExistingAncestor(of: directory, fileSystem: fs)
        guard let volume = fs.volume(containing: ancestor) else {
            throw LibraryError.locationUnavailable(directory)
        }
        // An unmounted drive leaves its /Volumes/<name> path resolving to the boot volume.
        if directory.hasPrefix("/Volumes/"), volume.mountPoint == "/" {
            throw LibraryError.locationUnavailable(directory)
        }
        if fs.isInSyncedFolder(ancestor) { throw LibraryError.syncedFolder(path: directory) }
        if !volume.isLocal { throw LibraryError.notLocalFilesystem(path: directory) }
        if !allowedFilesystems.contains(volume.filesystemType) {
            throw LibraryError.unsupportedFilesystem(path: directory, type: volume.filesystemType)
        }
        return volume
    }

    private static func nearestExistingAncestor(of path: String, fileSystem fs: FileSystem) -> String {
        var current = path
        while current != "/", !fs.exists(current) {
            current = (current as NSString).deletingLastPathComponent
        }
        return current.isEmpty ? "/" : current
    }
}
