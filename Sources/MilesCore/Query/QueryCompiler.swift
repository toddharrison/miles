import Foundation
import GRDB

/// A query compiled to SQL against the `file` table (aliased as `file`).
public struct CompiledQuery: Sendable {
    public var whereSQL: String
    public var orderSQL: String
    var arguments: [DatabaseValue]
}

/// Compiles a parsed query to SQL (ADR 0009). Alias resolution and implication expansion happen
/// in the SQL itself, at query time, so saved searches follow later alias and implication changes.
public enum QueryCompiler {
    public static func compile(_ query: ParsedQuery) throws -> CompiledQuery {
        var c = Compiler()
        var conditions: [String] = []
        if let expr = query.expr {
            conditions.append(try c.compile(expr))
            // Missing files are hidden unless the query asks about them.
            if !mentionsMissing(expr) { conditions.append("file.missingSince IS NULL") }
        } else {
            conditions.append("file.missingSince IS NULL")
        }
        return CompiledQuery(whereSQL: conditions.joined(separator: " AND "),
                             orderSQL: try order(query.sort), arguments: c.arguments)
    }

    static func mentionsMissing(_ expr: QueryExpr) -> Bool {
        switch expr {
        case .filter(.missing): true
        case .and(let items), .or(let items): items.contains(where: mentionsMissing)
        case .not(let inner): mentionsMissing(inner)
        default: false
        }
    }

    static func order(_ sort: QuerySort?) throws -> String {
        guard let sort else { return "file.rootID, file.relativePath, file.id" }
        let dir = sort.descending ? "DESC" : "ASC"
        switch sort.key {
        case .name: return "lower(\(LibraryDatabase.nameSQL("file.relativePath"))) \(dir), file.relativePath, file.id"
        case .path: return "file.relativePath \(dir), file.rootID, file.id"
        case .size: return "file.size \(dir), file.relativePath, file.id"
        case .date: return "file.modified \(dir), file.relativePath, file.id"
        case .kind: return "file.kind \(dir), file.relativePath, file.id"
        case .random: return "RANDOM()"
        case .created: throw createdUnavailable
        }
    }

    static let createdUnavailable = QueryError("created: and sort:created need file creation dates, which Miles does not index yet")

