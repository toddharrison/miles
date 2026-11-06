import Foundation
import GRDB

/// Layer 1 job: file metadata tags. Never downloads. Content (dimensions, duration) is read only
/// after a live check that the file is on disk; for a placeholder only the index-derived tags are written
/// and the run is marked incomplete, so it repeats once the file is local (ADR 0010, 0014).
public struct MetadataJobHandler: JobHandler {
    let library: Library
    let fileSystem: FileSystem
    let probe: any MetadataProbe
    let calendar: Calendar

    public init(library: Library, fileSystem: FileSystem, probe: any MetadataProbe = SystemMetadataProbe(), calendar: Calendar = .current) {
        self.library = library
        self.fileSystem = fileSystem
        self.probe = probe
        self.calendar = calendar
    }

    public func run(_ job: Job) async throws {
        guard let fileID = job.fileID, let file = try library.file(id: fileID), file.missingSince == nil else { return }
        let fileKind = file.kind.flatMap(FileKind.init(rawValue:))

        var info: MediaInfo?
        var complete = true
        if let fileKind, [.image, .video, .audio].contains(fileKind) {
            if let path = try? library.absolutePath(of: file, fileSystem: fileSystem),
               let live = try? fileSystem.metadata(at: path), !live.isDataless {
                // A file that cannot be read (damaged, odd format) gets no content tags; trying again would not help.
                info = try? await probe.probe(path: path, kind: fileKind)
            } else {
                complete = false
            }
        }
        try library.applyLayer(.metadata,
                               snapshot: LayerSnapshot(fileID: fileID, size: file.size, modified: file.modified, path: file.relativePath),
                               tags: MetadataTagger.tags(kind: file.kind, modified: file.modified, info: info, calendar: calendar),
                               version: MetadataTagger.version, complete: complete)
    }
}

/// Layer 2 job: the root's path rules.
public struct PathRuleJobHandler: JobHandler {
    let library: Library

    public init(library: Library) { self.library = library }

    public func run(_ job: Job) async throws {
        guard let fileID = job.fileID, let file = try library.file(id: fileID), file.missingSince == nil else { return }
        let (rules, revision) = try await library.database.read { db -> ([PathRule], Int) in
            let rules = try Row.fetchAll(db, sql: "SELECT pattern, tag FROM tag_rule WHERE rootID = ? ORDER BY id", arguments: [file.rootID])
                .map { PathRule(pattern: $0["pattern"], template: $0["tag"]) }
            let revision = try Int.fetchOne(db, sql: "SELECT ruleRevision FROM root WHERE id = ?", arguments: [file.rootID]) ?? 0
            return (rules, revision)
        }
        try library.applyLayer(.pathRules,
                               snapshot: LayerSnapshot(fileID: fileID, size: file.size, modified: file.modified, path: file.relativePath),
                               tags: rules.compactMap { $0.tag(forRelativePath: file.relativePath) },
                               version: revision)
    }
}

extension Library {
    /// The handlers for the job kinds MilesCore knows, for `JobQueue`: tagging layers 1 and 2, duplicate hashing and fingerprints. AI jobs are handled by `MilesAI`.
    public func taggingHandlers(fileSystem: FileSystem, probe: any MetadataProbe = SystemMetadataProbe()) -> [JobKind: any JobHandler] {
        [.tagMetadata: MetadataJobHandler(library: self, fileSystem: fileSystem, probe: probe),
         .tagPathRules: PathRuleJobHandler(library: self),
         .hashPartial: HashJobHandler(library: self, fileSystem: fileSystem, stage: .partial),
         .hashFull: HashJobHandler(library: self, fileSystem: fileSystem, stage: .full),
         .fingerprint: FingerprintJobHandler(library: self, fileSystem: fileSystem)]
    }

    /// Queues everything that is due after a scan: tagging layers 1 and 2, duplicate hashing and image fingerprints.
    /// `ai` maps an AI layer to the version of its current providers (see `MilesAI`); layers not listed are not queued,
    /// which is how a layer with no provider available stays quiet. Returns the number of jobs added.
    @discardableResult
    public func enqueueDueJobs(rootID: Int64? = nil, ai: [TagLayer: Int] = [:]) throws -> Int {
        var added = try enqueueStaleTaggingJobs(rootID: rootID) + enqueueHashingJobs(rootID: rootID) + enqueueFingerprintJobs(rootID: rootID)
        for (layer, version) in ai.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            added += try enqueueStaleAIJobs(layer: layer, version: version, rootID: rootID)
        }
        return added
    }
}
