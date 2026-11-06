import Foundation
import GRDB

/// The automated tagging layers (ADR 0010). Layers 1 and 2 are deterministic and write accepted `rule` tags; layers 3 and 4
/// are on-device AI and write `ai` suggestions into the review queue.
public enum TagLayer: Int, Sendable, CaseIterable {
    case metadata = 1
    case pathRules = 2
    /// Vision and NaturalLanguage: image classification, text in images, language and entities.
    case systemML = 3
    /// LLM/VLM providers. Off by default for every root (ADR 0010).
    case llm = 4

    /// Layers that need no model: queued by `enqueueStaleTaggingJobs`. The AI layers are queued by `enqueueStaleAIJobs`.
    public static let deterministic: [TagLayer] = [.metadata, .pathRules]
    public var isAI: Bool { rawValue >= 3 }

    public var jobKind: JobKind {
        switch self {
        case .metadata: .tagMetadata
        case .pathRules: .tagPathRules
        case .systemML: .tagSystemML
        case .llm: .tagLLM
        }
    }

    /// Recorded as `provider` on the rows the layer writes.
    public var provider: String {
        switch self {
        case .metadata: "metadata"
        case .pathRules: "path-rules"
        case .systemML: "system-ml"
        case .llm: "llm"
        }
    }

    /// Whether the layer's result can change when the file's bytes change (and not only its name).
    var dependsOnContent: Bool { self == .metadata }
}

/// What a layer saw of a file when it ran. A later difference means the layer is due again.
struct LayerSnapshot: Sendable {
    var fileID: Int64
    var size: Int64
    var modified: Date
    var path: String
}

extension Library {
    /// Makes the file's accepted `rule` tags of `layer` exactly `tags`, and records the run.
    ///
    /// Only that layer's accepted rule rows are ever removed or added. User tags, rows made by other
    /// layers or by AI, and rejected rows are left alone, and a tag the user rejected is not applied
    /// again (ADR 0008, 0010). Namespaces the layer writes to are marked system-managed (ADR 0014).
    func applyLayer(_ layer: TagLayer, snapshot: LayerSnapshot, tags: [TagName], version: Int, complete: Bool = true,
                    now: Date = Date()) throws {
        try database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM file WHERE id = ?)", arguments: [snapshot.fileID]) == true else { return }

            var desired: Set<Int64> = []
            for name in tags {
                desired.insert(try canonicalTagID(db, for: name, createIfMissing: true)!)
                try db.execute(sql: "UPDATE namespace SET isSystem = 1 WHERE name = ?", arguments: [name.namespace])
            }

            let existing = try Row.fetchAll(db, sql: "SELECT tagID, source, status, layer FROM file_tag WHERE fileID = ?",
                                            arguments: [snapshot.fileID])
            var present: Set<Int64> = []
            for row in existing {
                let tagID: Int64 = row["tagID"]
                present.insert(tagID)
                let ours = (row["layer"] as Int?) == layer.rawValue && (row["source"] as String) == "rule" && (row["status"] as String) == "accepted"
                if ours, !desired.contains(tagID) {
                    try db.execute(sql: "DELETE FROM file_tag WHERE fileID = ? AND tagID = ?", arguments: [snapshot.fileID, tagID])
                }
            }
            for tagID in desired.subtracting(present) {
                try db.execute(sql: """
                    INSERT INTO file_tag (fileID, tagID, source, confidence, status, provider, model, createdAt, layer)
                    VALUES (?, ?, 'rule', NULL, 'accepted', ?, NULL, ?, ?)
                    """, arguments: [snapshot.fileID, tagID, layer.provider, now, layer.rawValue])
            }

            try db.execute(sql: """
                INSERT OR REPLACE INTO file_layer_run (fileID, layer, version, sourceSize, sourceModified, sourcePath, complete, doneAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [snapshot.fileID, layer.rawValue, version, snapshot.size, snapshot.modified, snapshot.path, complete, now])
        }
    }

    /// Queues a job for every file whose `layer` run is missing or out of date: the file changed, moved
    /// or became local after an incomplete run, or the layer's version or the root's rules changed.
    /// Missing files are skipped. Returns how many jobs were added.
    @discardableResult
    public func enqueueStaleTaggingJobs(layers: [TagLayer] = TagLayer.deterministic, rootID: Int64? = nil, now: Date = Date()) throws -> Int {
        try database.write { db in
            var added = 0
            for layer in layers where !layer.isAI {
                let version = layer == .metadata ? String(MetadataTagger.version) : "ro.ruleRevision"
                // Layer 2 only has work once a root has had a rule; before that, nothing could be out of date.
                let neverRun = layer == .pathRules ? "(r.fileID IS NULL AND ro.ruleRevision > 0)" : "r.fileID IS NULL"
                var stale = "\(neverRun) OR r.version <> \(version) OR r.sourcePath <> f.relativePath"
                if layer.dependsOnContent {
                    stale += " OR r.sourceSize <> f.size OR r.sourceModified <> f.modified OR (r.complete = 0 AND f.icloudStatus = 'local')"
                }
                var args: [DatabaseValueConvertible] = [layer.jobKind.rawValue, now, now, layer.rawValue]
                if let rootID { args.append(rootID) }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO job (kind, fileID, state, attempts, createdAt, updatedAt)
                    SELECT ?, f.id, 'queued', 0, ?, ? FROM file f
                    JOIN root ro ON ro.id = f.rootID
                    LEFT JOIN file_layer_run r ON r.fileID = f.id AND r.layer = ?
                    WHERE f.missingSince IS NULL \(rootID == nil ? "" : "AND f.rootID = ?") AND (\(stale))
                    ORDER BY f.id
                    """, arguments: StatementArguments(args))
                added += db.changesCount
            }
            return added
        }
    }

    /// Re-runs a layer for every file (of one root, or all) and queues the work. Only that layer's own
    /// rule tags change; user tags and rejected suggestions stay (ADR 0010). Layer 2 only has work in
    /// roots that have had a rule.
    @discardableResult
    public func rerunLayer(_ layer: TagLayer, rootID: Int64? = nil) throws -> Int {
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM file_layer_run WHERE layer = ? \(rootID == nil ? "" : "AND fileID IN (SELECT id FROM file WHERE rootID = ?)")
                """, arguments: StatementArguments([layer.rawValue] + (rootID.map { [$0] } ?? [])))
        }
        return try enqueueStaleTaggingJobs(layers: [layer], rootID: rootID)
    }
}
