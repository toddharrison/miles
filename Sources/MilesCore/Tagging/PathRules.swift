import Foundation
import GRDB

public struct TagRuleRecord: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var rootID: Int64
    public var pattern: String
    public var tag: String
}

public enum TagRuleError: Error, Equatable, Sendable {
    case emptyPattern
    case unknownRoot(Int64)
    case unknownRule(Int64)
    case duplicate
    /// The tag template does not make a valid tag, or uses a `{n}` the pattern has no wildcard for.
    case badTemplate(String, reason: String)
}

extension TagRuleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPattern: "A rule needs a folder pattern."
        case .unknownRoot(let id): "No root with id \(id)."
        case .unknownRule(let id): "No rule with id \(id)."
        case .duplicate: "That rule already exists."
        case .badTemplate(let t, let r): "'\(t)' is not a usable tag: \(r)."
        }
    }
}

/// A folder pattern matched against the folders above a file, relative to its root (ADR 0010).
///
/// Segments are separated by `/`. `*` inside a segment matches any characters in it and is captured,
/// `**` as a whole segment matches any number of folders (including none). A pattern matches when it
/// fits the start of the folder path, so `Games/*` covers every file under `Games/Skyrim`, at any
/// depth. Matching ignores case. The tag template inserts captures with `{1}`, `{2}`, in wildcard order.
/// Example: pattern `Games/*`, tag `game:{1}`, file `Games/Skyrim/screens/a.png` gives `game:skyrim`.
struct PathRule: Sendable {
    let segments: [String]
    let template: String

    init(pattern: String, template: String) {
        self.segments = Self.segments(of: pattern)
        self.template = template
    }

    static func segments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// The tag for a file at `relativePath`, or nil if the rule does not apply or the captured text
    /// does not make a valid tag name.
    func tag(forRelativePath relativePath: String) -> TagName? {
        let folders = Array(Self.segments(of: relativePath).dropLast())
        guard let captures = Self.match(segments, 0, folders, 0) else { return nil }
        var text = template
        for (i, capture) in captures.enumerated() { text = text.replacingOccurrences(of: "{\(i + 1)}", with: capture) }
        return try? TagName(text)
    }

    private static func match(_ pattern: [String], _ pi: Int, _ folders: [String], _ fi: Int) -> [String]? {
        if pi == pattern.count { return [] }
        if pattern[pi] == "**" {
            for skip in 0...(folders.count - fi) {
                if let rest = match(pattern, pi + 1, folders, fi + skip) { return rest }
            }
            return nil
        }
        guard fi < folders.count, let here = glob(Array(pattern[pi]), 0, Array(folders[fi]), 0) else { return nil }
        guard let rest = match(pattern, pi + 1, folders, fi + 1) else { return nil }
        return here + rest
    }

    /// Matches one segment, returning what each `*` matched.
    private static func glob(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> [String]? {
        if pi == p.count { return si == s.count ? [] : nil }
        if p[pi] == "*" {
            for end in si...s.count {
                if let rest = glob(p, pi + 1, s, end) { return [String(s[si..<end])] + rest }
            }
            return nil
        }
        guard si < s.count, String(p[pi]).lowercased() == String(s[si]).lowercased() else { return nil }
        return glob(p, pi + 1, s, si + 1)
    }

    /// How many captures the pattern produces.
    static func wildcardCount(_ pattern: String) -> Int {
        segments(of: pattern).filter { $0 != "**" }.reduce(0) { $0 + $1.filter { $0 == "*" }.count }
    }
}

extension Library {
    /// Adds a path rule to a root and queues layer 2 for its files. Changing rules re-runs the layer; user
    /// tags are never touched (ADR 0010).
    @discardableResult
    public func addTagRule(rootID: Int64, pattern: String, tag template: String) throws -> TagRuleRecord {
        let pattern = PathRule.segments(of: pattern).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
        guard !pattern.isEmpty else { throw TagRuleError.emptyPattern }
        let wildcards = PathRule.wildcardCount(pattern)
        // The template must make a valid tag once every placeholder has text, and may only use wildcards that exist.
        for m in template.matches(of: /\{(\d+)\}/) {
            guard let n = Int(m.1), n >= 1, n <= wildcards else {
                throw TagRuleError.badTemplate(template, reason: "{\(m.1)} has no matching * in the pattern")
            }
        }
        let probe = template.replacingOccurrences(of: #"\{\d+\}"#, with: "x", options: .regularExpression)
        do { _ = try TagName(probe) } catch { throw TagRuleError.badTemplate(template, reason: error.localizedDescription) }

        let id: Int64
        do {
            id = try database.write { db in
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM root WHERE id = ?)", arguments: [rootID]) == true else {
                    throw TagRuleError.unknownRoot(rootID)
                }
                try db.execute(sql: "INSERT INTO tag_rule (rootID, pattern, tag, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [rootID, pattern, template, Date()])
                let id = db.lastInsertedRowID
                try db.execute(sql: "UPDATE root SET ruleRevision = ruleRevision + 1 WHERE id = ?", arguments: [rootID])
                return id
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw TagRuleError.duplicate
        }
        try enqueueStaleTaggingJobs(layers: [.pathRules], rootID: rootID)
        return TagRuleRecord(id: id, rootID: rootID, pattern: pattern, tag: template)
    }

    public func removeTagRule(id: Int64) throws {
        let rootID = try database.write { db -> Int64 in
            guard let rootID = try Int64.fetchOne(db, sql: "SELECT rootID FROM tag_rule WHERE id = ?", arguments: [id]) else {
                throw TagRuleError.unknownRule(id)
            }
            try db.execute(sql: "DELETE FROM tag_rule WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE root SET ruleRevision = ruleRevision + 1 WHERE id = ?", arguments: [rootID])
            return rootID
        }
        try enqueueStaleTaggingJobs(layers: [.pathRules], rootID: rootID)
    }

    public func tagRules(rootID: Int64? = nil) throws -> [TagRuleRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, rootID, pattern, tag FROM tag_rule \(rootID == nil ? "" : "WHERE rootID = ?") ORDER BY rootID, id",
                             arguments: rootID.map { [$0] } ?? []).map {
                TagRuleRecord(id: $0["id"], rootID: $0["rootID"], pattern: $0["pattern"], tag: $0["tag"])
            }
        }
    }
}
