import Foundation
import IOKit.ps

/// Does one kind of job. Throwing means the attempt failed and may be retried.
public protocol JobHandler: Sendable {
    func run(_ job: Job) async throws
}

/// Decides whether background work should wait. Checked before every job.
public protocol QueueConditions: Sendable {
    /// Why the queue should pause right now, or nil to carry on.
    func pauseReason() -> String?
}

public struct NoConditions: QueueConditions {
    public init() {}
    public func pauseReason() -> String? { nil }
}

/// Pauses on battery power, Low Power Mode, a serious thermal state, or a busy machine (ADR 0003).
public struct SystemConditions: QueueConditions {
    public var pauseOnBattery: Bool
    /// One-minute load average per core above which the queue waits.
    public var maxLoadPerCore: Double

    public init(pauseOnBattery: Bool = true, maxLoadPerCore: Double = 0.7) {
        self.pauseOnBattery = pauseOnBattery
        self.maxLoadPerCore = maxLoadPerCore
    }

    public func pauseReason() -> String? {
        let info = ProcessInfo.processInfo
        if pauseOnBattery, Self.onBattery() { return "on battery power" }
        if info.isLowPowerModeEnabled { return "Low Power Mode is on" }
        if info.thermalState == .serious || info.thermalState == .critical { return "the Mac is running hot" }
        var load = [Double](repeating: 0, count: 1)
        if getloadavg(&load, 1) == 1, load[0] / Double(max(info.activeProcessorCount, 1)) > maxLoadPerCore {
            return "the Mac is busy"
        }
        return nil
    }

    static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}

public struct JobRunSummary: Equatable, Sendable {
    public enum End: Equatable, Sendable {
        /// Nothing due is left (jobs waiting for a retry delay may remain).
        case idle
        case paused(String)
        /// The `limit` was reached with work left.
        case limit
        case cancelled
    }
    public var processed = 0
    public var failed = 0
    public var end: End = .idle
}

/// A throttled, resumable background queue over the `job` table (ADR 0003). One job runs at a time,
/// with a short pause between jobs, and the queue stops claiming work while the machine is on battery
/// or busy. All state is in the database, so it picks up where it left off after a restart.
public final class JobQueue: @unchecked Sendable {
    public struct Settings: Sendable {
        public var pauseBetweenJobs: TimeInterval = 0.02
        public var maxAttempts = Library.maxJobAttempts
        public var retryDelay: TimeInterval = 30
        /// How often the background loop looks again when idle or paused.
        public var pollInterval: TimeInterval = 5
        public init() {}
    }

    private let library: Library
    private let handlers: [JobKind: any JobHandler]
    private let conditions: any QueueConditions
    private let settings: Settings
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(library: Library, handlers: [JobKind: any JobHandler], conditions: any QueueConditions = SystemConditions(),
                settings: Settings = Settings(), now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.library = library
        self.handlers = handlers
        self.conditions = conditions
        self.settings = settings
        self.now = now
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    /// Runs due jobs until none are left, the machine asks the queue to wait, `limit` jobs have run, or
    /// the task is cancelled.
    @discardableResult
    public func runUntilIdle(limit: Int? = nil) async -> JobRunSummary {
        var summary = JobRunSummary()
        let kinds = Set(handlers.keys)
        while true {
            if Task.isCancelled { summary.end = .cancelled; return summary }
            if let limit, summary.processed >= limit { summary.end = .limit; return summary }
            if let reason = conditions.pauseReason() { summary.end = .paused(reason); return summary }
            guard let job = try? library.claimNextJob(kinds: kinds, now: now()), let handler = handlers[job.kind] else {
                return summary
            }
            do {
                try await handler.run(job)
                try? library.finishJob(job.id)
            } catch is CancellationError {
                try? library.releaseJob(job.id, now: now())
                summary.end = .cancelled
                return summary
            } catch {
                try? library.failJob(job.id, error: error.localizedDescription, now: now(),
                                     maxAttempts: settings.maxAttempts, retryDelay: settings.retryDelay)
                summary.failed += 1
            }
            summary.processed += 1
            await sleep(settings.pauseBetweenJobs)
        }
    }

    /// Starts the background loop: recovers interrupted jobs, then works through the queue and keeps
    /// checking for more. Safe to call twice.
    public func start() {
        lock.withLock {
            guard task == nil else { return }
            _ = try? library.recoverInterruptedJobs(now: now())
            task = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.runUntilIdle()
                    await self.sleep(self.settings.pollInterval)
                }
            }
        }
    }

    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }
}
