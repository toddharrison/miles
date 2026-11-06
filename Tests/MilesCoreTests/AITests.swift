import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MilesAI
@testable import MilesCore

/// Steps 8: layers 3 and 4, the review queue, fingerprints and near-duplicates, natural-language queries.
@Suite("AI layers, review queue and near-duplicates")
struct AITests {
    final class FakeProvider: TagProvider, @unchecked Sendable {
        let info: ProviderInfo
        let layer: TagLayer
        var kinds: Set<FileKind>
        var available = true
        var failing = false
        var results: [TagCandidate]
        private let lock = NSLock()
        private var _inputs: [String] = []
        var inputs: [String] { lock.withLock { _inputs } }

        init(id: String = "fake", layer: TagLayer = .systemML, kinds: Set<FileKind> = [.image, .text], revision: Int = 1,
             results: [TagCandidate] = []) {
            info = ProviderInfo(id: id, model: "\(id)-model", revision: revision)
            self.layer = layer
            self.kinds = kinds
            self.results = results
        }
        func supports(kind: FileKind) -> Bool { kinds.contains(kind) }
        func availability() async -> ProviderAvailability { available ? .available : .unavailable("off") }
        func suggestTags(for input: TagInput) async throws -> [TagCandidate] {
            lock.withLock {
                switch input {
                case .image(let path): _inputs.append("image:\(path)")
                case .text(let text, let name): _inputs.append("text:\(name):\(text.count)")
                }
            }
            if failing { throw ThumbnailRenderError.unreadable("model failed") }
            return results
        }
    }

    final class Env {
        let env: ScannerTests.Env
        var library: Library { env.library }
        var fs: FakeFileSystem { env.fs }
        init() throws { env = try ScannerTests.Env() }
        deinit { env.close() }

        func id(_ path: String) throws -> Int64 { try #require(try library.files().first { $0.relativePath == path }).id }
        func tag(_ text: String) throws -> TagName { try TagName(text) }

        /// Synchronous: inside an async test the pool's async overload would otherwise be chosen.
        func sql(_ statement: String, _ arguments: StatementArguments = []) throws {
            try library.database.write { try $0.execute(sql: statement, arguments: arguments) }
        }
        func count(_ statement: String) throws -> Int {
            try library.database.read { try Int.fetchOne($0, sql: statement) ?? 0 }
        }

        /// Stores each file's real full hash, as the hashing pipeline would.
        func storeFullHashes() throws {
            for file in try library.files() {
                let path = try library.absolutePath(of: file, fileSystem: fs)
                let hash = try #require(ContentHash.full(of: path, fileSystem: fs))
                try sql("UPDATE file SET fullHash = ? WHERE id = ?", [hash, file.id])
            }
        }

        func status(_ path: String, _ tag: String) throws -> String? {
            try library.tags(forFile: id(path), includeRejected: true).first { "\($0.name)" == tag }?.status
        }

        func run(_ layer: TagLayer, _ providers: [FakeProvider], rerun: Bool = false) async throws -> JobRunSummary {
            let usable = providers.filter(\.available)
            let version = AIPipeline.version(of: usable)
            if rerun { try library.rerunAILayer(layer, version: version) } else { try library.enqueueStaleAIJobs(layer: layer, version: version) }
            let handler = AITagJobHandler(library: library, fileSystem: fs, layer: layer, providers: usable, version: version)
            return await JobQueue(library: library, handlers: [layer.jobKind: handler], conditions: NoConditions(), sleep: { _ in }).runUntilIdle()
        }
    }

    static func candidate(_ ns: String, _ value: String, _ confidence: Double) -> TagCandidate {
        TagCandidate(namespace: ns, value: value, confidence: confidence)
    }

    // MARK: Suggestions

    @Test func layer3SuggestsIntoTheReviewQueueWithProviderAndModel() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        e.fs.addFile("/Fake/photos/notes.txt", content: Data("hello world".utf8))
        e.fs.addFile("/Fake/photos/clip.mov", size: 9)
        try e.env.scan()
        let provider = FakeProvider(results: [Self.candidate("subject", "cat", 0.9), Self.candidate("subject", "pet", 0.4)])
        let summary = try await e.run(.systemML, [provider])
        #expect(summary.processed == 2 && summary.failed == 0, "images and text only")

