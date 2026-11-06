import Foundation
import Testing
@testable import MilesCore

/// Change source the test drives by hand.
final class ManualChangeSource: FileChangeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable ([FileChange]) -> Void] = [:]
    private(set) var watchedPaths: [[String]] = []

    private struct Sub: FileChangeSubscription {
        let cancelAction: @Sendable () -> Void
        func cancel() { cancelAction() }
    }

    func watch(paths: [String], handler: @escaping @Sendable ([FileChange]) -> Void) -> any FileChangeSubscription {
        let id = UUID()
        lock.withLock { handlers[id] = handler; watchedPaths.append(paths) }
        return Sub { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }

    func emit(_ changes: [FileChange]) {
        let current = lock.withLock { Array(handlers.values) }
        for h in current { h(changes) }
    }
    var activeSubscriptions: Int { lock.withLock { handlers.count } }
}

@Suite("Index coordinator")
struct IndexCoordinatorTests {
    struct Env {
        let tmp: TempDir
        let fs = FakeFileSystem()
        let library: Library
        let source = ManualChangeSource()
        let rootID: Int64

        init() throws {
            tmp = try TempDir()
            library = try Library.create(at: tmp.path + "/lib", fileSystem: RealFileSystem())
            try fs.createDirectory(at: "/Fake/photos")
            rootID = try library.addRoot(at: "/Fake/photos", fileSystem: fs, registry: LibraryRegistry(preferences: InMemoryPreferences())).id
        }
        func coordinator(debounce: TimeInterval = 0.05) -> IndexCoordinator {
            IndexCoordinator(library: library, fileSystem: fs, source: source, debounce: debounce, reconcileInterval: 3600)
        }
        func paths() throws -> [String] { try library.files(rootID: rootID).map(\.relativePath) }
        func close() { try? library.close(); tmp.cleanup() }
    }

    @Test func fileEventsTriggerARescanOfJustThosePaths() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        env.fs.addFile("/Fake/photos/b.jpg", size: 1)
        let c = env.coordinator()
        try c.start(reconcileOnStart: false)
        defer { c.stop() }
        c.reconcile()

        env.fs.addFile("/Fake/photos/new.jpg", size: 1)
        env.fs.removeItem("/Fake/photos/b.jpg")
        env.fs.addFile("/Fake/photos/unreported.jpg", size: 1)   // no event: not seen until reconciliation
        env.source.emit([FileChange(path: "/Fake/photos/new.jpg"), FileChange(path: "/Fake/photos/b.jpg")])
        let ran = c.flush()
        #expect(ran.map(\.scope) == [.subtree("b.jpg"), .subtree("new.jpg")])
        #expect(try env.paths() == ["a.jpg", "new.jpg"])

