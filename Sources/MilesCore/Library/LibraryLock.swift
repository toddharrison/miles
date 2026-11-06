import Foundation

/// Who holds a lock, as written into the lock file.
public struct LockInfo: Codable, Equatable, Sendable {
    public var token: UUID
    public var host: String
    public var pid: Int32
    public var appVersion: String
    public var acquiredAt: Date

    public init(token: UUID = UUID(), host: String, pid: Int32, appVersion: String, acquiredAt: Date = Date()) {
        self.token = token
        self.host = host
        self.pid = pid
        self.appVersion = appVersion
        self.acquiredAt = acquiredAt
    }
}

/// Identity of the process asking for a lock. Injectable so tests can simulate other Macs and dead processes.
public struct LockOwner: Sendable {
    public var host: String
    public var pid: Int32
    public var appVersion: String
    public var processIsAlive: @Sendable (Int32) -> Bool

    public init(host: String, pid: Int32, appVersion: String, processIsAlive: @escaping @Sendable (Int32) -> Bool) {
        self.host = host
        self.pid = pid
        self.appVersion = appVersion
        self.processIsAlive = processIsAlive
    }

    /// The running process.
    public static func current(appVersion: String = MilesCore.version) -> LockOwner {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        return LockOwner(host: String(cString: buffer), pid: getpid(), appVersion: appVersion) { pid in
            kill(pid, 0) == 0 || errno == EPERM
        }
    }
}

/// One opener per library, across Macs and app copies (ADR 0012). The lock is a file in the
/// library folder, created with O_EXCL. There is no heartbeat: a crash leaves a stale lock,
/// which is detected when it is on this Mac and its process is gone, and otherwise needs an
/// explicit takeover by the user after confirming nothing else has the library open.
public final class LibraryLock: @unchecked Sendable {
    public static let fileName = "lock.json"

    public enum Staleness: Equatable, Sendable {
        /// Same Mac, process still running.
        case live
        /// Same Mac, process is gone. Safe to reclaim.
        case stale
        /// Another Mac (or an unreadable lock file): cannot be verified from here.
        case unknown
    }

    public let info: LockInfo
    private let path: String
    private let fileSystem: FileSystem
    private var released = false

    private init(info: LockInfo, path: String, fileSystem: FileSystem) {
        self.info = info
        self.path = path
        self.fileSystem = fileSystem
    }

    /// Takes the lock. A stale lock on this Mac is reclaimed silently. Any other existing lock
    /// throws `LibraryError.locked`, unless `takeOver` is true (only after the user confirmed).
    public static func acquire(directory: String, fileSystem fs: FileSystem, owner: LockOwner, takeOver: Bool = false) throws -> LibraryLock {
        let path = directory + "/" + fileName
        let info = LockInfo(host: owner.host, pid: owner.pid, appVersion: owner.appVersion)
        let data = try encoder.encode(info)

        for _ in 0..<2 {
            do {
                try fs.createFileExclusively(data, at: path)
                return LibraryLock(info: info, path: path, fileSystem: fs)
            } catch FileSystemError.alreadyExists {
                let existing = read(at: path, fileSystem: fs)
                let staleness = classify(existing, owner: owner)
                guard takeOver || staleness == .stale else {
                    throw LibraryError.locked(holder: existing, staleness: staleness)
                }
                // Only remove the lock we actually inspected; if it changed under us, someone else
                // just took it and we must not delete theirs.
                guard read(at: path, fileSystem: fs) == existing else {
                    throw LibraryError.locked(holder: read(at: path, fileSystem: fs), staleness: .unknown)
                }
                try? fs.removeMilesOwnedFile(at: path)
            }
        }
        throw LibraryError.locked(holder: read(at: path, fileSystem: fs), staleness: .unknown)
    }

    /// Looks at the current lock without taking it.
    public static func inspect(directory: String, fileSystem fs: FileSystem, owner: LockOwner) -> (holder: LockInfo?, staleness: Staleness)? {
        let path = directory + "/" + fileName
        guard fs.exists(path) else { return nil }
        let holder = read(at: path, fileSystem: fs)
        return (holder, classify(holder, owner: owner))
    }

    /// Releases the lock if it is still ours. Safe to call more than once.
    public func release() {
        guard !released else { return }
        released = true
        if Self.read(at: path, fileSystem: fileSystem)?.token == info.token {
            try? fileSystem.removeMilesOwnedFile(at: path)
        }
    }

    deinit { release() }

    private static func classify(_ holder: LockInfo?, owner: LockOwner) -> Staleness {
        guard let holder else { return .unknown }
        guard holder.host == owner.host else { return .unknown }
        return owner.processIsAlive(holder.pid) ? .live : .stale
    }

    private static func read(at path: String, fileSystem fs: FileSystem) -> LockInfo? {
        guard let data = try? fs.readFile(at: path) else { return nil }
        return try? decoder.decode(LockInfo.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
