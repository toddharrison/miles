import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MilesCore

@Suite("Tagging layers 1 and 2")
struct TaggingLayerTests {
    final class FakeProbe: MetadataProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var infos: [String: MediaInfo] = [:]
        var calls: [String] { lock.withLock { _calls } }
        func probe(path: String, kind: FileKind) async throws -> MediaInfo {
            lock.withLock { _calls.append(path) }
            guard let info = infos[path] else { throw ThumbnailRenderError.unreadable(path) }
            return info
        }
    }

    static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    static let y2021 = Date(timeIntervalSince1970: 1_620_000_000)   // May 2021
    static let y2023 = Date(timeIntervalSince1970: 1_690_000_000)   // July 2023

    final class Env {
        let env: ScannerTests.Env
        let probe = FakeProbe()
        var library: Library { env.library }
        var fs: FakeFileSystem { env.fs }
        init() throws { env = try ScannerTests.Env() }
        deinit { env.close() }

        func id(_ path: String) throws -> Int64 { try #require(try library.files().first { $0.relativePath == path }).id }

        /// Queues what is due and runs it, with no throttling.
        @discardableResult
        func process(layers: [TagLayer] = TagLayer.allCases) async throws -> JobRunSummary {
            try library.enqueueStaleTaggingJobs(layers: layers)
            let handlers: [JobKind: any JobHandler] = [
                .tagMetadata: MetadataJobHandler(library: library, fileSystem: fs, probe: probe, calendar: TaggingLayerTests.utc),
                .tagPathRules: PathRuleJobHandler(library: library),
            ]
            return await JobQueue(library: library, handlers: handlers, conditions: NoConditions(), sleep: { _ in }).runUntilIdle()
        }

        func tags(_ path: String, includeRejected: Bool = false) throws -> [String] {
            try library.tags(forFile: id(path), includeRejected: includeRejected).map { "\($0.name)" }
        }
    }

    // MARK: Layer 1

    @Test func bucketsAreAsDocumented() {
        #expect([100, 1279, 1280, 1919, 1920, 3839, 3840, 9000].map(MetadataTagger.resolution(longestEdge:))
                == ["sd", "sd", "hd", "hd", "fhd", "fhd", "uhd", "uhd"])
        #expect([0, 59.9, 60, 599, 600, 3599, 3600].map(MetadataTagger.length(seconds:))
                == ["short", "short", "medium", "medium", "long", "long", "feature"])
    }

    @Test func imageGetsKindYearAndResolution() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9, modified: Self.y2021)
        e.probe.infos["/Fake/photos/a.jpg"] = MediaInfo(width: 4000, height: 3000)
        try e.env.scan()
        let summary = try await e.process(layers: [.metadata])
        #expect(summary.processed == 1 && summary.failed == 0)
        #expect(try e.tags("a.jpg") == ["kind:image", "resolution:uhd", "year:2021"])
        let rows = try e.library.tags(forFile: e.id("a.jpg"))
        #expect(rows.allSatisfy { $0.source == "rule" && $0.status == "accepted" && $0.provider == "metadata" })
    }

    @Test func videoGetsLengthAndOtherFilesGetNoKindTag() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/clip.mov", size: 9, modified: Self.y2023)
        e.fs.addFile("/Fake/photos/blob.xyzunknown", size: 9, modified: Self.y2023)
        e.probe.infos["/Fake/photos/clip.mov"] = MediaInfo(width: 1920, height: 1080, duration: 125)
        try e.env.scan()
        try await e.process(layers: [.metadata])
        #expect(try e.tags("clip.mov") == ["kind:video", "length:medium", "resolution:fhd", "year:2023"])
        #expect(try e.tags("blob.xyzunknown") == ["year:2023"])
    }

    @Test func anUnreadableFileStillGetsTheIndexTagsAndIsNotRetried() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/broken.jpg", size: 9, modified: Self.y2023)    // the probe throws
        try e.env.scan()
        let first = try await e.process(layers: [.metadata])
        #expect(first.failed == 0)
        #expect(try e.tags("broken.jpg") == ["kind:image", "year:2023"])
        #expect(try e.library.enqueueStaleTaggingJobs() == 0)
    }

    @Test func aPlaceholderIsNeverReadAndIsRetriedOnceItIsLocal() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/cloud.jpg", size: 9, dataless: true, modified: Self.y2023)
        e.probe.infos["/Fake/photos/cloud.jpg"] = MediaInfo(width: 5000, height: 4000)
        try e.env.scan()
        try await e.process(layers: [.metadata])
        #expect(e.probe.calls.isEmpty, "a placeholder must never be read, which would download it")
        #expect(try e.tags("cloud.jpg") == ["kind:image", "year:2023"])
        #expect(try e.library.enqueueStaleTaggingJobs() == 0, "still a placeholder: nothing to retry yet")

        e.fs.addFile("/Fake/photos/cloud.jpg", size: 9, dataless: false, modified: Self.y2023)
        try await e.library.database.write { try $0.execute(sql: "UPDATE file SET icloudStatus = 'local'") }
        try await e.process(layers: [.metadata])
        #expect(try e.tags("cloud.jpg") == ["kind:image", "resolution:uhd", "year:2023"])
    }

    @Test func aFileThatBecamePlaceholderAfterIndexingIsNotReadEither() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9, modified: Self.y2023)       // indexed as local
        try e.env.scan()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9, dataless: true, modified: Self.y2023)   // evicted since
        try await e.process(layers: [.metadata])
        #expect(e.probe.calls.isEmpty)
    }

    @Test func aChangedFileIsRetaggedAndTheOldYearGoes() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9, modified: Self.y2021)
        e.probe.infos["/Fake/photos/a.jpg"] = MediaInfo(width: 800, height: 600)
        try e.env.scan()
        try await e.process(layers: [.metadata])
        #expect(try e.tags("a.jpg") == ["kind:image", "resolution:sd", "year:2021"])
        #expect(try e.library.enqueueStaleTaggingJobs() == 0, "nothing changed, nothing due")

        e.fs.addFile("/Fake/photos/a.jpg", size: 99, modified: Self.y2023)
        e.probe.infos["/Fake/photos/a.jpg"] = MediaInfo(width: 2000, height: 1000)
        try e.env.scan()
        try await e.process(layers: [.metadata])
        #expect(try e.tags("a.jpg") == ["kind:image", "resolution:fhd", "year:2023"])
    }

    @Test func userTagsAndRejectionsSurviveARerun() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9, modified: Self.y2021)
        try e.env.scan()
        let id = try e.id("a.jpg")
        try e.library.addTag("year:1999", toFile: id)             // the user's own tag in a system namespace
        try await e.process(layers: [.metadata])
        try e.library.removeTag("kind:image", fromFile: id)       // reject an automatic tag
        try e.library.addTag("year:2021", toFile: id)             // and take over another as the user's

        try e.library.rerunLayer(.metadata)
        try await e.process(layers: [.metadata])
        let tags = try e.library.tags(forFile: id, includeRejected: true)
        #expect(tags.map { "\($0.name)" } == ["kind:image", "year:1999", "year:2021"])
        #expect(tags.first { "\($0.name)" == "kind:image" }?.status == "rejected", "a rejected tag stays rejected")
        #expect(tags.first { "\($0.name)" == "year:1999" }?.source == "user")
        #expect(tags.first { "\($0.name)" == "year:2021" }?.source == "user", "a user tag is not demoted by the layer")
    }

    @Test func layerNamespacesAreMarkedSystemManagedButStayOpenToTheUser() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9, modified: Self.y2021)
        try e.env.scan()
        try await e.process(layers: [.metadata])
        let system = try await e.library.database.read { try String.fetchAll($0, sql: "SELECT name FROM namespace WHERE isSystem = 1 ORDER BY name") }
        #expect(system == ["kind", "year"])
        try e.library.addTag("year:memories", toFile: e.id("a.jpg"))
        #expect(try e.tags("a.jpg").contains("year:memories"))
    }

    @Test func missingFilesAreNotQueued() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.jpg", size: 9)
        try e.env.scan()
        try await e.library.database.write { try $0.execute(sql: "UPDATE file SET missingSince = ?", arguments: [Date()]) }
        #expect(try e.library.enqueueStaleTaggingJobs() == 0)
    }

    @Test func theRealProbeReadsImageDimensionsFromDisk() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let path = tmp.path + "/pic.png"
        let context = try #require(CGContext(data: nil, width: 5, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let info = try await SystemMetadataProbe().probe(path: path, kind: .image)
        #expect(info == MediaInfo(width: 5, height: 3, duration: nil))
        await #expect(throws: (any Error).self) { try await SystemMetadataProbe().probe(path: tmp.path + "/nope.png", kind: .image) }
    }

    // MARK: Layer 2

    @Test func ruleTagsFilesUnderMatchingFoldersWithCapturesAtAnyDepth() async throws {
        let e = try Env()
        for p in ["Games/Skyrim/shot1.png", "Games/Skyrim/deep/er/shot2.png", "games/Elden Ring/a.png", "Games/top.png", "Other/x.png"] {
            e.fs.addFile("/Fake/photos/" + p, size: 1)
        }
        try e.env.scan()
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process(layers: [.pathRules])
        func games(_ p: String) throws -> [String] { try e.tags(p).filter { $0.hasPrefix("game:") } }
        #expect(try games("Games/Skyrim/shot1.png") == ["game:skyrim"])
        #expect(try games("Games/Skyrim/deep/er/shot2.png") == ["game:skyrim"])
        #expect(try games("games/Elden Ring/a.png") == ["game:elden_ring"], "case-insensitive; the capture is normalized")
        #expect(try games("Games/top.png").isEmpty, "the file sits in Games itself, so * has no folder to capture")
        #expect(try games("Other/x.png").isEmpty)
        let row = try #require(try e.library.tags(forFile: e.id("Games/Skyrim/shot1.png")).first)
        #expect(row.source == "rule" && row.status == "accepted" && row.provider == "path-rules")
    }

    @Test func literalRulesAndDoubleStarMatching() throws {
        func tag(_ pattern: String, _ template: String, _ path: String) -> String? {
            PathRule(pattern: pattern, template: template).tag(forRelativePath: path).map(\.description)
        }
        #expect(tag("Work/Taxes", "topic:taxes", "Work/Taxes/2020/a.pdf") == "topic:taxes")
        #expect(tag("Work/Taxes", "topic:taxes", "Work/Taxes.pdf") == nil)
        #expect(tag("Work/Taxes", "topic:taxes", "Work/TaxesOld/a.pdf") == nil)
        #expect(tag("**/Trips/*", "trip:{1}", "Photos/2019/Trips/Rome/a.jpg") == "trip:rome")
        #expect(tag("**/Trips/*", "trip:{1}", "Trips/Rome/a.jpg") == "trip:rome", "** matches zero folders")
        #expect(tag("Photos/*/*", "year:{1}-{2}", "Photos/2019/Rome/a.jpg") == "year:2019-rome")
        #expect(tag("Gam*", "game:{1}", "Gaming/a.png") == "game:ing")
        #expect(tag("Game*", "game:{1}", "Game/a.png") == nil, "an empty capture is not a tag")
        #expect(tag("Games/*", "game:{1}", "Games/a:b/c.png") == nil, "a capture that is not a valid tag name is skipped")
        #expect(tag("Work", "work", "a.pdf") == nil, "top-level files have no folders to match")
    }

    @Test func badRulesAreRefused() throws {
        let e = try Env()
        let root = e.env.rootID
        #expect(throws: TagRuleError.emptyPattern) { try e.library.addTagRule(rootID: root, pattern: " / ", tag: "a") }
        #expect(throws: TagRuleError.self) { try e.library.addTagRule(rootID: root, pattern: "Games/*", tag: "game:{2}") }
        #expect(throws: TagRuleError.self) { try e.library.addTagRule(rootID: root, pattern: "Games", tag: "game:{1}") }
        #expect(throws: TagRuleError.self) { try e.library.addTagRule(rootID: root, pattern: "Games", tag: "type:game") }   // reserved namespace
        #expect(throws: TagRuleError.unknownRoot(99)) { try e.library.addTagRule(rootID: 99, pattern: "a", tag: "b") }
        try e.library.addTagRule(rootID: root, pattern: "Games", tag: "game")
        #expect(throws: TagRuleError.duplicate) { try e.library.addTagRule(rootID: root, pattern: "Games/", tag: "game") }
        #expect(try e.library.tagRules().count == 1)
    }

    @Test func removingARuleRemovesItsTagsButKeepsUserTags() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/Games/Skyrim/a.png", size: 1)
        e.fs.addFile("/Fake/photos/Games/Skyrim/b.png", size: 1)
        try e.env.scan()
        let rule = try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process(layers: [.pathRules])
        try e.library.addTag("game:skyrim", toFile: e.id("Games/Skyrim/b.png"))      // the user owns this one now
        #expect(try e.tags("Games/Skyrim/a.png").contains("game:skyrim"))

        try e.library.removeTagRule(id: rule.id)
        try await e.process(layers: [.pathRules])
        #expect(try !e.tags("Games/Skyrim/a.png").contains("game:skyrim"))
        #expect(try e.tags("Games/Skyrim/b.png").contains("game:skyrim"))
    }

    @Test func aRejectedRuleTagIsNotAppliedAgainEvenAfterRulesChange() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/Games/Skyrim/a.png", size: 1)
        try e.env.scan()
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process(layers: [.pathRules])
        let id = try e.id("Games/Skyrim/a.png")
        try e.library.removeTag("game:skyrim", fromFile: id)
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games", tag: "genre:games")   // changes the rule set
        try await e.process(layers: [.pathRules])
        #expect(try e.tags("Games/Skyrim/a.png") == ["genre:games"])
        #expect(try e.tags("Games/Skyrim/a.png", includeRejected: true).contains("game:skyrim"))
    }

    @Test func aMovedFileIsEvaluatedAgainAtItsNewPath() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/Inbox/a.png", size: 1)
        try e.env.scan()
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process(layers: [.pathRules])
        #expect(try e.tags("Inbox/a.png").filter { $0.hasPrefix("game:") }.isEmpty)

        let id = try e.id("Inbox/a.png")
        try await e.library.database.write { try $0.execute(sql: "UPDATE file SET relativePath = 'Games/Doom/a.png' WHERE id = ?", arguments: [id]) }
        try await e.process(layers: [.pathRules])
        #expect(try e.tags("Games/Doom/a.png").contains("game:doom"))
    }

    @Test func rootsWithoutRulesQueueNothingForLayerTwo() throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/a.png", size: 1)
        try e.env.scan()
        #expect(try e.library.enqueueStaleTaggingJobs(layers: [.pathRules]) == 0)
        #expect(try e.library.enqueueStaleTaggingJobs(layers: [.metadata]) == 1)
    }

    @Test func rulesAreScopedToTheirRoot() async throws {
        let e = try Env()
        try e.fs.createDirectory(at: "/Fake/other")
        let other = try e.library.addRoot(at: "/Fake/other", fileSystem: e.fs, registry: LibraryRegistry(preferences: InMemoryPreferences()))
        e.fs.addFile("/Fake/photos/Games/Doom/a.png", size: 1)
        e.fs.addFile("/Fake/other/Games/Doom/b.png", size: 1)
        try e.env.scan()
        try e.library.scan(rootID: other.id, scope: .full, fileSystem: e.fs, options: ScanOptions())
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process(layers: [.pathRules])
        let tagged = try await e.library.database.read {
            try String.fetchAll($0, sql: "SELECT f.relativePath FROM file_tag ft JOIN file f ON f.id = ft.fileID WHERE f.rootID = ?", arguments: [other.id])
        }
        #expect(tagged.isEmpty)
        #expect(try e.tags("Games/Doom/a.png") == ["game:doom"])
    }

    // MARK: Search, export, cascade

    @Test func automaticTagsAreSearchable() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/Games/Doom/a.png", size: 1, modified: Self.y2021)
        e.fs.addFile("/Fake/photos/b.png", size: 1, modified: Self.y2023)
        try e.env.scan()
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process()
        #expect(try e.library.search("game:doom").map(\.relativePath) == ["Games/Doom/a.png"])
        #expect(try e.library.search("year:2023").map(\.relativePath) == ["b.png"])
        #expect(try e.library.search("kind:image source:rule").count == 2)
    }

    @Test func rulesAndLayersGoIntoTheJSONExport() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/Games/Doom/a.png", size: 1)
        try e.env.scan()
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process()
        let export = try await e.library.database.read { try TagExport.make(from: $0, schemaVersion: 4, now: Date()) }
        #expect(export.tagRules.count == 1 && export.tagRules[0]["pattern"] == "Games/*")
        #expect(Set(export.fileTags.compactMap(\.layer)) == [1, 2])
        #expect(export.namespaces.first { $0.name == "game" }?.isSystem == true)
    }

    @Test func droppingARootRemovesItsRulesRunsAndJobs() async throws {
        let e = try Env()
        e.fs.addFile("/Fake/photos/Games/Doom/a.png", size: 1)
        try e.env.scan()
        try e.library.addTagRule(rootID: e.env.rootID, pattern: "Games/*", tag: "game:{1}")
        try await e.process()
        try e.library.enqueueJobs(kind: .tagMetadata, fileIDs: [e.id("Games/Doom/a.png")])
        try e.library.removeRoot(id: e.env.rootID)
        for table in ["tag_rule", "file_layer_run", "job", "file_tag"] {
            #expect(try await e.library.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") } == 0, "\(table)")
        }
    }
}
