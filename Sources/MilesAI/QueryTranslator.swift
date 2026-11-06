import Foundation
import MilesCore

/// A translated query, for showing to the user before it runs (ADR 0015).
public struct QueryTranslation: Equatable, Sendable {
    public var request: String
    public var query: String
    public var provider: ProviderInfo
}

public enum QueryTranslationError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(String)
    case empty
    /// The model's answer is not a valid query, even after a second try. Shows what it said and why it failed.
    case invalid(query: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): "natural-language search is unavailable: \(why)"
        case .empty: "the model did not produce a query"
        case .invalid(let q, let why): "the model wrote a query that does not parse (\(q)): \(why)"
        }
    }
}

/// Natural-language search: asks a provider for a query, checks that it parses with the real parser, and hands it back
/// to be shown. It never runs a query itself; the caller shows `query` and runs it only when the user agrees.
public struct QueryTranslator: Sendable {
    let provider: any QueryTranslationProvider

    public init(provider: any QueryTranslationProvider = FoundationModelsProvider()) {
        self.provider = provider
    }

    public func translate(_ request: String, in library: Library) async throws -> QueryTranslation {
        let availability = await provider.availability()
        if case .unavailable(let why) = availability { throw QueryTranslationError.unavailable(why) }
        let vocabulary = (try? library.queryVocabulary()) ?? QueryVocabulary()

        var asked = request
        var lastFailure: QueryTranslationError = .empty
        for _ in 0..<2 {
            let raw = try await provider.translate(asked, vocabulary: vocabulary)
            let query = Self.clean(raw)
            if query.isEmpty { lastFailure = .empty; continue }
            do {
                _ = try QueryCompiler.compile(try QueryParser.parse(query))
                return QueryTranslation(request: request, query: query, provider: provider.info)
            } catch {
                lastFailure = .invalid(query: query, reason: error.localizedDescription)
                asked = "\(request)\n\nYour previous answer \(query) was rejected: \(error.localizedDescription). Write a corrected query."
            }
        }
        throw lastFailure
    }

    /// Models like to wrap answers in quotes or code fences.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("```") }.joined(separator: " ")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`").union(.whitespacesAndNewlines))
        if text.hasPrefix("query:") { text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return text
    }

    /// The model's instructions: the grammar of ADR 0009 and the user's own vocabulary.
    static func instructions(vocabulary: QueryVocabulary, today: Date = Date()) -> String {
        """
        You translate a request about the user's files into a search query for a file manager. Answer with the query only.
        Today is \(today.formatted(.iso8601.year().month().day())).

        Syntax:
        - A space between terms means AND (never write the word AND). `or` between terms means OR. A leading `-` excludes a term. Parentheses group.
        - A tag is `namespace:value`, or a bare word for a tag in the default namespace. `foo*` matches by prefix. Spaces in tag values are `_`.
        - Text in quotes searches file names and paths: "holiday".
        - Filters: type:(\(FileKind.allCases.map(\.rawValue).joined(separator: "|"))) ext:jpg size:>5mb size:<1mb date:2024 date:2024-05 root:<id> path:folder dup:exact dup:near tagged -tagged source:(user|rule|ai) status:(accepted|suggested|rejected) sort:name sort:-date sort:size sort:-size
        - Sizes use kb, mb, gb. A date is a year, a month or a day.
        Examples:
        - photos of cats from 2023 -> type:image cat date:2023
        - big videos -> type:video size:>1gb
        - untagged pdfs -> ext:pdf -tagged
        - text files that mention people -> type:text person:*
        - files that are exact copies -> dup:exact
        - similar or near-duplicate pictures -> dup:near
        - pictures from this year, newest first -> type:image date:<the current year> sort:-date
        `tagged` alone means "has any tag" and `-tagged` means "has no tags"; never write both together.
        Use only tags and namespaces the user has when one fits; otherwise use a plain "quoted" text search.
        Namespaces in use: \(vocabulary.namespaces.joined(separator: ", ")).
        Common tags: \(vocabulary.tags.joined(separator: ", ")).
        """
    }
}

extension Library {
    /// The user's namespaces and most-used tags, for the translator's instructions.
    public func queryVocabulary(tagLimit: Int = 80) throws -> QueryVocabulary {
        let tags = try allTags().filter { $0.fileCount > 0 }.sorted { $0.fileCount > $1.fileCount }.prefix(tagLimit)
        return QueryVocabulary(namespaces: Array(Set(try allTags().map(\.name.namespace))).sorted(),
                               tags: tags.map { $0.name.display })
    }
}