        let queue = try e.library.reviewQueue()
        #expect(queue.map(\.tag.description) == ["subject:cat", "subject:cat", "subject:pet", "subject:pet"])
        #expect(queue.allSatisfy { $0.provider == "fake" && $0.model == "fake-model" && $0.layer == 3 })
        #expect(try e.library.suggestionCount() == 4)
        // A suggestion is not an accepted tag: it does not show up in search until accepted.
        #expect(try e.library.search("subject:cat").isEmpty)
        #expect(provider.inputs.contains { $0.hasPrefix("text:notes.txt:11") })
    }

    @Test func acceptingAndRejectingDecidesWhatSearchSeesAndRejectionSticks() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        let provider = FakeProvider(results: [Self.candidate("subject", "cat", 0.9), Self.candidate("subject", "dog", 0.5)])
        try await e.run(.systemML, [provider])
        let id = try e.id("a.jpg")

        try e.library.acceptSuggestion(fileID: id, tag: e.tag("subject:cat"))
        try e.library.rejectSuggestion(fileID: id, tag: e.tag("subject:dog"))
        #expect(try e.library.search("subject:cat").map(\.id) == [id])
        #expect(try e.library.search("subject:dog").isEmpty)
        let accepted = try #require(try e.library.tags(forFile: id).first { "\($0.name)" == "subject:cat" })
        #expect(accepted.source == "ai" && accepted.status == "accepted" && accepted.provider == "fake" && accepted.confidence == 0.9)
        #expect(try e.library.suggestionCount() == 0)
        #expect(throws: SuggestionError.self) { try e.library.acceptSuggestion(fileID: id, tag: e.tag("subject:cat")) }

