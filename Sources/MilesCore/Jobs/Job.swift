import Foundation
import GRDB

/// What a job does. Open set: later steps add kinds (duplicate hashing, AI tagging) without a migration.
public struct JobKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Layer 1 tags from file metadata (ADR 0010).
    public static let tagMetadata = JobKind(rawValue: "tag-metadata")
    /// Layer 2 tags from path rules (ADR 0010).
    public static let tagPathRules = JobKind(rawValue: "tag-path-rules")
    /// Layer 3 suggestions from Vision and NaturalLanguage (ADR 0010).
    public static let tagSystemML = JobKind(rawValue: "tag-system-ml")
    /// Layer 4 suggestions from an LLM/VLM provider (ADR 0010).
    public static let tagLLM = JobKind(rawValue: "tag-llm")
    /// Perceptual hash of an image, for near-duplicate groups (ADR 0007).
    public static let fingerprint = JobKind(rawValue: "fingerprint")
    /// Partial hash of a file that shares its size with another (ADR 0007).
    public static let hashPartial = JobKind(rawValue: "hash-partial")
    /// Full content hash of a file whose partial hash matches another file's (ADR 0007).
    public static let hashFull = JobKind(rawValue: "hash-full")
}

public enum JobState: String, Sendable {
    case queued, running, failed
}

public struct Job: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var kind: JobKind
    public var fileID: Int64?
    public var state: JobState
    public var attempts: Int
    public var provider: String?
    public var model: String?
    public var error: String?
    public var notBefore: Date?
}

public struct JobCounts: Equatable, Sendable {
    public var queued = 0
    public var running = 0
    public var failed = 0
    public var total: Int { queued + running + failed }
}

/// The durable side of the job queue (ADR 0003). Jobs are rows, so a quit or crash loses nothing:
/// `recoverInterruptedJobs` puts whatever was running back in line. A finished job is deleted.
extension Library {
    public static let maxJobAttempts = 3

    private static func job(_ row: Row) -> Job {
        Job(id: row["id"], kind: JobKind(rawValue: row["kind"]), fileID: row["fileID"],
            state: JobState(rawValue: row["state"]) ?? .failed, attempts: row["attempts"],
            provider: row["provider"], model: row["model"], error: row["error"], notBefore: row["notBefore"])
    }

    /// Queues one job per file, skipping files that already have a waiting or running job of this kind.
    /// Returns how many were added.
    @discardableResult
    public func enqueueJobs(kind: JobKind, fileIDs: [Int64], now: Date = Date()) throws -> Int {
        try database.write { db in
            var added = 0
            for id in fileIDs {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO job (kind, fileID, state, attempts, createdAt, updatedAt)
                    VALUES (?, ?, 'queued', 0, ?, ?)
                    """, arguments: [kind.rawValue, id, now, now])
                added += db.changesCount
            }
            return added
        }
    }

    /// Takes the oldest due job of one of `kinds` and marks it running (counting the attempt).
    public func claimNextJob(kinds: Set<JobKind>, now: Date = Date()) throws -> Job? {
        guard !kinds.isEmpty else { return nil }
        let marks = kinds.map { _ in "?" }.joined(separator: ", ")
        var args: [DatabaseValueConvertible] = [now]
        args += kinds.map(\.rawValue)
        return try database.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM job WHERE state = 'queued' AND (notBefore IS NULL OR notBefore <= ?) AND kind IN (\(marks))
                ORDER BY id LIMIT 1
                """, arguments: StatementArguments(args)) else { return nil }
            var job = Self.job(row)
            try db.execute(sql: "UPDATE job SET state = 'running', attempts = attempts + 1, updatedAt = ? WHERE id = ?",
                           arguments: [now, job.id])
            job.state = .running
            job.attempts += 1
            return job
        }
    }

    public func finishJob(_ id: Int64) throws {
        try database.write { try $0.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [id]) }
    }

    /// Records a failure. The job waits and retries (with a growing delay) until it has been tried
    /// `maxAttempts` times, then stays as `failed` for the user to see and retry.
    public func failJob(_ id: Int64, error: String, now: Date = Date(), maxAttempts: Int = Library.maxJobAttempts,
                        retryDelay: TimeInterval = 30) throws {
        try database.write { db in
            guard let attempts = try Int.fetchOne(db, sql: "SELECT attempts FROM job WHERE id = ?", arguments: [id]) else { return }
            if attempts >= maxAttempts {
                try db.execute(sql: "UPDATE job SET state = 'failed', error = ?, notBefore = NULL, updatedAt = ? WHERE id = ?",
                               arguments: [error, now, id])
            } else {
                try db.execute(sql: "UPDATE job SET state = 'queued', error = ?, notBefore = ?, updatedAt = ? WHERE id = ?",
                               arguments: [error, now.addingTimeInterval(retryDelay * Double(attempts)), now, id])
            }
        }
    }

    /// Puts a job back in line without counting the attempt, for work that was interrupted rather than wrong.
    public func releaseJob(_ id: Int64, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE job SET state = 'queued', attempts = MAX(attempts - 1, 0), updatedAt = ? WHERE id = ? AND state = 'running'
                """, arguments: [now, id])
        }
    }

    /// Jobs left `running` by a quit or crash go back in line. Call when the queue starts.
    @discardableResult
    public func recoverInterruptedJobs(now: Date = Date()) throws -> Int {
        try database.write { db in
            try db.execute(sql: "UPDATE job SET state = 'queued', updatedAt = ? WHERE state = 'running'", arguments: [now])
            return db.changesCount
        }
    }

    public func jobCounts() throws -> JobCounts {
        try database.read { db in
            var counts = JobCounts()
            for row in try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM job GROUP BY state") {
                let n: Int = row["n"]
                switch JobState(rawValue: row["state"]) {
                case .queued: counts.queued = n
                case .running: counts.running = n
                default: counts.failed = n
                }
            }
            return counts
        }
    }

    /// Queued and running jobs per kind, for progress display. Failed jobs are not counted: they are not waiting.
    public func waitingJobCountsByKind() throws -> [JobKind: Int] {
        try database.read { db in
            var counts: [JobKind: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM job WHERE state <> 'failed' GROUP BY kind") {
                counts[JobKind(rawValue: row["kind"])] = row["n"]
            }
            return counts
        }
    }

    public func jobs(state: JobState? = nil, limit: Int = 100) throws -> [Job] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job \(state == nil ? "" : "WHERE state = ?") ORDER BY id LIMIT ?",
                             arguments: state.map { [$0.rawValue, limit] } ?? [limit]).map(Self.job)
        }
    }

    /// Gives failed jobs another round of attempts. Returns how many.
    @discardableResult
    public func retryFailedJobs(now: Date = Date()) throws -> Int {
        try database.write { db in
            try db.execute(sql: "UPDATE job SET state = 'queued', attempts = 0, notBefore = NULL, updatedAt = ? WHERE state = 'failed'",
                           arguments: [now])
            return db.changesCount
        }
    }

    /// Drops failed jobs. The next scan or `enqueueStaleTaggingJobs` queues the work again if it is still due.
    @discardableResult
    public func clearFailedJobs() throws -> Int {
        try database.write { db in
            try db.execute(sql: "DELETE FROM job WHERE state = 'failed'")
            return db.changesCount
        }
    }
}
