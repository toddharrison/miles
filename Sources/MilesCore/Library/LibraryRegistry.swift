import Foundation
import GRDB

/// Where the registry persists. `UserDefaults` in the app, in memory in tests.
public protocol PreferencesStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class UserDefaultsPreferences: PreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: key) }
}

public final class InMemoryPreferences: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { lock.withLock { storage[key] } }
    public func set(_ data: Data?, forKey key: String) { lock.withLock { storage[key] = data } }
}

/// One known library. The location is volume plus relative path, so a portable drive is found
/// wherever it mounts.
public struct LibraryRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var location: VolumeLocation

    public init(id: UUID, name: String, location: VolumeLocation) {
        self.id = id
        self.name = name
        self.location = location
    }
}

/// Registry of known libraries, kept in app preferences (ADR 0012). Libraries are independent
/// in v1; the registry exists to find them and to enforce that a root belongs to exactly one.
public final class LibraryRegistry: @unchecked Sendable {
    static let preferencesKey = "miles.libraryRegistry.v1"

    private struct Stored: Codable {
        var libraries: [LibraryRecord] = []
        var defaultLibraryID: UUID?
    }

    private let preferences: PreferencesStore
    private let lock = NSLock()

    public init(preferences: PreferencesStore) { self.preferences = preferences }

    public var libraries: [LibraryRecord] { lock.withLock { load().libraries } }
    public var defaultLibraryID: UUID? { lock.withLock { load().defaultLibraryID } }

    /// Adds or updates a record. The first library registered becomes the default.
    public func register(_ record: LibraryRecord) {
        lock.withLock {
            var stored = load()
            if let i = stored.libraries.firstIndex(where: { $0.id == record.id }) { stored.libraries[i] = record }
            else { stored.libraries.append(record) }
            if stored.defaultLibraryID == nil { stored.defaultLibraryID = record.id }
            save(stored)
        }
    }

    public func register(_ library: Library, name: String) {
        register(LibraryRecord(id: library.id, name: name, location: library.volume))
    }

    public func setDefault(_ id: UUID) throws {
        try lock.withLock {
            var stored = load()
            guard stored.libraries.contains(where: { $0.id == id }) else { throw LibraryError.unknownLibrary(id) }
            stored.defaultLibraryID = id
            save(stored)
        }
    }

    /// Forgets a library. Files on disk are untouched.
    public func unregister(_ id: UUID) {
        lock.withLock {
            var stored = load()
            stored.libraries.removeAll { $0.id == id }
            if stored.defaultLibraryID == id { stored.defaultLibraryID = stored.libraries.first?.id }
            save(stored)
        }
    }

    /// The current folder of a registered library, or nil if its drive is not mounted.
    public func path(of record: LibraryRecord, fileSystem fs: FileSystem) -> String? {
        record.location.resolve(fileSystem: fs)
    }

    /// Opens a registered library. Reports an unmounted drive as unavailable; never creates anything.
    public func open(_ id: UUID, fileSystem fs: FileSystem, owner: LockOwner = .current(), takeOverLock: Bool = false) throws -> Library {
        guard let record = libraries.first(where: { $0.id == id }) else { throw LibraryError.unknownLibrary(id) }
        guard let path = path(of: record, fileSystem: fs) else {
            throw LibraryError.locationUnavailable(record.name)
        }
        let library = try Library.open(at: path, fileSystem: fs, owner: owner, takeOverLock: takeOverLock)
        guard library.id == id else {
            try? library.close()
            throw LibraryError.notALibrary(path)
        }
        return library
    }

    /// Roots of every registered library except `excluding`, read from their databases without
    /// taking their locks. If any such library cannot be read, this throws: overlap cannot be ruled out.
    func rootsOfOtherLibraries(excluding id: UUID, fileSystem fs: FileSystem) throws -> [(library: String, location: VolumeLocation)] {
        var result: [(String, VolumeLocation)] = []
        for record in libraries where record.id != id {
            guard let path = path(of: record, fileSystem: fs),
                  fs.exists(path + "/" + Library.databaseFileName) else {
                throw LibraryError.otherLibraryUnavailable(name: record.name)
            }
            do {
                let queue = try DatabaseQueue(path: path + "/" + Library.databaseFileName,
                                              configuration: LibraryDatabase.configuration(readonly: true))
                let rows = try queue.read { db in
                    try Row.fetchAll(db, sql: "SELECT volumeID, relativePath FROM root")
                }
                for row in rows {
                    result.append((record.name, VolumeLocation(volumeID: row["volumeID"], relativePath: row["relativePath"])))
                }
            } catch {
                throw LibraryError.otherLibraryUnavailable(name: record.name)
            }
        }
        return result
    }

    private func load() -> Stored {
        guard let data = preferences.data(forKey: Self.preferencesKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }

    private func save(_ stored: Stored) {
        preferences.set(try? JSONEncoder().encode(stored), forKey: Self.preferencesKey)
    }
}
