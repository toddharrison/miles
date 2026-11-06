import Foundation
import FoundationModels
import MilesCore

@Generable
struct GeneratedTags {
    @Guide(description: "Between 3 and 8 short, lowercase tags that describe the content. Prefer concrete topics over generic words.")
    var tags: [GeneratedTag]
}

@Generable
struct GeneratedTag {
    @Guide(description: "A category such as topic, subject, mood, setting or genre. One lowercase word.")
    var namespace: String
    @Guide(description: "The tag value: one or two lowercase words.")
    var value: String
    @Guide(description: "How sure you are, from 0 to 1.")
    var confidence: Double
}

@Generable
struct GeneratedQuery {
    @Guide(description: "The search query only, in the syntax described in the instructions. No explanation, no quotes around the whole query.")
    var query: String
}

/// Apple's on-device language model, for layer 4 (topics, summaries, captions) and for translating plain-language
/// searches (ADR 0003, 0015). The model runs locally; nothing leaves the Mac.
///
/// The system model on macOS 27 reports a `vision` capability, so images go to it directly as attachments. If a given
/// model lacks that capability the provider reports itself unavailable for images instead of failing every job.
public struct FoundationModelsProvider: TagProvider, QueryTranslationProvider {
    public let info = ProviderInfo(id: "foundation-models", model: "SystemLanguageModel.default", revision: 1)
    public let layer = TagLayer.llm

    /// A model's own confidence is not calibrated, so it is capped: it can never clear a high auto-accept threshold.
    public static let confidenceCap = 0.8

    public init() {}

    public func supports(kind: FileKind) -> Bool { kind == .image || kind == .text }

    public func availability() async -> ProviderAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable("this Mac cannot run Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Apple Intelligence is turned off in System Settings")
        case .unavailable(.modelNotReady): return .unavailable("the on-device model is still downloading")
        case .unavailable: return .unavailable("the on-device model is unavailable")
        }
    }

    /// Whether the system model accepts images.
    public var acceptsImages: Bool { SystemLanguageModel.default.capabilities.contains(.vision) }

    public func suggestTags(for input: TagInput) async throws -> [TagCandidate] {
        let generated: GeneratedTags
        switch input {
        case .text(let text, let fileName):
            let session = LanguageModelSession(model: SystemLanguageModel(useCase: .contentTagging),
                                               instructions: "You tag a user's personal files so they can find them later.")
            generated = try await session.respond(to: "File name: \(fileName)\n\nContent:\n\(text)", generating: GeneratedTags.self).content
        case .image(let path):
            guard acceptsImages else { return [] }
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                               instructions: "You tag a user's personal pictures so they can find them later.")
            let url = URL(fileURLWithPath: path)
            generated = try await session.respond(generating: GeneratedTags.self) {
                "Tag this image."
                Attachment(imageURL: url)
            }.content
        }
        return generated.tags.map {
            TagCandidate(namespace: $0.namespace, value: $0.value, confidence: min(max($0.confidence, 0), Self.confidenceCap))
        }
    }

    public func translate(_ request: String, vocabulary: QueryVocabulary) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: QueryTranslator.instructions(vocabulary: vocabulary))
        return try await session.respond(to: request, generating: GeneratedQuery.self).content.query
    }
}