        // A re-run with the same answers must not bring the rejected tag back, nor disturb the accepted one.
        try await e.run(.systemML, [provider], rerun: true)
        #expect(try e.status("a.jpg", "subject:dog") == "rejected")
        #expect(try e.status("a.jpg", "subject:cat") == "accepted")
        #expect(try e.library.suggestionCount() == 0)
    }

    @Test func userAndRuleTagsWinAndAreNeverOverwritten() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        let id = try e.id("a.jpg")
        try e.library.addTag("subject:cat", toFile: id)
        let provider = FakeProvider(results: [Self.candidate("subject", "cat", 0.99), Self.candidate("subject", "tabby", 0.6)])
        try e.library.setAutoAcceptThreshold(0.5, forRoot: e.env.rootID)
        try await e.run(.systemML, [provider])
        let cat = try #require(try e.library.tags(forFile: id).first { "\($0.name)" == "subject:cat" })
        #expect(cat.source == "user" && cat.confidence == nil && cat.provider == nil)

        // The user removes the tag the model had suggested: it is rejected, not deleted, so it is not suggested again.
        try e.library.removeTag("subject:tabby", fromFile: id)
        #expect(try e.status("a.jpg", "subject:tabby") == "rejected")
        try await e.run(.systemML, [provider], rerun: true)
        #expect(try e.status("a.jpg", "subject:tabby") == "rejected")
    }

    @Test func autoAcceptThresholdAcceptsAtOrAboveAndIsPerRoot() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        #expect(try e.library.roots().first?.autoAcceptThreshold == nil)
        try e.library.setAutoAcceptThreshold(0.8, forRoot: e.env.rootID)
        #expect(throws: SuggestionError.self) { try e.library.setAutoAcceptThreshold(1.5, forRoot: e.env.rootID) }
        let provider = FakeProvider(results: [Self.candidate("subject", "cat", 0.8), Self.candidate("subject", "dog", 0.79)])
        try await e.run(.systemML, [provider])
        #expect(try e.status("a.jpg", "subject:cat") == "accepted")
        #expect(try e.status("a.jpg", "subject:dog") == "suggested")
        #expect(try e.library.search("subject:cat").count == 1)
        // Raising review decisions in bulk.
        #expect(try e.library.acceptSuggestions(minConfidence: 0.9) == 0)
        #expect(try e.library.acceptSuggestions(minConfidence: 0.5) == 1)
    }

    @Test func aRerunReplacesPendingSuggestionsOnlyAndRecordsTheNewModel() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        let id = try e.id("a.jpg")
        let old = FakeProvider(results: [Self.candidate("subject", "cat", 0.9), Self.candidate("subject", "blurry", 0.4)])
        try await e.run(.systemML, [old])
        try e.library.acceptSuggestion(fileID: id, tag: e.tag("subject:cat"))

        let newer = FakeProvider(revision: 2, results: [Self.candidate("subject", "kitten", 0.7)])
        // A different provider version makes the layer due again without being asked.
        #expect(try e.library.enqueueStaleAIJobs(layer: .systemML, version: AIPipeline.version(of: [newer])) == 1)
        try e.library.clearFailedJobs()
        try await e.run(.systemML, [newer])
        #expect(try e.status("a.jpg", "subject:blurry") == nil, "an unjudged suggestion the new model does not repeat is dropped")
        #expect(try e.status("a.jpg", "subject:cat") == "accepted", "an accepted AI tag stays")
        #expect(try e.status("a.jpg", "subject:kitten") == "suggested")
        #expect(try e.library.reviewQueue().first?.provider == "fake")
    }

    @Test func aFileChangeMakesTheLayerDueAgainButNothingElseDoes() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        let provider = FakeProvider(results: [Self.candidate("subject", "cat", 0.9)])
        try await e.run(.systemML, [provider])
        let version = AIPipeline.version(of: [provider])
        #expect(try e.library.enqueueStaleAIJobs(layer: .systemML, version: version) == 0)
        e.fs.overwrite("/Fake/photos/a.jpg", with: Data(count: 50), modified: Date().addingTimeInterval(100))
        try e.env.scan()
        #expect(try e.library.enqueueStaleAIJobs(layer: .systemML, version: version) == 1)
    }

    @Test func placeholdersAreNeverQueuedOrShownToAProvider() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/cloud.jpg", size: 9, dataless: true)
        try e.env.scan()
        let provider = FakeProvider(results: [Self.candidate("subject", "cat", 0.9)])
        let summary = try await e.run(.systemML, [provider])
        #expect(summary.processed == 0 && provider.inputs.isEmpty)

        // Even a job that was queued before the file was evicted does nothing.
        try e.library.enqueueJobs(kind: .tagSystemML, fileIDs: [e.id("cloud.jpg")])
        let handler = AITagJobHandler(library: e.library, fileSystem: e.fs, layer: .systemML, providers: [provider], version: 1)
        _ = await JobQueue(library: e.library, handlers: [.tagSystemML: handler], conditions: NoConditions(), sleep: { _ in }).runUntilIdle()
        #expect(provider.inputs.isEmpty)
    }

    @Test func layer4IsOffUntilARootEnablesAKindAndFollowsTheSetting() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        e.fs.addFile("/Fake/photos/notes.txt", content: Data("words".utf8))
        try e.env.scan()
        let llm = FakeProvider(id: "llm", layer: .llm, results: [Self.candidate("topic", "travel", 0.7)])
        let version = AIPipeline.version(of: [llm])
        #expect(try e.library.roots().first?.layer4Kinds == [])
        #expect(try e.library.enqueueStaleAIJobs(layer: .llm, version: version) == 0, "off by default for every root")

        try e.library.setLayer4Kinds([.text], forRoot: e.env.rootID)
        #expect(try e.library.roots().first?.layer4Kinds == [.text])
        #expect(try e.library.enqueueStaleAIJobs(layer: .llm, version: version) == 1, "only the enabled kind")
        let summary = try await e.run(.llm, [llm])
        #expect(summary.processed == 1)
        #expect(try e.status("notes.txt", "topic:travel") == "suggested")
        #expect(try e.status("a.jpg", "topic:travel") == nil)

        // Switched off after queueing: the handler checks again and does nothing.
        try e.library.rerunAILayer(.llm, version: version)
        try e.library.setLayer4Kinds([], forRoot: e.env.rootID)
        let handler = AITagJobHandler(library: e.library, fileSystem: e.fs, layer: .llm, providers: [llm], version: version)
        let before = llm.inputs.count
        _ = await JobQueue(library: e.library, handlers: [.tagLLM: handler], conditions: NoConditions(), sleep: { _ in }).runUntilIdle()
        #expect(llm.inputs.count == before)
    }

    @Test func aFailingProviderIsRetriedAndAWorkingOneStillAnswers() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        let broken = FakeProvider(id: "broken"); broken.failing = true
        let working = FakeProvider(id: "working", results: [Self.candidate("subject", "cat", 0.9)])
        let both = try await e.run(.systemML, [broken, working])
        #expect(both.failed == 0)
        #expect(try e.status("a.jpg", "subject:cat") == "suggested")

        let e2 = try Env()
        e2.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e2.env.scan()
        let only = FakeProvider(); only.failing = true
        let version = AIPipeline.version(of: [only])
        try e2.library.enqueueStaleAIJobs(layer: .systemML, version: version)
        let handler = AITagJobHandler(library: e2.library, fileSystem: e2.fs, layer: .systemML, providers: [only], version: version)
        var settings = JobQueue.Settings(); settings.retryDelay = 0
        let summary = await JobQueue(library: e2.library, handlers: [.tagSystemML: handler], conditions: NoConditions(), settings: settings, sleep: { _ in }).runUntilIdle()
        #expect(summary.failed >= 1)
        #expect(try e2.library.suggestionCount() == 0)
        // Nothing was recorded as run, so the layer stays due.
        #expect(try e2.count("SELECT COUNT(*) FROM file_layer_run WHERE layer = 3") == 0)
    }

    @Test func tagsTheGrammarRefusesAreDroppedNotGuessed() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        let provider = FakeProvider(results: [Self.candidate("type", "photo", 0.9), Self.candidate("subject", "a:b", 0.9),
                                              Self.candidate("subject", "", 0.9), Self.candidate("Subject", "Wine Glass", 2)])
        try await e.run(.systemML, [provider])
        let queue = try e.library.reviewQueue()
        #expect(queue.map(\.tag.description) == ["subject:wine_glass"])
        #expect(queue.first?.confidence == 1, "confidence is clamped to 0...1")
    }

    @Test func aiLayersAreNotQueuedByTheDeterministicEnqueue() throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        try e.library.enqueueStaleTaggingJobs(layers: TagLayer.allCases)
        #expect(try e.library.jobs().allSatisfy { $0.kind == .tagMetadata })
        try e.library.enqueueDueJobs()
        #expect(try e.library.jobs().allSatisfy { [.tagMetadata, .fingerprint].contains($0.kind) })
        try e.library.enqueueDueJobs(ai: [.systemML: 1])
        #expect(try e.library.jobs().contains { $0.kind == .tagSystemML })
    }

    @Test func pipelineOnlyHandlesLayersWithAUsableProvider() async throws {
        let e = try Env()
        let off = FakeProvider(id: "llm", layer: .llm); off.available = false
        let on = FakeProvider(id: "ml")
        let pipeline = AIPipeline(providers: [off, on], translator: FakeTranslator(["x"]))
        #expect(await pipeline.layerVersions().keys.sorted { $0.rawValue < $1.rawValue } == [.systemML])
        let handlers = await pipeline.handlers(library: e.library, fileSystem: e.fs)
        #expect(Set(handlers.keys) == [.tagSystemML])
        #expect(await pipeline.status().map(\.availability) == [.unavailable("off"), .available])
        #expect(AIPipeline.version(of: [on]) != AIPipeline.version(of: [FakeProvider(id: "ml", revision: 2)]))
        #expect(AIPipeline.version(of: [on]) == AIPipeline.version(of: [FakeProvider(id: "ml")]))
    }

    // MARK: Fingerprints and near-duplicates

    final class FakeFingerprinter: ImageFingerprinter, @unchecked Sendable {
        let algorithm = 1
        var hashes: [String: UInt64] = [:]
        func fingerprint(path: String) throws -> UInt64 {
            guard let h = hashes[path] else { throw ThumbnailRenderError.unreadable(path) }
            return h
        }
    }

    final class NearEnv {
        let e: Env
        let prints = FakeFingerprinter()
        var library: Library { e.library }
        init() throws { e = try Env() }

        func add(_ name: String, hash: UInt64, content: String? = nil, size: Int64 = 100) {
            let path = "/Fake/photos/\(name)"
            if let content { e.fs.addFile(path, content: Data(content.utf8)) } else { e.fs.addFile(path, size: size) }
            prints.hashes[path] = hash
        }

        func fingerprintAll() async throws {
            try e.env.scan()
            try library.enqueueFingerprintJobs()
            let handler = FingerprintJobHandler(library: library, fileSystem: e.fs, fingerprinter: prints)
            let summary = await JobQueue(library: library, handlers: [.fingerprint: handler], conditions: NoConditions(), sleep: { _ in }).runUntilIdle()
            #expect(summary.failed == 0)
        }

        func groups() throws -> [[String]] {
            try library.duplicateGroups(includeReviewed: true).filter { $0.kind == .near }
                .map { $0.members.map(\.relativePath).sorted() }.sorted { $0.first! < $1.first! }
        }
    }

    @Test func fingerprintsAreStoredForLocalImagesOnlyAndRefreshedWhenAFileChanges() async throws {
        let n = try NearEnv()
        n.add("a.jpg", hash: 0xF0F0)
        n.add("notes.txt", hash: 1)
        n.e.fs.addFile("/Fake/photos/cloud.jpg", size: 9, dataless: true)
        n.prints.hashes["/Fake/photos/cloud.jpg"] = 7
        try await n.fingerprintAll()
        #expect(try n.library.fingerprint(forFile: n.e.id("a.jpg")) == 0xF0F0)
        #expect(try n.library.fingerprint(forFile: n.e.id("notes.txt")) == nil)
        #expect(try n.library.fingerprint(forFile: n.e.id("cloud.jpg")) == nil)
        #expect(try n.library.enqueueFingerprintJobs() == 0)

        n.prints.hashes["/Fake/photos/a.jpg"] = 0x0F0F
        n.e.fs.overwrite("/Fake/photos/a.jpg", with: Data(count: 50), modified: Date().addingTimeInterval(100))
        try n.e.env.scan()
        #expect(try n.library.enqueueFingerprintJobs() == 1)
        #expect(try n.library.enqueueFingerprintJobs(algorithm: 2) == 0, "already queued")
    }

    @Test func nearDuplicateGroupsChainWithinTheDistanceAndKeepUnrelatedImagesOut() async throws {
        let n = try NearEnv()
        n.add("orig.jpg", hash: 0x0123_4567_89AB_CDEF)
        n.add("resized.jpg", hash: 0x0123_4567_89AB_CDEF ^ 0b1011)                // 3 bits away
        n.add("edited.jpg", hash: 0x0123_4567_89AB_CDEF ^ 0b1011 ^ (0b111 << 40))  // 3 more from resized, 6 from orig
        n.add("far.jpg", hash: 0x0123_4567_89AB_CDEF ^ 0xFF)                        // 8 bits from orig, 5 from resized
        n.add("other.jpg", hash: 0xFEDC_BA98_7654_3210)
        try await n.fingerprintAll()
        #expect(try n.library.refreshNearDuplicateGroups(maxDistance: 6) == 1)
        // far.jpg is 8 bits from orig and 5 from resized (0xFF vs 0b1011 differ in 0b11110100), so it chains in through resized.
        let expected = Set(["orig.jpg", "resized.jpg", "edited.jpg", "far.jpg"])
        #expect(DifferenceHasher.distance(0xFF, 0b1011) == 5)
        #expect(try n.groups() == [expected.sorted()])
        let group = try #require(try n.library.duplicateGroups().first)
        #expect(group.kind == .near && group.contentHash == nil)
        #expect(group.members.allSatisfy { $0.similarity != nil && $0.similarity! > 0.8 })
        #expect(try n.library.search("dup:near").count == expected.count)
        #expect(try n.library.search("dup:near -dup:exact").count == expected.count)
        #expect(try n.library.search("dup:near root:\(n.e.env.rootID) \"other\"").isEmpty)
    }

    @Test func aTighterDistanceSplitsTheGroup() async throws {
        let n = try NearEnv()
        n.add("a.jpg", hash: 0)
        n.add("b.jpg", hash: 0b1)          // 1 bit
        n.add("c.jpg", hash: 0b111111)     // 6 bits from a
        try await n.fingerprintAll()
        #expect(try n.library.refreshNearDuplicateGroups(maxDistance: 1) == 1)
        #expect(try n.groups() == [["a.jpg", "b.jpg"]])
        #expect(try n.library.refreshNearDuplicateGroups(maxDistance: 6) == 1)
        #expect(try n.groups() == [["a.jpg", "b.jpg", "c.jpg"]])
        #expect(throws: OperationError.self) { try n.library.refreshNearDuplicateGroups(maxDistance: 40) }
    }

    @Test func aGroupOfByteIdenticalFilesIsLeftToTheExactReport() async throws {
        let n = try NearEnv()
        n.add("a.jpg", hash: 5, content: String(repeating: "x", count: 300))
        n.add("b.jpg", hash: 5, content: String(repeating: "x", count: 300))
        n.add("c.jpg", hash: 5, content: String(repeating: "y", count: 300))
        try await n.fingerprintAll()
        // a and b are byte-identical, c shows the same picture with different bytes: one near group of three.
        try n.e.storeFullHashes()
        try n.library.refreshNearDuplicateGroups()
        #expect(try n.groups() == [["a.jpg", "b.jpg", "c.jpg"]])

        // Once c is byte-identical too, the three are exact duplicates and not a near group.
        try n.e.sql("UPDATE file SET fullHash = (SELECT fullHash FROM file WHERE relativePath = 'a.jpg')")
        try n.library.refreshNearDuplicateGroups()
        #expect(try n.groups() == [])
    }

    @Test func aHardLinkCountsOnceAndAResizeIsNotItsOriginalsDuplicate() async throws {
        let n = try NearEnv()
        n.add("a.jpg", hash: 9)
        n.add("b.jpg", hash: 9)
        try await n.fingerprintAll()
        // Make b the same file as a (a hard link).
        try n.e.sql("UPDATE file SET fileID = (SELECT fileID FROM file WHERE relativePath = 'a.jpg') WHERE relativePath = 'b.jpg'")
        #expect(try n.library.refreshNearDuplicateGroups() == 0)

        // A file and its own resize (linked by hash) never group.
        try n.e.sql("UPDATE file SET fileID = 12345 WHERE relativePath = 'b.jpg'")
        #expect(try n.library.refreshNearDuplicateGroups() == 1, "two different files with one picture")
        let aHash = Data(repeating: 0xAA, count: 32)
        try n.e.sql("UPDATE file SET fullHash = ? WHERE relativePath = 'a.jpg'", [aHash])
        try n.e.sql("""
            INSERT INTO file_link (derivedFileID, originalHash, originalSize, kind, createdAt)
            SELECT id, ?, 100, 'resize', ? FROM file WHERE relativePath = 'b.jpg'
            """, [aHash, Date()])
        #expect(try n.library.refreshNearDuplicateGroups() == 0)
    }

    @Test func unchangedGroupsKeepTheirReviewedStatusAndChangedOnesReopen() async throws {
        let n = try NearEnv()
        n.add("a.jpg", hash: 0)
        n.add("b.jpg", hash: 0b11)
        try await n.fingerprintAll()
        try n.library.refreshNearDuplicateGroups()
        let group = try #require(try n.library.duplicateGroups().first)
        try n.library.setDuplicateGroupReviewed(group.id, reviewed: true)
        try n.library.refreshNearDuplicateGroups()
        #expect(try n.library.duplicateGroups().isEmpty)
        #expect(try n.library.duplicateGroups(includeReviewed: true).count == 1)

        n.add("c.jpg", hash: 0b111)
        try await n.fingerprintAll()
        try n.library.refreshNearDuplicateGroups()
        #expect(try n.library.duplicateGroups().first?.members.count == 3, "a new member reopens it")

        // Near groups are suggestions only: they cannot be resolved.
        let open = try #require(try n.library.duplicateGroups().first)
        #expect(throws: OperationError.self) {
            try n.library.planResolution(groupID: open.id, action: .trash, keep: open.members[0].id, fileSystem: n.e.fs)
        }
    }

    @Test func missingFilesLeaveAGroup() async throws {
        let n = try NearEnv()
        n.add("a.jpg", hash: 0)
        n.add("b.jpg", hash: 1)
        try await n.fingerprintAll()
        try n.library.refreshNearDuplicateGroups()
        #expect(try n.groups().count == 1)
        n.e.fs.removeItem("/Fake/photos/b.jpg")
        try n.e.env.scan()
        try n.library.refreshNearDuplicateGroups()
        #expect(try n.groups().isEmpty)
    }

    // The real hasher, on images generated here.
    static func writeImage(_ path: String, size: Int, draw: (CGContext, Int) -> Void) throws {
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context, size)
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func theDifferenceHashSurvivesAResizeAndSeparatesDifferentPictures() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        func gradient(_ c: CGContext, _ s: Int) {
            let colors = [CGColor(red: 0.05, green: 0.1, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.8, blue: 0.1, alpha: 1)] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: s, y: s / 3), options: [])
            c.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            c.fill(CGRect(x: s / 5, y: s / 2, width: s / 3, height: s / 4))
        }
        func stripes(_ c: CGContext, _ s: Int) {
            for i in 0..<9 {
                c.setFillColor(CGColor(gray: i % 2 == 0 ? 0.1 : 0.9, alpha: 1))
                c.fill(CGRect(x: i * s / 9, y: 0, width: s / 9 + 1, height: s))
            }
        }
        try Self.writeImage(tmp.path + "/big.png", size: 800, draw: gradient)
        try Self.writeImage(tmp.path + "/small.png", size: 160, draw: gradient)
        try Self.writeImage(tmp.path + "/stripes.png", size: 800, draw: stripes)
        let hasher = DifferenceHasher()
        let big = try hasher.fingerprint(path: tmp.path + "/big.png")
        let small = try hasher.fingerprint(path: tmp.path + "/small.png")
        let stripes = try hasher.fingerprint(path: tmp.path + "/stripes.png")
        #expect(DifferenceHasher.distance(big, small) <= Library.nearDuplicateDistance)
        #expect(DifferenceHasher.distance(big, stripes) > Library.nearDuplicateDistance)
        #expect(throws: ThumbnailRenderError.self) { try hasher.fingerprint(path: tmp.path + "/missing.png") }
        #expect(DifferenceHasher.distance(0, UInt64.max) == 64)
    }

    // MARK: Natural-language queries

    struct FakeTranslator: QueryTranslationProvider {
        let info = ProviderInfo(id: "fake-translator", model: "m", revision: 1)
        final class State: @unchecked Sendable { var answers: [String]; var asked: [String] = []; init(_ a: [String]) { answers = a } }
        let state: State
        var available = true
        init(_ answers: [String]) { state = State(answers) }
        func availability() async -> ProviderAvailability { available ? .available : .unavailable("model missing") }
        func translate(_ request: String, vocabulary: QueryVocabulary) async throws -> String {
            state.asked.append(request)
            return state.answers.isEmpty ? "" : state.answers.removeFirst()
        }
    }

    @Test func aTranslatedQueryIsCheckedWithTheRealParserAndShownBeforeItRuns() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/cat.jpg", size: 9)
        try e.env.scan()
        try e.library.addTag("animal:cat", toFile: e.id("cat.jpg"))

        let fake = FakeTranslator(["```\ntype:image animal:cat\n```"])
        let result = try await QueryTranslator(provider: fake).translate("pictures of cats", in: e.library)
        #expect(result.query == "type:image animal:cat" && result.request == "pictures of cats")
        // Translating runs nothing and changes nothing; running is the caller's separate step.
        #expect(try e.library.search(result.query).count == 1)

        let instructions = QueryTranslator.instructions(vocabulary: try e.library.queryVocabulary())
        #expect(instructions.contains("animal:cat") && instructions.contains("animal"))
    }

    @Test func aBadAnswerIsRetriedOnceWithTheErrorThenGivenUp() async throws {
        let e = try Env()
        let retry = FakeTranslator(["type:(", "ext:png"])
        let ok = try await QueryTranslator(provider: retry).translate("pngs", in: e.library)
        #expect(ok.query == "ext:png")
        #expect(retry.state.asked.count == 2 && retry.state.asked[1].contains("rejected"))

        let hopeless = FakeTranslator(["size:>>", "type:nope"])
        await #expect(throws: QueryTranslationError.self) { try await QueryTranslator(provider: hopeless).translate("x", in: e.library) }
        let empty = FakeTranslator(["", "  "])
        await #expect(throws: QueryTranslationError.empty) { try await QueryTranslator(provider: empty).translate("x", in: e.library) }

        var off = FakeTranslator(["ext:png"]); off.available = false
        await #expect(throws: QueryTranslationError.unavailable("model missing")) { try await QueryTranslator(provider: off).translate("x", in: e.library) }
        #expect(off.state.asked.isEmpty)
    }

    @Test func translatorCleaningStripsFencesAndLabels() {
        #expect(QueryTranslator.clean("  `ext:png`  ") == "ext:png")
        #expect(QueryTranslator.clean("```text\nquery: ext:png size:>1mb\n```") == "ext:png size:>1mb")
        #expect(QueryTranslator.clean("") == "")
    }
}
