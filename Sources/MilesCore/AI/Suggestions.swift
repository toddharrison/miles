import Foundation
import GRDB

/// A tag a model proposes for a file. Providers fill in who made it, so a layer can be re-run per model (ADR 0003).
public struct NewSuggestion: Equatable, Sendable {
    public var tag: TagName
    public var confidence: Double
    public var provider: String
    public var model: String

    public init(tag: TagName, confidence: Double, provider: String, model: String) {
        self.tag = tag
        self.confidence = min(max(confidence, 0), 1)
        self.provider = provider
        self.model = model
    }
}

/// What `recordSuggestions` did with a batch.
public struct SuggestionOutcome: Equatable, Sendable {
    public var suggested = 0
    public var autoAccepted = 0
    /// Not stored because the file already has the tag in some state: accepted, rejected, or put there by the user.
    public var skipped = 0
}

/// One entry in the review queue.
public struct Suggestion: Equatable, Identifiable, Sendable {
    public var fileID: Int64
    public var rootID: Int64
    public var relativePath: String
    public var tag: TagName
    public var confidence: Double?
    public var layer: Int?
    public var provider: String?
    public var model: String?
    public var id: String { "\(fileID):\(tag)" }
}

public enum SuggestionError: Error, Equatable, LocalizedError, Sendable {
    case invalidThreshold(Double)
    case noSuchSuggestion(fileID: Int64, tag: String)
    public var errorDescription: String? {
        switch self {
        case .invalidThreshold(let v): "the auto-accept threshold must be between 0 and 1, not \(v)"
        case .noSuchSuggestion(let id, let tag): "file \(id) has no pending suggestion \(tag)"
        }
    }
}

/// Layers 3 and 4 and the review queue (ADR 0003, 0008, 0010). Everything here only touches `ai` rows: user tags,
/// rule tags and rejected rows are never overwritten.
extension Library {
    // MARK: Recording

    /// Stores what a layer proposed for one file and records that the layer ran.
    ///
    /// - A tag the file already has in any state (user, rule, accepted, rejected) is left alone: user tags win and a
    ///   rejected suggestion stays rejected.
    /// - A suggestion this layer made earlier and the user has not judged is replaced by the new result, so a re-run
    ///   with a newer model drops what the model no longer proposes. Accepted AI tags are never removed.
    /// - A suggestion at or above the root's auto-accept threshold is stored as accepted (still source `ai`).
    ///
    /// `size`, `modified` and `path` are the file version the providers saw, so the layer runs again if the file changes.
    @discardableResult
    public func recordSuggestions(_ suggestions: [NewSuggestion], layer: TagLayer, forFile fileID: Int64, size: Int64,
                                  modified: Date, path: String, version: Int, now: Date = Date()) throws -> SuggestionOutcome {
        precondition(layer.isAI)
        let snapshot = LayerSnapshot(fileID: fileID, size: size, modified: modified, path: path)
        return try database.write { db in
            var outcome = SuggestionOutcome()
            guard let threshold = try Row.fetchOne(db, sql: "SELECT ro.autoAcceptThreshold AS t FROM file f JOIN root ro ON ro.id = f.rootID WHERE f.id = ?",
                                                   arguments: [snapshot.fileID]).map({ $0["t"] as Double? }) else { return outcome }

            var best: [TagName: NewSuggestion] = [:]
            for s in suggestions where best[s.tag].map({ $0.confidence < s.confidence }) ?? true { best[s.tag] = s }

            var proposed: Set<Int64> = []
            for s in best.values.sorted(by: { $0.confidence > $1.confidence || ($0.confidence == $1.confidence && $0.tag.description < $1.tag.description) }) {
                let tagID = try canonicalTagID(db, for: s.tag, createIfMissing: true)!
                try db.execute(sql: "UPDATE namespace SET isSystem = 1 WHERE name = ?", arguments: [s.tag.namespace])
                let existing = try Row.fetchOne(db, sql: "SELECT source, status, layer FROM file_tag WHERE fileID = ? AND tagID = ?",
                                                arguments: [snapshot.fileID, tagID])
                if let existing {
                    let ours = (existing["source"] as String) == "ai" && (existing["status"] as String) == "suggested"
                        && (existing["layer"] as Int?) == layer.rawValue
                    guard ours else { outcome.skipped += 1; continue }
                }
                let accept = threshold.map { s.confidence >= $0 } ?? false
                try db.execute(sql: """
                    INSERT INTO file_tag (fileID, tagID, source, confidence, status, provider, model, createdAt, layer)
                    VALUES (?, ?, 'ai', ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (fileID, tagID) DO UPDATE SET confidence = excluded.confidence, status = excluded.status,
                      provider = excluded.provider, model = excluded.model, createdAt = excluded.createdAt
                    """, arguments: [snapshot.fileID, tagID, s.confidence, accept ? "accepted" : "suggested", s.provider, s.model, now, layer.rawValue])
                proposed.insert(tagID)
                if accept { outcome.autoAccepted += 1 } else { outcome.suggested += 1 }
            }

            // Drop this layer's pending suggestions the new run did not propose again.
            for row in try Row.fetchAll(db, sql: "SELECT tagID FROM file_tag WHERE fileID = ? AND source = 'ai' AND status = 'suggested' AND layer = ?",
                                        arguments: [snapshot.fileID, layer.rawValue]) {
                let tagID: Int64 = row["tagID"]
                if !proposed.contains(tagID) {
                    try db.execute(sql: "DELETE FROM file_tag WHERE fileID = ? AND tagID = ?", arguments: [snapshot.fileID, tagID])
                }
            }

            try db.execute(sql: """
                INSERT OR REPLACE INTO file_layer_run (fileID, layer, version, sourceSize, sourceModified, sourcePath, complete, doneAt)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                """, arguments: [snapshot.fileID, layer.rawValue, version, snapshot.size, snapshot.modified, snapshot.path, now])
            return outcome
        }
    }

