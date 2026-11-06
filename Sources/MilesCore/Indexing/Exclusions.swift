import Foundation

/// What the scanner never indexes (ADR 0001, 0004). App-owned library packages are always
/// excluded and cannot be switched off; users may add their own exclusions per root.
public struct Exclusions: Equatable, Sendable {
    /// Extensions of packages owned by other apps. Indexing or touching them can corrupt that app's library.
    public static let appOwnedPackageExtensions: Set<String> = [
        "photoslibrary", "migratedphotolibrary", "photolibrary", "aplibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "lrlibrary",
    ]

    /// Junk the system writes everywhere. Skipped silently.
    static let ignoredFileNames: Set<String> = [".ds_store", ".localized", ".fseventsd", ".spotlight-v100", ".trashes", ".temporaryitems"]

    /// User exclusions. An entry with no `/` matches any path component by name (case-insensitive);
    /// an entry with `/` matches that path relative to the root, and everything under it.
    public var userPatterns: [String]

    public init(userPatterns: [String] = []) {
        self.userPatterns = userPatterns.map { Self.normalizePattern($0) }.filter { !$0.isEmpty }
    }

    /// True for a path component that is an app-owned package.
    public static func isAppOwnedPackage(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && appOwnedPackageExtensions.contains(ext)
    }

    /// True if any component of `path` is an app-owned package, i.e. the path is inside one.
    public static func isInsideAppOwnedPackage(_ path: String) -> Bool {
        path.split(separator: "/").contains { isAppOwnedPackage(name: String($0)) }
    }

    static func isIgnoredFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ignoredFileNames.contains(lower) || lower.hasPrefix("._")
    }

    /// Whether the entry named `name` at `relativePath` (relative to the root) is excluded.
    public func excludes(name: String, relativePath: String) -> Bool {
        if Self.isAppOwnedPackage(name: name) { return true }
        let lowerName = name.lowercased()
        let lowerPath = relativePath.lowercased()
        for pattern in userPatterns {
            if pattern.contains("/") {
                if lowerPath == pattern || lowerPath.hasPrefix(pattern + "/") { return true }
            } else if lowerName == pattern {
                return true
            }
        }
        return false
    }

    static func normalizePattern(_ pattern: String) -> String {
        pattern.split(separator: "/").filter { !$0.isEmpty && $0 != "." }.joined(separator: "/").lowercased()
    }

    // MARK: Storage (root.exclusions holds a JSON array)

    static func decode(_ json: String?) -> Exclusions {
        guard let data = json?.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return Exclusions() }
        return Exclusions(userPatterns: list)
    }

    var json: String {
        String(decoding: (try? JSONEncoder().encode(userPatterns)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
