import Foundation
import MilesCore
import Vision

/// Layer 3 for images: Vision's classifier gives `subject:` tags, and text recognition gives `content:text` when an
/// image contains readable writing. Runs on-device with the system's built-in models; nothing to install.
public struct VisionProvider: TagProvider {
    public let info = ProviderInfo(id: "vision", model: "ClassifyImageRequest", revision: 1)
    public let layer = TagLayer.systemML

    /// Classifications below this confidence are not suggested at all.
    public var minimumConfidence: Float = 0.25
    public var maximumLabels = 8
    /// Characters of recognised text that make an image worth a `content:text` suggestion.
    public var minimumTextLength = 12

    public init() {}

    public func supports(kind: FileKind) -> Bool { kind == .image }
    public func availability() async -> ProviderAvailability { .available }

    public func suggestTags(for input: TagInput) async throws -> [TagCandidate] {
        guard case .image(let path) = input else { return [] }
        let url = URL(fileURLWithPath: path)
        var candidates: [TagCandidate] = []

        let labels = try await ClassifyImageRequest().perform(on: url)
        for label in labels.sorted(by: { $0.confidence > $1.confidence }).prefix(maximumLabels) where label.confidence >= minimumConfidence {
            // Vision names are like "outdoor" or "wine_glass"; the first one is the most general.
            candidates.append(TagCandidate(namespace: "subject", value: label.identifier, confidence: Double(label.confidence)))
        }

        var text = RecognizeTextRequest()
        text.recognitionLevel = .fast
        let lines = try await text.perform(on: url).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.5 }
        let length = lines.reduce(0) { $0 + $1.string.count }
        if length >= minimumTextLength {
            let mean = lines.reduce(0.0) { $0 + Double($1.confidence) } / Double(lines.count)
            candidates.append(TagCandidate(namespace: "content", value: "text", confidence: mean))
        }
        return candidates
    }
}
