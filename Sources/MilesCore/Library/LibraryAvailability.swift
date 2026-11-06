import Foundation

/// Whether a registered library can be opened right now, worked out without taking its lock,
/// writing anything or migrating anything (ADR 0012). The app and CLI use it to say why a library
/// is unavailable and what the user can do, and to notice when a drive comes back.
public enum LibraryAvailability: Equatable, Sendable {
    /// Can be opened. `path` is where it is mounted now.
    case ready(path: String)
    /// Its drive is not mounted. Opening is refused and nothing is created in its place.
    case driveNotMounted
    /// The drive is mounted but the folder holds no library (moved or deleted).
    case notALibrary(path: String)
    /// Open elsewhere. `.stale` is reclaimed on open; `.live` and `.unknown` need the user's confirmation to take over.
    case locked(holder: LockInfo?, staleness: LibraryLock.Staleness)
    /// Written by a newer app. This copy must be updated; there is no override.
    case newerSchema(found: Int, supported: Int)

    public var canOpen: Bool {
        switch self {
        case .ready: true
        case .locked(_, let staleness): staleness == .stale
        default: false
        }
    }

    /// True when only an explicit user confirmation lets the library open (a lock that cannot be shown to be dead).
    public var needsTakeOverConfirmation: Bool {
        if case .locked(_, let staleness) = self { return staleness != .stale }
        return false
    }

    public func message(libraryName: String) -> String {
        switch self {
        case .ready: "\(libraryName) is available."
        case .driveNotMounted: "\(libraryName) is on a drive that is not connected. Connect it and Miles will pick it up; nothing has been changed."
        case .notALibrary(let p): "The drive is connected but \(p) holds no Miles library."
        case .locked(let holder, let staleness):
            "\(libraryName) is open elsewhere" + (holder.map { " (\($0.host), Miles \($0.appVersion), since \($0.acquiredAt.formatted()))" } ?? "")
                + (staleness == .stale ? ". That process is gone, so the lock will be cleared." : ". If you are sure nothing has it open, you can take over the lock.")
        case .newerSchema(let f, let s): "\(libraryName) was written by a newer Miles (schema \(f); this copy supports \(s)). Update this copy of Miles."
        }
    }
}

extension LibraryRegistry {
    public func availability(of record: LibraryRecord, fileSystem fs: FileSystem, owner: LockOwner = .current()) -> LibraryAvailability {
        guard let path = path(of: record, fileSystem: fs) else { return .driveNotMounted }
        let dbPath = path + "/" + Library.databaseFileName
        guard fs.exists(path), fs.exists(dbPath) else { return .notALibrary(path: path) }
        if let found = try? LibraryDatabase.recordedSchemaVersion(atPath: dbPath), found > LibraryDatabase.currentSchemaVersion {
            return .newerSchema(found: found, supported: LibraryDatabase.currentSchemaVersion)
        }
        if let lock = LibraryLock.inspect(directory: path, fileSystem: fs, owner: owner) {
            return .locked(holder: lock.holder, staleness: lock.staleness)
        }
        return .ready(path: path)
    }
}

/// Whether a root can be scanned now.
public struct RootStatus: Equatable, Sendable {
    public var root: RootRecord
    /// Current absolute path, nil while its drive is unmounted.
    public var path: String?
    public var isAvailable: Bool { path != nil }
}

extension Library {
    /// Mounted or not, per root. Files of an unmounted root stay in the index and in search; they are never marked missing.
    public func rootStatuses(fileSystem fs: FileSystem) throws -> [RootStatus] {
        try roots().map { root in
            let path = root.location.resolve(fileSystem: fs)
            return RootStatus(root: root, path: path.flatMap { fs.exists($0) ? $0 : nil })
        }
    }
}
