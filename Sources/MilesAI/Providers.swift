import Foundation
import MilesCore

/// Who produced a suggestion. Recorded on every suggestion so a layer can be re-run when a model changes (ADR 0003).
public struct ProviderInfo: Equatable, Sendable {
    public var id: String
    public var model: String
    /// Bumped when the provider's behaviour changes (prompt, thresholds), so layers re-run.
    public var revision: Int

    public init(id: String, model: String, revision: Int) {
        self.id = id
        self.model = model
        self.revision = revision
    }
}

public enum ProviderAvailability: Equatable, Sendable {
    case available
    /// The reason, in words for the user.
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
}

/// A tag a provider proposes, before it is checked against the tag grammar.
public struct TagCandidate: Equatable, Sendable {
    public var namespace: String
    public var value: String
    public var confidence: Double

    public init(namespace: String, value: String, confidence: Double) {
        self.namespace = namespace
        self.value = value
        self.confidence = confidence
    }
}

/// What a tagging provider is given. Images arrive as a path to a file that is on disk; Miles never hands a provider a
/// placeholder or bytes it has not checked are local.
public enum TagInput: Sendable {
    case image(path: String)
    /// The start of a text file, decoded as UTF-8.
    case text(String, fileName: String)
}

/// Layer 3 and 4 tagging (ADR 0010). A provider suggests tags; it never writes anything itself.
public protocol TagProvider: Sendable {
    var info: ProviderInfo { get }
    /// `.systemML` (Vision, NaturalLanguage) or `.llm`.
    var layer: TagLayer { get }
    func supports(kind: FileKind) -> Bool
    func availability() async -> ProviderAvailability
    func suggestTags(for input: TagInput) async throws -> [TagCandidate]
}

/// What the translator may name: the user's own tag vocabulary.
public struct QueryVocabulary: Equatable, Sendable {
    public var namespaces: [String]
    /// Most-used tags first.
    public var tags: [String]
    public init(namespaces: [String] = [], tags: [String] = []) {
        self.namespaces = namespaces
        self.tags = tags
    }
}

/// Turns a plain-language request into a query in the syntax of ADR 0009.
public protocol QueryTranslationProvider: Sendable {
    var info: ProviderInfo { get }
    func availability() async -> ProviderAvailability
    /// The raw query text the model produced. `QueryTranslator` checks that it parses.
    func translate(_ request: String, vocabulary: QueryVocabulary) async throws -> String
}