    // MARK: Queueing

    /// Queues layer 3 or 4 for every local file whose run is missing or out of date: the file changed, or the
    /// providers' `version` changed (a new model or provider). Layer 3 covers images and plain text. Layer 4 covers only
    /// the kinds a root has enabled, so a root with none queues nothing (ADR 0010). Never queues a placeholder.
    @discardableResult
    public func enqueueStaleAIJobs(layer: TagLayer, version: Int, rootID: Int64? = nil, now: Date = Date()) throws -> Int {
        precondition(layer.isAI)
        return try database.write { db in
            let kindFilter = layer == .llm
                ? "EXISTS (SELECT 1 FROM json_each(ro.layer4Kinds) WHERE value = f.kind)"
                : "f.kind IN ('image', 'text')"
            var args: [DatabaseValueConvertible] = [layer.jobKind.rawValue, now, now, layer.rawValue, version]
            if let rootID { args.append(rootID) }
            try db.execute(sql: """
                INSERT OR IGNORE INTO job (kind, fileID, state, attempts, createdAt, updatedAt)
                SELECT ?, f.id, 'queued', 0, ?, ? FROM file f
                JOIN root ro ON ro.id = f.rootID
                LEFT JOIN file_layer_run r ON r.fileID = f.id AND r.layer = ?
                WHERE f.missingSince IS NULL AND f.icloudStatus = 'local' AND \(kindFilter)
                  AND (r.fileID IS NULL OR r.version <> ? OR r.sourceSize <> f.size OR r.sourceModified <> f.modified)
                  \(rootID == nil ? "" : "AND f.rootID = ?")
                ORDER BY f.id
                """, arguments: StatementArguments(args))
            return db.changesCount
        }
    }

