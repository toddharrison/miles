import Foundation

/// Why a tag, namespace, alias or saved-search operation was refused.
public enum TagError: Error, Equatable, Sendable {
    case invalidName(String, reason: String)
    /// The namespace is a query filter key (ADR 0009), so `key:value` could not be told apart from a filter.
    case reservedNamespace(String)
    case unknownFile(Int64)
    case unknownTag(String)
    case selfImplication(String)
    case aliasConflict(alias: String)
    case duplicateSearchName(String)
    case unknownSearch(String)
}

extension TagError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidName(let n, let r): "'\(n)' is not a valid tag name: \(r)."
        case .reservedNamespace(let n): "'\(n)' is a search filter key and cannot be a namespace."
        case .unknownFile(let id): "No file with id \(id)."
        case .unknownTag(let n): "No tag '\(n)'."
        case .selfImplication(let n): "A tag cannot imply itself ('\(n)')."
        case .aliasConflict(let a): "'\(a)' is already a real tag, so it cannot be an alias."
        case .duplicateSearchName(let n): "A saved search named '\(n)' already exists."
        case .unknownSearch(let n): "No saved search named '\(n)'."
        }
    }
}

/// A parsed `namespace:value` tag name. Names are lowercased and inner whitespace becomes `_`.
public struct TagName: Hashable, Sendable, CustomStringConvertible {
    public static let defaultNamespace = "general"

    public let namespace: String
    public let value: String

    public var description: String { "\(namespace):\(value)" }
    /// Shorter form for display: flat tags drop the default namespace.
    public var display: String { namespace == Self.defaultNamespace ? value : description }

    public init(namespace: String, value: String) throws {
        self.namespace = try Self.normalize(namespace, what: "namespace")
        self.value = try Self.normalize(value, what: "name")
        if QueryFilterKey.isReserved(self.namespace) { throw TagError.reservedNamespace(self.namespace) }
        // A bare `tagged` in a query is the untagged-files filter (ADR 0009), so it cannot be a flat tag.
        if self.namespace == Self.defaultNamespace, self.value == "tagged" {
            throw TagError.invalidName(value, reason: "'tagged' is a search keyword")
        }
    }

    /// Parses `ns:value` or a flat `value` (default namespace). Splits at the first colon.
    public init(_ text: String) throws {
        if let colon = text.firstIndex(of: ":") {
            try self.init(namespace: String(text[..<colon]), value: String(text[text.index(after: colon)...]))
        } else {
            try self.init(namespace: Self.defaultNamespace, value: text)
        }
    }

    /// For names read back from the database, which were validated on the way in.
    init(unchecked namespace: String, _ value: String) {
        self.namespace = namespace
        self.value = value
    }

    static let forbidden = Set("()\"*~:")

    static func normalize(_ text: String, what: String) throws -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_").lowercased()
        if collapsed.isEmpty { throw TagError.invalidName(text, reason: "the \(what) is empty") }
        if collapsed.hasPrefix("-") { throw TagError.invalidName(text, reason: "the \(what) cannot start with '-'") }
        if let bad = collapsed.first(where: { forbidden.contains($0) || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) {
            throw TagError.invalidName(text, reason: "the \(what) cannot contain '\(bad)'")
        }
        return collapsed
    }
}