        c.reconcile()
        #expect(try env.paths() == ["a.jpg", "new.jpg", "unreported.jpg"])
    }

    @Test func eventsAreDebouncedIntoOneScanAutomatically() async throws {
        let env = try Env(); defer { env.close() }
        let c = env.coordinator(debounce: 0.05)
        try c.start(reconcileOnStart: false)
        defer { c.stop() }
        let scans = ScanLog()
        c.onScan = { id, result in scans.add(id, result) }

        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        env.source.emit([FileChange(path: "/Fake/photos/a.jpg")])
        env.source.emit([FileChange(path: "/Fake/photos/a.jpg")])
        try await Task.sleep(for: .milliseconds(600))
        #expect(scans.count == 1)
        #expect(try env.paths() == ["a.jpg"])
    }

    @Test func startReconcilesEveryRootOnce() throws {
        let env = try Env(); defer { env.close() }
        env.fs.addFile("/Fake/photos/a.jpg", size: 1)
        let c = env.coordinator()
        try c.start()
        defer { c.stop() }
        c.flush()   // waits for the queue, which runs the start-up scan first
        #expect(try env.paths() == ["a.jpg"])
        #expect(env.source.watchedPaths.last == ["/Fake/photos"])
    }

    @Test func refreshReplacesTheWatch() throws {
        let env = try Env(); defer { env.close() }
        let c = env.coordinator()
        try c.start(reconcileOnStart: false)
        try env.fs.createDirectory(at: "/Fake/more")
        try env.library.addRoot(at: "/Fake/more", fileSystem: env.fs, registry: LibraryRegistry(preferences: InMemoryPreferences()))
        try c.refreshWatches()
        #expect(env.source.activeSubscriptions == 1)
        #expect(Set(env.source.watchedPaths.last ?? []) == ["/Fake/photos", "/Fake/more"])
        c.stop()
        #expect(env.source.activeSubscriptions == 0)
    }

    // MARK: Planning

    private let roots: [(Int64, String)] = [(1, "/Fake/photos"), (2, "/Fake/docs")]

    @Test func planCollapsesNestedPathsAndSplitsByRoot() throws {
        let fs = FakeFileSystem()
        fs.addFile("/Fake/photos/a/b/1.jpg"); fs.addFile("/Fake/photos/a/2.jpg"); fs.addFile("/Fake/docs/x.txt")
        let plan = IndexCoordinator.plan([
            "/Fake/photos/a/b/1.jpg": false, "/Fake/photos/a": true, "/Fake/photos/a/2.jpg": false,
            "/Fake/docs/x.txt": false, "/Elsewhere/y": false,
        ], roots: roots, fileSystem: fs)
        #expect(plan.map(\.rootID) == [1, 2])
        #expect(plan.map(\.scope) == [.subtree("a"), .subtree("x.txt")])
    }

    @Test func planIgnoresExistingDirectoriesUnlessTheirWholeContentsChanged() throws {
        let fs = FakeFileSystem()
        fs.addFile("/Fake/photos/a/1.jpg"); fs.addFile("/Fake/photos/b/2.jpg")
        let plan = IndexCoordinator.plan(["/Fake/photos": false, "/Fake/photos/a": false, "/Fake/photos/b": true], roots: roots, fileSystem: fs)
        #expect(plan.map(\.scope) == [.subtree("b")])
    }

    @Test func planTurnsAWholeRootEventIntoAFullScan() throws {
        let fs = FakeFileSystem()
        fs.addFile("/Fake/photos/a.jpg")
        let plan = IndexCoordinator.plan(["/Fake/photos": true, "/Fake/photos/a.jpg": false], roots: roots, fileSystem: fs)
        #expect(plan.map(\.scope) == [.full])
    }

    @Test func planMatchesEventsReportedWithThePrivatePrefix() throws {
        let fs = FakeFileSystem()
        let plan = IndexCoordinator.plan(["/private/var/data/pics/a.jpg": false], roots: [(1, "/var/data/pics")], fileSystem: fs)
        #expect(plan.map(\.scope) == [.subtree("a.jpg")])
    }

    @Test func planKeepsPathsThatNoLongerExist() throws {
        let fs = FakeFileSystem()
        fs.addFile("/Fake/photos/keep.jpg")
        let plan = IndexCoordinator.plan(["/Fake/photos/deleted-dir": false], roots: roots, fileSystem: fs)
        #expect(plan.map(\.scope) == [.subtree("deleted-dir")])
    }

    // MARK: Real FSEvents

    @Test func realFSEventsReportAFileCreatedInsideAWatchedFolder() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try tmp.subdirectory("watched")
        let seen = PathLog()
        let sub = FSEventsChangeSource(latency: 0.1).watch(paths: [dir]) { changes in seen.add(changes.map(\.path)) }
        defer { sub.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        try Data("hi".utf8).write(to: URL(fileURLWithPath: dir + "/new.txt"))
        // FSEvents says /private/var/..., Foundation's canonical form says /var/...
        let expected = normalizedEventPath(dir + "/new.txt")
        for _ in 0 ..< 100 where !seen.contains(normalized: expected) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(seen.contains(normalized: expected))
    }
}

final class ScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int64, ScanResult)] = []
    func add(_ id: Int64, _ r: ScanResult) { lock.withLock { entries.append((id, r)) } }
    var count: Int { lock.withLock { entries.count } }
}

final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: [String]) { lock.withLock { paths += p } }
    func contains(normalized p: String) -> Bool { lock.withLock { paths.contains { normalizedEventPath($0) == p } } }
}
