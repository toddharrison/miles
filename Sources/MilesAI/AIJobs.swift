import Foundation
import GRDB
import MilesCore

/// Runs the AI tagging layers for one file (ADR 0010): asks every available provider of the layer that supports the file,
/// and stores what comes back as suggestions. Never downloads, and only ever reads a file that is local and unchanged.
public struct AITagJobHandler: JobHandler {
    let library: Library
    let fileSystem: FileSystem
    let layer: TagLayer
    let providers: [any TagProvider]
    let version: Int

    /// The most of a text file a provider is shown.
    public static let textLimit = 32 * 1024

    public init(library: Library, fileSystem: FileSystem, layer: TagLayer, providers: [any TagProvider], version: Int) {
        precondition(layer.isAI)
        self.library = library
        self.fileSystem = fileSystem
        self.layer = layer
        self.providers = providers.filter { $0.layer == layer }
        self.version = version
    }

    struct ProviderFailure: LocalizedError {
        let failures: [String]
        var errorDescription: String? { failures.joined(separator: "; ") }
    }

    public func run(_ job: Job) async throws {
        guard let fileID = job.fileID, let file = try library.file(id: fileID), file.missingSince == nil, file.icloudStatus == "local",
              let kind = file.kind.flatMap(FileKind.init(rawValue:)),
              let path = try? library.absolutePath(of: file, fileSystem: fileSystem) else { return }
        // Layer 4 re-checks the root's setting: it may have been turned off since the job was queued.
        if layer == .llm {
            guard let root = try library.roots().first(where: { $0.id == file.rootID }), root.layer4Kinds.contains(kind) else { return }
        }
        let active = providers.filter { $0.supports(kind: kind) }
        guard !active.isEmpty else { return }

        func unchanged() -> Bool {
            guard let live = try? fileSystem.metadata(at: path), !live.isDirectory, !live.isSymlink, !live.isDataless else { return false }
            return live.size == file.size && abs(live.modified.timeIntervalSince(file.modified)) < 0.01
        }
        guard unchanged() else { return }

        let input: TagInput
        switch kind {
        case .image: input = .image(path: path)
        case .text:
            guard let data = try? fileSystem.readRange(at: path, offset: 0, length: Self.textLimit) else { throw ProviderFailure(failures: ["could not read \(path)"]) }
            let text = String(decoding: data, as: UTF8.self)
            input = .text(text, fileName: (file.relativePath as NSString).lastPathComponent)
        default: return
        }

        var suggestions: [NewSuggestion] = []
        var failures: [String] = []
        var succeeded = false
        for provider in active {
            guard await provider.availability().isAvailable else { continue }
            do {
                for c in try await provider.suggestTags(for: input) {
                    // A name the tag grammar refuses (a reserved namespace, a colon in a value) is dropped, not guessed at.
                    guard let tag = try? TagName(namespace: c.namespace, value: c.value) else { continue }
                    suggestions.append(NewSuggestion(tag: tag, confidence: c.confidence, provider: provider.info.id, model: provider.info.model))
                }
                succeeded = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(provider.info.id): \(error.localizedDescription)")
            }
        }
        // Every provider failed: let the queue retry. If any answered, its result stands.
        if !succeeded { if failures.isEmpty { return } else { throw ProviderFailure(failures: failures) } }
        guard unchanged() else { return }    // edited while the model looked at it
        try library.recordSuggestions(suggestions, layer: layer, forFile: file.id, size: file.size, modified: file.modified,
                                      path: file.relativePath, version: version)
    }
}

/// The AI side of the job queue, for the app and the CLI: which providers exist, which are usable right now, and the
/// handlers and queue versions that follow from that.
public struct AIPipeline: Sendable {
    public var providers: [any TagProvider]
    public var translator: any QueryTranslationProvider

    public init(providers: [any TagProvider] = [VisionProvider(), NaturalLanguageProvider(), FoundationModelsProvider()],
                translator: any QueryTranslationProvider = FoundationModelsProvider()) {
        self.providers = providers
        self.translator = translator
    }

    public struct Status: Equatable, Sendable {
        public var provider: ProviderInfo
        public var layer: TagLayer
        public var availability: ProviderAvailability
    }

    public func status() async -> [Status] {
        var out: [Status] = []
        for p in providers { out.append(Status(provider: p.info, layer: p.layer, availability: await p.availability())) }
        return out
    }

    /// A number that changes when the set of usable providers of a layer, or any of their revisions, changes. A layer whose
    /// files were last run under a different number is due again, so a new model re-runs the layer (ADR 0003).
    public static func version(of providers: [any TagProvider]) -> Int {
        var hash: UInt32 = 2166136261
        for p in providers.sorted(by: { $0.info.id < $1.info.id }) {
            for byte in "\(p.info.id)/\(p.info.model)/\(p.info.revision)".utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        }
        return Int(hash & 0x7fffffff)
    }

    /// Usable providers by layer, as of now.
    public func available() async -> [TagLayer: [any TagProvider]] {
        var out: [TagLayer: [any TagProvider]] = [:]
        for p in providers where await p.availability().isAvailable { out[p.layer, default: []].append(p) }
        return out
    }

    /// Layer versions for `Library.enqueueDueJobs(ai:)`. A layer with no usable provider is left out, so nothing is queued for it.
    public func layerVersions() async -> [TagLayer: Int] {
        await available().mapValues(Self.version(of:))
    }

    /// Handlers for `JobQueue`, for the layers that have a usable provider.
    public func handlers(library: Library, fileSystem: FileSystem) async -> [JobKind: any JobHandler] {
        var out: [JobKind: any JobHandler] = [:]
        for (layer, usable) in await available() {
            out[layer.jobKind] = AITagJobHandler(library: library, fileSystem: fileSystem, layer: layer, providers: usable,
                                                 version: Self.version(of: usable))
        }
        return out
    }

    /// `library.taggingHandlers` plus the AI layers.
    public func allHandlers(library: Library, fileSystem: FileSystem) async -> [JobKind: any JobHandler] {
        library.taggingHandlers(fileSystem: fileSystem).merging(await handlers(library: library, fileSystem: fileSystem)) { _, ai in ai }
    }
}
