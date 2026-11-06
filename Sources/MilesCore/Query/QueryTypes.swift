import Foundation

/// A malformed or unsupported query (ADR 0009). Never answered with a guessed or loose text search.
public struct QueryError: Error, Equatable, Sendable {
    public var message: String
    /// Character offset into the query text, when the problem has a place in it.
    public var offset: Int?

    public init(_ message: String, offset: Int? = nil) {
        self.message = message
        self.offset = offset
    }
}

extension QueryError: LocalizedError {
    public var errorDescription: String? {
        offset.map { "\(message) (at character \($0 + 1))" } ?? message
    }
}

/// Filter keys are reserved (ADR 0009): a namespace cannot share a name with one.
public enum QueryFilterKey: String, CaseIterable, Sendable {
    case type, ext, size, date, created, root, path, dup, tagged, source, status, missing, sort

    public static func isReserved(_ name: String) -> Bool { QueryFilterKey(rawValue: name.lowercased()) != nil }
}

/// A half-open range: `lower` inclusive, `upper` exclusive, either side open.
public struct HalfOpenRange<Bound: Equatable & Sendable>: Equatable, Sendable {
    public var lower: Bound?
    public var upper: Bound?
    public init(lower: Bound? = nil, upper: Bound? = nil) {
        self.lower = lower
        self.upper = upper
    }
}

public enum QueryFilter: Equatable, Sendable {
    case type(FileKind)
    case ext(String)
    case size(HalfOpenRange<Int64>)
    case date(HalfOpenRange<Date>)
    case created(HalfOpenRange<Date>)
    case root(Int64)
    case path(String)
    case dup(Duplicate)
    case tagged(Bool)
    case source(String)
    case status(String)
    case missing(Bool)

    public enum Duplicate: String, Sendable { case exact, near }
}

public indirect enum QueryExpr: Equatable, Sendable {
    case and([QueryExpr])
    case or([QueryExpr])
    case not(QueryExpr)
    /// `namespace` nil means the default namespace. `pattern` is normalized and may contain `*`.
    /// `literal` (the `~` prefix) turns off alias resolution and implication expansion.
    case tag(namespace: String?, pattern: String, literal: Bool)
    /// A quoted string: matches file name or path text.
    case text(String)
    case filter(QueryFilter)
}

public struct QuerySort: Equatable, Sendable {
    public enum Key: String, CaseIterable, Sendable { case name, path, size, date, created, kind, random }
    public var key: Key
    public var descending: Bool
}

public struct ParsedQuery: Equatable, Sendable {
    /// Nil matches every file (an empty query, or one that only sorts).
    public var expr: QueryExpr?
    public var sort: QuerySort?
}