    /// Redoes layer 3 or 4 for every file (or one root's): the next run replaces the layer's pending suggestions.
    /// Accepted tags, rejected tags and user tags stay as they are.
    @discardableResult
    public func rerunAILayer(_ layer: TagLayer, version: Int, rootID: Int64? = nil) throws -> Int {
        precondition(layer.isAI)
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM file_layer_run WHERE layer = ? \(rootID == nil ? "" : "AND fileID IN (SELECT id FROM file WHERE rootID = ?)")
                """, arguments: StatementArguments([layer.rawValue] + (rootID.map { [$0] } ?? [])))
        }
        return try enqueueStaleAIJobs(layer: layer, version: version, rootID: rootID)
    }

    // MARK: Review queue

    /// Pending suggestions, most confident first. Missing files are left out.
    public func reviewQueue(rootID: Int64? = nil, minConfidence: Double? = nil, limit: Int = 200, offset: Int = 0) throws -> [Suggestion] {
        try database.read { db in
            var sql = """
                SELECT f.id AS fileID, f.rootID, f.relativePath, n.name AS ns, t.name AS value, ft.confidence, ft.layer, ft.provider, ft.model
                FROM file_tag ft JOIN file f ON f.id = ft.fileID JOIN tag t ON t.id = ft.tagID JOIN namespace n ON n.id = t.namespaceID
                WHERE ft.status = 'suggested' AND f.missingSince IS NULL
                """
            var args: [DatabaseValueConvertible] = []
            if let rootID { sql += " AND f.rootID = ?"; args.append(rootID) }
            if let minConfidence { sql += " AND ft.confidence >= ?"; args.append(minConfidence) }
            sql += " ORDER BY ft.confidence DESC, f.id, n.name, t.name LIMIT ? OFFSET ?"
            args += [limit, offset]
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                Suggestion(fileID: $0["fileID"], rootID: $0["rootID"], relativePath: $0["relativePath"],
                           tag: TagName(unchecked: $0["ns"], $0["value"]), confidence: $0["confidence"], layer: $0["layer"],
                           provider: $0["provider"], model: $0["model"])
            }
        }
    }

    public func suggestionCount(rootID: Int64? = nil) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM file_tag ft JOIN file f ON f.id = ft.fileID
                WHERE ft.status = 'suggested' AND f.missingSince IS NULL \(rootID == nil ? "" : "AND f.rootID = ?")
                """, arguments: StatementArguments(rootID.map { [$0] } ?? [])) ?? 0
        }
    }

    /// Accepts a pending suggestion. The row keeps its `ai` source, confidence, provider and model.
    public func acceptSuggestion(fileID: Int64, tag: TagName) throws {
        try decide(fileID: fileID, tag: tag, to: "accepted")
    }

    /// Rejects a pending suggestion. It stays in the database as `rejected`, so it is never suggested again for that file.
    public func rejectSuggestion(fileID: Int64, tag: TagName) throws {
        try decide(fileID: fileID, tag: tag, to: "rejected")
    }

    private func decide(fileID: Int64, tag: TagName, to status: String) throws {
        try database.write { db in
            guard let tagID = try canonicalTagID(db, for: tag, createIfMissing: false) else {
                throw SuggestionError.noSuchSuggestion(fileID: fileID, tag: tag.description)
            }
            try db.execute(sql: "UPDATE file_tag SET status = ? WHERE fileID = ? AND tagID = ? AND status = 'suggested'",
                           arguments: [status, fileID, tagID])
            guard db.changesCount == 1 else { throw SuggestionError.noSuchSuggestion(fileID: fileID, tag: tag.description) }
        }
    }

    /// Accepts every pending suggestion at or above `minConfidence`. Returns how many.
    @discardableResult
    public func acceptSuggestions(minConfidence: Double, rootID: Int64? = nil) throws -> Int {
        guard (0...1).contains(minConfidence) else { throw SuggestionError.invalidThreshold(minConfidence) }
        return try database.write { db in
            try db.execute(sql: """
                UPDATE file_tag SET status = 'accepted' WHERE status = 'suggested' AND confidence >= ?
                  AND fileID IN (SELECT id FROM file WHERE missingSince IS NULL \(rootID == nil ? "" : "AND rootID = ?"))
                """, arguments: StatementArguments([minConfidence] + (rootID.map { [DatabaseValueConvertible]([$0]) } ?? [])))
            return db.changesCount
        }
    }
}
