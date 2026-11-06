import Foundation

/// Keeps the index current: turns file-change events into small rescans, and runs a full scan of every
/// root periodically and at start-up, because events can be missed (app not running, dropped events,
/// drive unplugged). Read-only with respect to user files, like the scanner it drives (ADR 0001).
public final class IndexCoordinator: @unchecked Sendable {
    public static let defaultDebounce: TimeInterval = 1.5
    public static let defaultReconcileInterval: TimeInterval = 6 * 3600

    private let library: Library
    private let fs: FileSystem
    private let source: FileChangeSource
    private let options: ScanOptions
    private let debounce: TimeInterval
    private let reconcileInterval: TimeInterval

    /// All scanning happens here, one at a time.
    private let queue = DispatchQueue(label: "miles.index-coordinator")
    private let lock = NSLock()
    private var pending: [String: Bool] = [:]       // absolute path -> mustScanSubtree
    private var flushScheduled = false
    private var subscription: (any FileChangeSubscription)?
    private var timer: DispatchSourceTimer?

    /// Called after each scan with the root and its result. May be called on any thread.
    public var onScan: (@Sendable (Int64, ScanResult) -> Void)? {
        get { lock.withLock { _onScan } }
        set { lock.withLock { _onScan = newValue } }
    }
    private var _onScan: (@Sendable (Int64, ScanResult) -> Void)?

    public init(library: Library, fileSystem: FileSystem, source: FileChangeSource, options: ScanOptions = ScanOptions(),
                debounce: TimeInterval = IndexCoordinator.defaultDebounce,
                reconcileInterval: TimeInterval = IndexCoordinator.defaultReconcileInterval) {
        self.library = library
        self.fs = fileSystem
        self.source = source
        self.options = options
        self.debounce = debounce
        self.reconcileInterval = reconcileInterval
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// Starts watching every mounted root and schedules periodic reconciliation. With `reconcileOnStart`
    /// (the default) every root is fully scanned once, to catch whatever changed while nothing was watching.
    public func start(reconcileOnStart: Bool = true) throws {
        try refreshWatches()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + reconcileInterval, repeating: reconcileInterval)
        timer.setEventHandler { [weak self] in self?.reconcileLocked() }
        timer.resume()
        lock.withLock { self.timer = timer }
        if reconcileOnStart { queue.async { [weak self] in self?.reconcileLocked() } }
    }

    public func stop() {
        let (sub, timer) = lock.withLock { () -> ((any FileChangeSubscription)?, DispatchSourceTimer?) in
            defer { subscription = nil; self.timer = nil }
            return (subscription, self.timer)
        }
        sub?.cancel()
        timer?.cancel()
    }

    /// Re-reads the root list and watches the roots that are mounted now. Call after adding or removing
    /// a root or when a drive mounts.
    public func refreshWatches() throws {
        let paths = try library.roots().compactMap { $0.location.resolve(fileSystem: fs) }
        let new = source.watch(paths: paths) { [weak self] changes in self?.handle(changes) }
        let old = lock.withLock { () -> (any FileChangeSubscription)? in
            defer { subscription = new }
            return subscription
        }
        old?.cancel()
    }

    // MARK: Events

    /// Records changes and schedules a rescan after the debounce interval.
    public func handle(_ changes: [FileChange]) {
        let schedule: Bool = lock.withLock {
            for change in changes { pending[change.path] = (pending[change.path] ?? false) || change.mustScanSubtree }
            guard !flushScheduled, !pending.isEmpty else { return false }
            flushScheduled = true
            return true
        }
        if schedule {
            queue.asyncAfter(deadline: .now() + debounce) { [weak self] in self?.flushLocked() }
        }
    }

    /// Rescans everything recorded so far, now, and waits for it. Returns the scans that ran.
    @discardableResult
    public func flush() -> [(rootID: Int64, scope: ScanScope)] {
        queue.sync { flushLocked() }
    }

    /// Fully scans every root, now, and waits for it.
    public func reconcile() {
        queue.sync { reconcileLocked() }
    }

    // MARK: Work (runs on `queue`)

    @discardableResult
    private func flushLocked() -> [(rootID: Int64, scope: ScanScope)] {
        let batch: [String: Bool] = lock.withLock {
            defer { pending = [:]; flushScheduled = false }
            return pending
        }
        guard !batch.isEmpty, let roots = try? library.roots() else { return [] }
        let located = roots.compactMap { root in root.location.resolve(fileSystem: fs).map { (root.id, $0) } }
        let plan = Self.plan(batch, roots: located, fileSystem: fs)
        for item in plan { run(item.rootID, item.scope) }
        return plan
    }

    private func reconcileLocked() {
        guard let roots = try? library.roots() else { return }
        for root in roots { run(root.id, .full) }
    }

    private func run(_ rootID: Int64, _ scope: ScanScope) {
        guard let result = try? library.scan(rootID: rootID, scope: scope, fileSystem: fs, options: options) else { return }
        onScan?(rootID, result)
    }

    // MARK: Planning

    /// Maps changed absolute paths to scans: each path under a root becomes a subtree scan of its relative
    /// path, nested paths collapse into their ancestor, and an existing directory is rescanned only when
    /// the source says its contents changed wholesale (its files report themselves otherwise).
    static func plan(_ changes: [String: Bool], roots: [(Int64, String)], fileSystem fs: FileSystem) -> [(rootID: Int64, scope: ScanScope)] {
        var perRoot: [Int64: [String]] = [:]       // relative paths; "" means the whole root
        var fullRoots: Set<Int64> = []

        let roots = roots.map { ($0.0, normalizedEventPath($0.1)) }
        for (reported, mustScan) in changes {
            let path = normalizedEventPath(reported)
            guard let (rootID, rootPath) = roots.first(where: { path == $0.1 || path.hasPrefix($0.1 + "/") }) else { continue }
            let relative = path == rootPath ? "" : String(path.dropFirst(rootPath.count + 1))
            if let meta = try? fs.metadata(at: reported), meta.isDirectory, !mustScan { continue }
            if relative.isEmpty { fullRoots.insert(rootID) } else { perRoot[rootID, default: []].append(relative) }
        }

        var result: [(rootID: Int64, scope: ScanScope)] = []
        for (rootID, _) in roots {
            if fullRoots.contains(rootID) { result.append((rootID, .full)); continue }
            var kept: [String] = []
            for path in (perRoot[rootID] ?? []).sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
                if kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                kept.append(path)
            }
            result += kept.sorted().map { (rootID, ScanScope.subtree($0)) }
        }
        return result
    }
}

/// FSEvents reports `/private/var/...`, while stored roots use Foundation's canonical form `/var/...`
/// (`resolvingSymlinksInPath` drops the `/private` prefix). Compare both in the canonical form.
func normalizedEventPath(_ path: String) -> String {
    for prefix in ["/private/var", "/private/tmp", "/private/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
        return String(path.dropFirst("/private".count))
    }
    return path
}
