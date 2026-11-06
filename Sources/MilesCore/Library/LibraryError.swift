import Foundation

public enum LibraryError: Error, Equatable, Sendable {
    /// The location, or the drive it lives on, is not available. Never results in a new library.
    case locationUnavailable(String)
    case notLocalFilesystem(path: String)
    case unsupportedFilesystem(path: String, type: String)
    case syncedFolder(path: String)
    case alreadyExists(String)
    case notALibrary(String)
    /// Another opener holds the lock. See `LibraryLock.Staleness`.
    case locked(holder: LockInfo?, staleness: LibraryLock.Staleness)
    case newerSchema(found: Int, supported: Int)
    case invalidRoot(String)
    /// The path is, or is inside, a package owned by another app (a Photos library and the like).
    case appOwnedLibrary(String)
    case overlappingRoot(candidate: String, existing: String, inLibrary: String?)
    /// Another library's roots could not be read, so overlap cannot be ruled out.
    case otherLibraryUnavailable(name: String)
    case unknownLibrary(UUID)
}

extension LibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .locationUnavailable(let p): "The location \(p) is not available (is the drive mounted?). No library was created."
        case .notLocalFilesystem(let p): "\(p) is not on a local filesystem. Libraries cannot live on network shares."
        case .unsupportedFilesystem(let p, let t): "\(p) is on a \(t) volume. Libraries need APFS or HFS+."
        case .syncedFolder(let p): "\(p) is in a synced folder (iCloud or similar). A library database must not be synced."
        case .alreadyExists(let p): "A library already exists at \(p)."
        case .notALibrary(let p): "\(p) does not contain a Miles library."
        case .locked(_, let s): "The library is open elsewhere (\(s)). Take over the lock only if you are sure nothing else has it open."
        case .newerSchema(let f, let s): "This library uses schema version \(f), but this copy of Miles supports up to \(s). Update Miles."
        case .invalidRoot(let p): "\(p) cannot be used as a root."
        case .appOwnedLibrary(let p): "\(p) is, or is inside, a library owned by another app (such as Photos). Miles never indexes those."
        case .overlappingRoot(let c, let e, let lib): "\(c) overlaps the existing root \(e)\(lib.map { " in library \($0)" } ?? "")."
        case .otherLibraryUnavailable(let n): "Library \(n) is not available, so Miles cannot confirm the new root does not overlap its roots."
        case .unknownLibrary: "That library is not in the registry."
        }
    }
}