    /// Escapes `\`, `%` and `_` for LIKE with `ESCAPE '\'`, turning `*` into `%`.
    static func likePattern(_ text: String, wildcards: Bool) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\\", "%", "_": out.append("\\"); out.append(ch)
            case "*" where wildcards: out.append("%")
            default: out.append(ch)
            }
        }
        return out
    }

    private struct Compiler {
        var arguments: [DatabaseValue] = []

        mutating func bind(_ value: some DatabaseValueConvertible) -> String {
            arguments.append(value.databaseValue)
            return "?"
        }

        mutating func compile(_ expr: QueryExpr) throws -> String {
            switch expr {
            case .and(let items): return try compileAnd(items)
            case .or(let items): return "(" + (try items.map { try compile($0) }).joined(separator: " OR ") + ")"
            case .not(let inner): return "NOT (\(try compile(inner)))"
            case .tag(let ns, let pattern, let literal): return tag(ns ?? TagName.defaultNamespace, pattern, literal: literal)
            case .text(let text): return "file.id IN (SELECT rowid FROM file_fts WHERE file_fts MATCH \(bind(ftsPhrase(text))))"
            case .filter(let f): return try filter(f)
            }
        }

        /// Sibling `source:` and `status:` terms describe the same tag row (`source:ai status:suggested`
        /// means an AI suggestion), so they share one EXISTS instead of matching different rows.
        mutating func compileAnd(_ items: [QueryExpr]) throws -> String {
            var source: String?, status: String?
            var parts: [String] = []
            for item in items {
                switch item {
                case .filter(.source(let s)) where source == nil: source = s
                case .filter(.status(let s)) where status == nil: status = s
                default: parts.append(try compile(item))
                }
            }
            if source != nil || status != nil { parts.append(fileTagExists(source: source, status: status)) }
            return "(" + parts.joined(separator: " AND ") + ")"
        }

        mutating func fileTagExists(source: String?, status: String?) -> String {
            var sql = "EXISTS (SELECT 1 FROM file_tag ft WHERE ft.fileID = file.id"
            if let source { sql += " AND ft.source = \(bind(source))" }
            if let status { sql += " AND ft.status = \(bind(status))" }
            return sql + ")"
        }

        func ftsPhrase(_ text: String) -> String {
            // Name and path only. The last word matches as a prefix, so "beach da" finds "beach_day".
            "{name path} : \"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\" *"
        }

        /// A tag matches files where it is accepted. Unless literal, an alias resolves to its tag and
        /// every tag that (transitively) implies a matching tag counts as well.
        mutating func tag(_ namespace: String, _ pattern: String, literal: Bool) -> String {
            let wild = pattern.contains("*")
            let op = wild ? "LIKE" : "="
            let value = wild ? QueryCompiler.likePattern(pattern, wildcards: true) : pattern
            let esc = wild ? " ESCAPE '\\'" : ""
            var set: String
            if literal {
                set = """
                    SELECT t.id FROM tag t JOIN namespace n ON n.id = t.namespaceID
                    WHERE n.name = \(bind(namespace)) AND t.name \(op) \(bind(value))\(esc)
                    """
            } else {
                set = """
                    WITH RECURSIVE base(id) AS (
                      SELECT t.id FROM tag t JOIN namespace n ON n.id = t.namespaceID
                      WHERE n.name = \(bind(namespace)) AND t.name \(op) \(bind(value))\(esc)
                      UNION
                      SELECT a.tagID FROM tag_alias a JOIN namespace n ON n.id = a.namespaceID
                      WHERE n.name = \(bind(namespace)) AND a.name \(op) \(bind(value))\(esc)),
                    sat(id) AS (
                      SELECT id FROM base
                      UNION
                      SELECT ti.tagID FROM tag_implication ti JOIN sat ON ti.impliesTagID = sat.id)
                    SELECT id FROM sat
                    """
            }
            return "EXISTS (SELECT 1 FROM file_tag ft WHERE ft.fileID = file.id AND ft.status = 'accepted' AND ft.tagID IN (\(set)))"
        }

        mutating func filter(_ f: QueryFilter) throws -> String {
            switch f {
            case .type(let kind): return "file.kind = \(bind(kind.rawValue))"
            case .ext(let ext): return "lower(file.relativePath) LIKE \(bind("%." + QueryCompiler.likePattern(ext, wildcards: false))) ESCAPE '\\'"
            case .size(let r): return bounds("file.size", r.lower, r.upper)
            case .date(let r): return bounds("file.modified", r.lower, r.upper)
            case .created: throw QueryCompiler.createdUnavailable
            case .root(let id): return "file.rootID = \(bind(id))"
            case .path(let text): return "lower(file.relativePath) LIKE \(bind("%" + QueryCompiler.likePattern(text, wildcards: false) + "%")) ESCAPE '\\'"
            case .dup(.exact):
                return "(file.fullHash IS NOT NULL AND EXISTS (SELECT 1 FROM file o WHERE o.fullHash = file.fullHash AND o.id <> file.id AND o.missingSince IS NULL))"
            case .dup(.near): throw QueryError("dup:near needs image fingerprints, which Miles does not compute yet")
            case .tagged(let yes):
                return "\(yes ? "" : "NOT ")EXISTS (SELECT 1 FROM file_tag ft WHERE ft.fileID = file.id AND ft.status = 'accepted')"
            case .source(let s): return fileTagExists(source: s, status: nil)
            case .status(let s): return fileTagExists(source: nil, status: s)
            case .missing(let yes): return "file.missingSince IS \(yes ? "NOT " : "")NULL"
            }
        }

        mutating func bounds(_ column: String, _ lower: (some DatabaseValueConvertible)?, _ upper: (some DatabaseValueConvertible)?) -> String {
            var parts: [String] = []
            if let lower { parts.append("\(column) >= \(bind(lower))") }
            if let upper { parts.append("\(column) < \(bind(upper))") }
            return "(" + (parts.isEmpty ? "1" : parts.joined(separator: " AND ")) + ")"
        }
    }
}
