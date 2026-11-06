import Foundation
import CoreServices

/// One reported change under a watched folder.
public struct FileChange: Equatable, Sendable {
    public var path: String
    /// True when the source says everything below `path` must be rescanned (a directory created, moved
    /// in or renamed, dropped events, or an overflow), not just `path` itself.
    public var mustScanSubtree: Bool

    public init(path: String, mustScanSubtree: Bool = false) {
        self.path = path
        self.mustScanSubtree = mustScanSubtree
    }
}

public protocol FileChangeSubscription: Sendable {
    func cancel()
}

/// A stream of file-system change notifications. Behind a protocol so tests drive it by hand.
/// Events are a hint to rescan sooner; the periodic reconciliation is what guarantees correctness.
public protocol FileChangeSource: Sendable {
    func watch(paths: [String], handler: @escaping @Sendable ([FileChange]) -> Void) -> any FileChangeSubscription
}

/// FSEvents-backed source. Watches only; never reads or changes files.
public final class FSEventsChangeSource: FileChangeSource {
    private final class Box {
        let handler: @Sendable ([FileChange]) -> Void
        init(_ handler: @escaping @Sendable ([FileChange]) -> Void) { self.handler = handler }
    }

    private final class Subscription: FileChangeSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var stream: FSEventStreamRef?
        init(stream: FSEventStreamRef) { self.stream = stream }
        func cancel() {
            lock.withLock {
                guard let stream else { return }
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
        deinit { cancel() }
    }

    private struct Nothing: FileChangeSubscription { func cancel() {} }

    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "miles.fsevents")

    public init(latency: TimeInterval = 1.0) { self.latency = latency }

    public func watch(paths: [String], handler: @escaping @Sendable ([FileChange]) -> Void) -> any FileChangeSubscription {
        guard !paths.isEmpty else { return Nothing() }
        let box = Box(handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            var changes: [FileChange] = []
            changes.reserveCapacity(count)
            for i in 0 ..< min(count, list.count) {
                let flags = eventFlags[i]
                let isDirectory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                let structural = flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
                let rescan = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
                    | kFSEventStreamEventFlagRootChanged) != 0
                changes.append(FileChange(path: list[i], mustScanSubtree: rescan || (isDirectory && structural)))
            }
            box.handler(changes)
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return Nothing()
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return Subscription(stream: stream)
    }
}
