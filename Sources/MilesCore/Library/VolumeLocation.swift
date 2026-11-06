import Foundation

/// A place on disk stored as volume identity plus a path relative to the volume's mount point,
/// so it keeps working when a drive mounts under a different name or on another Mac (ADR 0012).
public struct VolumeLocation: Codable, Hashable, Sendable {
    public var volumeID: String
    /// Path components joined with `/`, no leading or trailing slash. Empty means the volume root.
    public var relativePath: String

    public init(volumeID: String, relativePath: String) {
        self.volumeID = volumeID
        self.relativePath = Self.normalize(relativePath)
    }

    /// Builds a location from an absolute path, or nil if its volume is not mounted.
    public static func make(path: String, fileSystem: FileSystem) -> VolumeLocation? {
        guard let volume = fileSystem.volume(containing: path) else { return nil }
        let mount = volume.mountPoint
        let relative: String
        if mount == "/" { relative = path }
        else if path == mount { relative = "" }
        else if path.hasPrefix(mount + "/") { relative = String(path.dropFirst(mount.count)) }
        else { return nil }
        return VolumeLocation(volumeID: volume.id, relativePath: relative)
    }

    /// The current absolute path, or nil if the volume is not mounted right now.
    public func resolve(fileSystem: FileSystem) -> String? {
        guard let volume = fileSystem.mountedVolume(withID: volumeID) else { return nil }
        let mount = volume.mountPoint
        if relativePath.isEmpty { return mount }
        return (mount == "/" ? "" : mount) + "/" + relativePath
    }

    /// True if `self` is the same place as `other` or an ancestor or descendant of it.
    /// Case-insensitive, because default APFS and HFS+ volumes are; this errs towards refusing.
    public func overlaps(_ other: VolumeLocation) -> Bool {
        guard volumeID == other.volumeID else { return false }
        let a = components, b = other.components
        let n = min(a.count, b.count)
        return Array(a.prefix(n)) == Array(b.prefix(n))
    }

    private var components: [String] {
        relativePath.split(separator: "/").map { $0.lowercased() }
    }

    private static func normalize(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }.joined(separator: "/")
    }
}

/// Canonical absolute form used everywhere a user-supplied path becomes a stored one.
func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}
