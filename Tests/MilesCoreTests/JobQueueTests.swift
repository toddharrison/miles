import Foundation
import GRDB
import Testing
@testable import MilesCore

@Suite("Job queue")
struct JobQueueTests {
    final class Recorder: JobHandler, @unchecked Sendable {
        private let lock = NSLock()
        private var _ran: [Int64] = []
        var failUntilAttempt = 0
        var cancel = false
        var ran: [Int64] { lock.withLock { _ran } }

        func run(_ job: Job) async throws {
            if cancel { throw CancellationError() }
            if job.attempts <= failUntilAttempt { throw TestFailure.boom }
            lock.withLock { _ran.append(job.fileID ?? -1) }
        }
        enum TestFailure: Error { case boom }
    }

    struct Paused: QueueConditions { let reason: String?; func pauseReason() -> String? { reason } }

    final class Env {
        let env: ScannerTests.Env
        var library: Library { env.library }
        var ids: [Int64] = []
        let clock = Clock()

        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var t = Date(timeIntervalSince1970: 1_700_000_000)
            var now: Date { lock.withLock { t } }
            func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
        }

        init(files: Int = 3) throws {
            env = try ScannerTests.Env()
            for i in 0..<files { env.fs.addFile("/Fake/photos/f\(i).jpg", size: 10) }
            try env.scan()
            ids = try library.files().map(\.id)
        }
        deinit { env.close() }

        func queue(_ handler: JobHandler, conditions: QueueConditions = NoConditions()) -> JobQueue {
            let clock = clock
            return JobQueue(library: library, handlers: [.tagMetadata: handler], conditions: conditions,
                            now: { clock.now }, sleep: { _ in })
        }
    }

    @Test func enqueueSkipsFilesThatAlreadyHaveAPendingJob() throws {
        let e = try Env()
        #expect(try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids) == 3)
        #expect(try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids) == 0)
        #expect(try e.library.enqueueJobs(kind: .tagPathRules, fileIDs: e.ids) == 3)
        #expect(try e.library.jobCounts() == JobCounts(queued: 6, running: 0, failed: 0))
    }

    @Test func runsEveryJobInOrderAndDeletesFinishedOnes() async throws {
        let e = try Env()
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        let handler = Recorder()
        let summary = await e.queue(handler).runUntilIdle()
        #expect(summary == JobRunSummary(processed: 3, failed: 0, end: .idle))
        #expect(handler.ran == e.ids)
        #expect(try e.library.jobCounts().total == 0)
    }

    @Test func aFailingJobRetriesAfterADelayThenStaysFailed() async throws {
        let e = try Env(files: 1)
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        let handler = Recorder()
        handler.failUntilAttempt = 99
        let queue = e.queue(handler)

        var summary = await queue.runUntilIdle()
        #expect(summary.failed == 1 && summary.processed == 1)
        let waiting = try #require(try e.library.jobs().first)
        #expect(waiting.state == .queued && waiting.attempts == 1 && waiting.error != nil && waiting.notBefore != nil)

        // Not due yet: nothing runs until the retry delay has passed.
        summary = await queue.runUntilIdle()
        #expect(summary.processed == 0)
        e.clock.advance(60)
        summary = await queue.runUntilIdle()
        #expect(summary.processed == 1)
        e.clock.advance(600)
        summary = await queue.runUntilIdle()
        #expect(summary.processed == 1)

        let failed = try #require(try e.library.jobs().first)
        #expect(failed.state == .failed && failed.attempts == 3)
        e.clock.advance(3600)
        #expect(await queue.runUntilIdle().processed == 0, "a failed job does not run again by itself")

        #expect(try e.library.retryFailedJobs() == 1)
        handler.failUntilAttempt = 0
        #expect(await queue.runUntilIdle().processed == 1)
        #expect(handler.ran == e.ids)
        #expect(try e.library.jobCounts().total == 0)
    }

    @Test func pausesWithoutClaimingAnythingWhileConditionsSayWait() async throws {
        let e = try Env()
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        let handler = Recorder()
        let summary = await e.queue(handler, conditions: Paused(reason: "on battery power")).runUntilIdle()
        #expect(summary == JobRunSummary(processed: 0, failed: 0, end: .paused("on battery power")))
        #expect(handler.ran.isEmpty)
        #expect(try e.library.jobCounts() == JobCounts(queued: 3, running: 0, failed: 0))
        #expect(try e.library.jobs().allSatisfy { $0.attempts == 0 })
    }

    @Test func stopsAtTheLimitAndLeavesTheRestQueued() async throws {
        let e = try Env()
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        let handler = Recorder()
        let queue = e.queue(handler)
        let first = await queue.runUntilIdle(limit: 2)
        #expect(first.processed == 2 && first.end == .limit)
        #expect(try e.library.jobCounts().queued == 1)
        #expect(await queue.runUntilIdle().processed == 1)
    }

    @Test func jobsLeftRunningByACrashGoBackInLine() throws {
        let e = try Env()
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        let claimed = try #require(try e.library.claimNextJob(kinds: [.tagMetadata]))
        #expect(claimed.state == .running && claimed.attempts == 1)
        #expect(try e.library.claimNextJob(kinds: [.tagMetadata])?.id != claimed.id)

        #expect(try e.library.recoverInterruptedJobs() == 2)
        #expect(try e.library.jobCounts() == JobCounts(queued: 3, running: 0, failed: 0))
    }

    @Test func queuedWorkSurvivesClosingAndReopeningTheLibrary() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fs = FakeFileSystem()
        try fs.createDirectory(at: "/Fake/photos")
        fs.addFile("/Fake/photos/a.jpg", size: 1)
        let dir = tmp.path + "/lib"
        var library = try Library.create(at: dir, fileSystem: RealFileSystem())
        let root = try library.addRoot(at: "/Fake/photos", fileSystem: fs, registry: LibraryRegistry(preferences: InMemoryPreferences()))
        try library.scan(rootID: root.id, scope: .full, fileSystem: fs, options: ScanOptions())
        try library.enqueueStaleTaggingJobs()
        _ = try library.claimNextJob(kinds: [.tagMetadata])   // "running" when the app quits
        try library.close()

        library = try Library.open(at: dir, fileSystem: RealFileSystem())
        defer { try? library.close() }
        #expect(try library.recoverInterruptedJobs() == 1)
        #expect(try library.jobCounts().queued >= 1)
    }

    @Test func cancellingMidJobPutsItBackWithoutCountingTheAttempt() async throws {
        let e = try Env(files: 1)
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        let handler = Recorder()
        handler.cancel = true
        let summary = await e.queue(handler).runUntilIdle()
        #expect(summary.end == .cancelled)
        let job = try #require(try e.library.jobs().first)
        #expect(job.state == .queued && job.attempts == 0)
    }

    @Test func aJobForADeletedFileDisappearsWithIt() throws {
        let e = try Env(files: 1)
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        try e.library.database.write { try $0.execute(sql: "DELETE FROM file") }
        #expect(try e.library.jobCounts().total == 0)
    }

    @Test func backgroundLoopProcessesJobsAndStops() async throws {
        let e = try Env()
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: e.ids)
        let handler = Recorder()
        let queue = e.queue(handler)
        queue.start()
        defer { queue.stop() }
        for _ in 0..<200 where handler.ran.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(handler.ran.count == 3)
    }
}
