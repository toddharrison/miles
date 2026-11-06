import Foundation
import MilesCore
import NaturalLanguage

/// Layer 3 for plain-text files: the dominant `language:` and the people, places and organisations the text names
/// (`person:`, `place:`, `org:`). NaturalLanguage gives no confidence for entities, so they get a fixed middling one and
/// land in review unless the user sets an auto-accept threshold below it.
public struct NaturalLanguageProvider: TagProvider {
    public let info = ProviderInfo(id: "natural-language", model: "NLTagger.nameType", revision: 1)
    public let layer = TagLayer.systemML

    public var entityConfidence = 0.6
    public var maximumEntities = 10
    /// A language is only suggested when the recogniser is at least this sure.
    public var minimumLanguageConfidence = 0.6

    public init() {}

    public func supports(kind: FileKind) -> Bool { kind == .text }
    public func availability() async -> ProviderAvailability { .available }

    public func suggestTags(for input: TagInput) async throws -> [TagCandidate] {
        guard case .text(let text, _) = input, !text.isEmpty else { return [] }
        var candidates: [TagCandidate] = []

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= minimumLanguageConfidence {
            candidates.append(TagCandidate(namespace: "language", value: language.rawValue, confidence: confidence))
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var counts: [String: (namespace: String, count: Int)] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            let namespace: String
            switch tag {
            case .personalName: namespace = "person"
            case .placeName: namespace = "place"
            case .organizationName: namespace = "org"
            default: return true
            }
            let name = String(text[range]).lowercased()
            counts[name, default: (namespace, 0)].count += 1
            return true
        }
        for (name, entry) in counts.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }).prefix(maximumEntities) {
            candidates.append(TagCandidate(namespace: entry.namespace, value: name, confidence: entityConfidence))
        }
        return candidates
    }
}
