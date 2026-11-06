import Foundation
import GRDB
import CryptoKit
import Testing
import ImageIO
import CoreGraphics
@testable import MilesCore

/// Deterministic stand-in for ImageIO. An "image" is a header line plus padding; its size follows
/// width x height x quality, so rules about size and dimensions can be tested exactly.
struct FakeTranscoder: ImageTranscoder {
    static func make(width: Int, height: Int, quality: Double = 0.95, format: String = "jpeg", frames: Int = 1, raw: Bool = false, gps: Bool = false) -> Data {
        let header = "IMG|\(format)|\(width)|\(height)|\(frames)|\(raw ? 1 : 0)|\(gps ? 1 : 0)|"
        var data = Data(header.utf8)
        let target = max(data.count, Int(Double(width * height) * quality / 1000))
        data.append(Data(repeating: 0x2e, count: target - data.count))
        return data
    }

    func inspect(_ data: Data) -> ImageInfo? {
        let parts = String(decoding: data.prefix(80), as: UTF8.self).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 7, parts[0] == "IMG", let w = Int(parts[2]), let h = Int(parts[3]), let frames = Int(parts[4]) else { return nil }
        return ImageInfo(format: ImageFormat(rawValue: parts[1]), width: w, height: h, frameCount: frames, isRaw: parts[5] == "1", hasLocation: parts[6] == "1")
    }

    func encode(_ data: Data, maxLongEdge: Int?, quality: Double, stripLocation: Bool) throws -> Data {
        guard let info = inspect(data), let format = info.format else { throw TranscodeError.unsupported }
        var (w, h) = (info.width, info.height)
        if let maxLongEdge, info.longEdge > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(info.longEdge)
            (w, h) = (Int(Double(w) * scale), Int(Double(h) * scale))
        }
        return Self.make(width: w, height: h, quality: quality, format: format.rawValue, gps: info.hasLocation && !stripLocation)
    }
}

@Suite("Managed roots, standardization and holdback")
struct ManagedTests {
    static let holdback = HoldbackLocator { _ in "/Fake/holdback" }

    final class Env {
        let env: ScannerTests.Env
        let t = FakeTranscoder()
        var fs: FakeFileSystem { env.fs }
        var library: Library { env.library }

        init(managed: Bool = true, rule: StandardizationRule? = StandardizationRule(maxBytes: 8_000, maxLongEdge: nil)) throws {
            env = try ScannerTests.Env()
            fs.volumeNeedsExistingPath = true
            if managed { try library.setManaged(true, forRoot: env.rootID) }
            if managed, let rule { try library.setStandardizationRule(rule, forRoot: env.rootID) }
        }
        deinit { env.close() }

        func add(_ name: String, _ data: Data) { fs.addFile("/Fake/photos/\(name)", content: data) }
        func id(_ name: String) throws -> Int64 { try #require(try library.files().first { $0.relativePath == name }).id }
        func plan(_ ids: [Int64]? = nil) throws -> StandardizationPlan {
            try library.planStandardization(rootID: env.rootID, fileIDs: ids, fileSystem: fs, transcoder: t)
        }
        func apply(_ plan: StandardizationPlan, now: Date = Date()) throws -> StandardizationOutcome {
            try library.applyStandardization(plan, fileSystem: fs, transcoder: t, holdback: ManagedTests.holdback, now: now)
        }
        func bytes(_ path: String) throws -> Data { try fs.readFile(at: path) }
    }

    /// 4000x3000 at quality 0.95 is 11,400 bytes: over an 8,000 byte limit; quality 0.65 (7,800) is the first step that fits (the 0.6 floor gives 7,200).
    static func big(quality: Double = 0.95) -> Data { FakeTranscoder.make(width: 4000, height: 3000, quality: quality) }

    // MARK: Opt-in

    @Test func nothingRunsOnAnUnmanagedRoot() throws {
        let e = try Env(managed: false)
        e.add("a.jpg", Self.big()); try e.env.scan()
        #expect(throws: OperationError.self) { try e.library.setStandardizationRule(StandardizationRule(maxBytes: 1000), forRoot: e.env.rootID) }
        #expect(throws: OperationError.self) { try e.plan() }
        let move = try e.library.planMoves([MoveRequest(fileID: try e.id("a.jpg"), toRelativePath: "b.jpg")], fileSystem: e.fs)
        #expect(move.isEmpty && move.skipped.first?.reason == "its root is not managed")
    }

    @Test func aManagedRootWithoutARuleRunsNothing() throws {
        let e = try Env(rule: nil)
        e.add("a.jpg", Self.big()); try e.env.scan()
        #expect(throws: OperationError.self) { try e.plan() }
    }

    @Test func aRuleNeedsAConstraintAndASaneFloor() throws {
        let e = try Env(rule: nil)
        #expect(throws: OperationError.self) { try e.library.setStandardizationRule(StandardizationRule(), forRoot: e.env.rootID) }
        #expect(throws: OperationError.self) { try e.library.setStandardizationRule(StandardizationRule(maxBytes: 10, qualityFloor: 0), forRoot: e.env.rootID) }
        try e.library.setStandardizationRule(StandardizationRule(maxLongEdge: 2000), forRoot: e.env.rootID)
        #expect(try e.library.roots().first?.standardization == StandardizationRule(maxLongEdge: 2000))
    }

    @Test func managedSettingsRoundTrip() throws {
        let e = try Env()
        try e.library.setHoldback(days: 7, releaseImmediately: true, forRoot: e.env.rootID)
        let root = try #require(try e.library.roots().first)
        #expect(root.isManaged && root.holdbackDays == 7 && root.releaseImmediately)
    }

    // MARK: Preview

    @Test func previewShowsSizesAndChangesNothing() throws {
        let e = try Env()
        e.add("a.jpg", Self.big()); try e.env.scan()
        let before = try e.bytes("/Fake/photos/a.jpg")
        let plan = try e.plan()
        let step = try #require(plan.steps.first)
        #expect(plan.steps.count == 1 && step.oldBytes == Int64(before.count) && step.newBytes <= 8_000 && step.newBytes < step.oldBytes)
        #expect(step.quality <= 0.85 && (step.newWidth, step.newHeight) == (4000, 3000))
        #expect(plan.bytesFreed == step.oldBytes - step.newBytes && plan.releasesImmediately == false && plan.holdbackDays == 30)
        #expect(try e.bytes("/Fake/photos/a.jpg") == before)
        #expect(try !e.fs.exists("/Fake/holdback") && (e.library.operations()).isEmpty)
    }

    @Test func skipsWhatMustNotBeReencoded() throws {
        let e = try Env()
        e.add("raw.jpg", FakeTranscoder.make(width: 4000, height: 3000, format: "jpeg", raw: true))
        e.add("anim.jpg", FakeTranscoder.make(width: 4000, height: 3000, frames: 12))
        e.add("shot.jpg", FakeTranscoder.make(width: 4000, height: 3000, format: "png"))
        e.add("junk.jpg", Data(repeating: 0x41, count: 9_000))
        e.add("small.jpg", FakeTranscoder.make(width: 1000, height: 1000))
        e.add("cloud.jpg", Self.big())
        e.add("ok.jpg", Self.big())
        try e.env.scan()
        e.fs.setDataless("/Fake/photos/cloud.jpg")
        _ = try e.env.scan()
        let plan = try e.plan()
        let reasons = Dictionary(uniqueKeysWithValues: plan.skipped.map { (($0.path as NSString).lastPathComponent, $0.reason) })
        #expect(reasons["raw.jpg"]?.contains("RAW") == true)
        #expect(reasons["anim.jpg"]?.contains("animated") == true)
        #expect(reasons["shot.jpg"]?.contains("only JPEG and HEIC") == true)
        #expect(reasons["junk.jpg"]?.contains("not a readable image") == true)
        #expect(reasons["cloud.jpg"]?.contains("not downloaded") == true)
        #expect(plan.alreadyCompliant == 1)                       // small.jpg
        #expect(plan.steps.map { ($0.path as NSString).lastPathComponent } == ["ok.jpg"])
        #expect(e.fs.downloads.isEmpty)
    }

    @Test func aFileThatCannotMeetTheRuleAboveTheFloorIsSkippedNotDegraded() throws {
        let e = try Env(rule: StandardizationRule(maxBytes: 3_000, qualityFloor: 0.6))
        e.add("a.jpg", Self.big()); try e.env.scan()   // 12,000 * 0.6 = 7,200 bytes at the floor
        let plan = try e.plan()
        #expect(plan.steps.isEmpty && plan.skipped.first?.reason.contains("quality floor") == true)
        #expect(try e.apply(plan).batch == nil)
        #expect(try e.bytes("/Fake/photos/a.jpg") == Self.big())
    }

    @Test func aLongEdgeRuleScalesDownAndRecordsDimensions() throws {
        let e = try Env(rule: StandardizationRule(maxLongEdge: 2000))
        e.add("a.jpg", Self.big()); try e.env.scan()
        let step = try #require(try e.plan().steps.first)
        #expect((step.newWidth, step.newHeight) == (2000, 1500) && step.maxLongEdge == 2000 && step.newBytes < step.oldBytes)
    }

    // MARK: Apply, holdback, links

    @Test func applyReplacesTheFileKeepsTheOriginalAndCarriesTagsOver() throws {
        let e = try Env()
        let original = Self.big()
        e.add("a.jpg", original); try e.env.scan()
        let id = try e.id("a.jpg")
        try e.library.addTag("holiday", toFile: id)
        let plan = try e.plan()
        let outcome = try e.apply(plan)
        #expect(outcome.resizedFileIDs == [id] && outcome.failures.isEmpty && outcome.bytesFreed == plan.bytesFreed)

        let now = try e.bytes("/Fake/photos/a.jpg")
        #expect(now.count <= 8_000 && now != original)
        let op = try #require(try e.library.operations(batch: outcome.batch).first)
        #expect(op.kind == .resize && op.state == .done && op.originalHash != nil && op.resultHash != nil)
        #expect(try e.bytes(try #require(op.holdbackPath)) == original)        // the original is kept, not deleted
        #expect(op.holdbackUntil != nil && op.releasedAt == nil)

        // The row kept its identity: tags, and the file's size and hashes follow the new content.
        #expect(try e.library.tags(forFile: id).map { $0.name.description } == ["general:holiday"])
        let file = try #require(try e.library.file(id: id))
        #expect(file.size == Int64(now.count) && file.missingSince == nil)
        #expect(try e.library.originalsOf(fileID: id).map(\.size) == [Int64(original.count)])
        #expect(try e.library.heldOriginals().map(\.operationID) == [op.id])
    }

    @Test func undoPutsTheOriginalBackAndTheResizedFileGoesToTheTrash() throws {
        let e = try Env()
        let original = Self.big()
        e.add("a.jpg", original); try e.env.scan()
        let id = try e.id("a.jpg")
        let outcome = try e.apply(try e.plan())
        let batch = try #require(outcome.batch)
        let resized = try e.bytes("/Fake/photos/a.jpg")

        let undo = try e.library.undoBatch(batch, fileSystem: e.fs)
        #expect(undo.undone == 1 && undo.stoppedBecause == nil)
        #expect(try e.bytes("/Fake/photos/a.jpg") == original)
        #expect(try e.library.file(id: id)?.size == Int64(original.count))
        #expect(try e.library.originalsOf(fileID: id).isEmpty && (e.library.heldOriginals()).isEmpty)
        let op = try #require(try e.library.operations(batch: batch).first)
        #expect(op.state == .undone)
        #expect(try e.bytes("\(FakeFileSystem.trashDirectory)/1-a.jpg") == resized)   // never deleted
        #expect(!e.fs.exists("/Fake/holdback/\(batch)"))
    }

    @Test func undoRefusesToReplaceAFileEditedAfterStandardizing() throws {
        let e = try Env()
        e.add("a.jpg", Self.big()); try e.env.scan()
        let batch = try #require(try e.apply(try e.plan()).batch)
        e.fs.overwrite("/Fake/photos/a.jpg", with: Data("edited".utf8), modified: Date())
        let undo = try e.library.undoBatch(batch, fileSystem: e.fs)
        #expect(undo.undone == 0 && undo.stoppedBecause?.contains("changed after") == true)
        #expect(try e.bytes("/Fake/photos/a.jpg") == Data("edited".utf8))
    }

    @Test func applyRefusesAFileThatChangedSinceThePreview() throws {
        let e = try Env()
        e.add("a.jpg", Self.big()); try e.env.scan()
        let plan = try e.plan()
        let edited = Self.big(quality: 0.9)
        e.fs.overwrite("/Fake/photos/a.jpg", with: edited, modified: Date(timeIntervalSince1970: 5))
        let outcome = try e.apply(plan)
        #expect(outcome.resizedFileIDs.isEmpty && outcome.failures.count == 1)
        #expect(try e.bytes("/Fake/photos/a.jpg") == edited && !e.fs.exists("/Fake/holdback"))
    }

    @Test func applyRefusesWhenTheRuleChangedSincePreview() throws {
        let e = try Env()
        e.add("a.jpg", Self.big()); try e.env.scan()
        let plan = try e.plan()
        try e.library.setStandardizationRule(StandardizationRule(maxBytes: 5_000), forRoot: e.env.rootID)
        #expect(throws: OperationError.self) { try e.apply(plan) }
    }

    @Test func stripLocationDropsGPSOnlyWhenAsked() throws {
        let e = try Env(rule: StandardizationRule(maxBytes: 8_000, stripLocation: true))
        e.add("a.jpg", FakeTranscoder.make(width: 4000, height: 3000, gps: true)); try e.env.scan()
        _ = try e.apply(try e.plan())
        #expect(e.t.inspect(try e.bytes("/Fake/photos/a.jpg"))?.hasLocation == false)

        let keep = try Env()
        keep.add("a.jpg", FakeTranscoder.make(width: 4000, height: 3000, gps: true)); try keep.env.scan()
        _ = try keep.apply(try keep.plan())
        #expect(keep.t.inspect(try keep.bytes("/Fake/photos/a.jpg"))?.hasLocation == true)
    }

    @Test func rerunsAreIdempotent() throws {
        let e = try Env()
        e.add("a.jpg", Self.big()); e.add("b.jpg", Self.big(quality: 0.9)); e.add("c.jpg", FakeTranscoder.make(width: 4000, height: 3000, quality: 0.2))
        try e.env.scan()
        let first = try e.apply(try e.plan())
        #expect(first.resizedFileIDs.count == 2)
        let sizes = try ["a.jpg", "b.jpg", "c.jpg"].map { try e.bytes("/Fake/photos/\($0)").count }
        try e.env.scan()
        let again = try e.plan()
        #expect(again.isEmpty && again.alreadyCompliant == 3)
        #expect(try e.apply(again).batch == nil)
        #expect(try ["a.jpg", "b.jpg", "c.jpg"].map { try e.bytes("/Fake/photos/\($0)").count } == sizes)
        #expect(try e.library.operations().count == 2)
    }

    @Test func aBulkRunTakesASnapshotFirst() throws {
        let e = try Env()
        e.add("a.jpg", Self.big()); e.add("b.jpg", Self.big(quality: 0.9)); try e.env.scan()
        #expect(try e.library.backups().filter { $0.kind == .preBulk }.isEmpty)
        _ = try e.apply(try e.plan())
        #expect(try e.library.backups().filter { $0.kind == .preBulk }.count == 1)
    }

    // MARK: Duplicates and links

    @Test func aFileAndItsOwnResizeAreNeverDuplicates() throws {
        let e = try Env()
        let original = Self.big()
        e.add("a.jpg", original); try e.env.scan()
        _ = try e.apply(try e.plan())
        // A stray copy of the original appears later (restored by hand, say).
        e.add("stray.jpg", original); try e.env.scan()
        // The stray copy has a unique size, so Miles would not hash it; give it the hash a hashing job would.
        let strayID = try e.id("stray.jpg")
        let hash = Data(SHA256.hash(data: original))
        try e.library.database.write { try $0.execute(sql: "UPDATE file SET fullHash = ? WHERE id = ?", arguments: [hash, strayID]) }
        try e.library.refreshDuplicateGroups()
        #expect(try e.library.duplicateGroups(includeReviewed: true).isEmpty)
        #expect(try e.library.areLinked(try e.id("a.jpg"), try e.id("stray.jpg")))
        #expect(try !e.library.areLinked(try e.id("a.jpg"), try e.id("a.jpg")))
    }

    // MARK: Retention and release

    @Test func originalsWaitThirtyDaysThenGoToTheTrash() throws {
        let e = try Env()
        let original = Self.big()
        e.add("a.jpg", original); try e.env.scan()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let batch = try #require(try e.apply(try e.plan(), now: start).batch)
        let held = try #require(try e.library.heldOriginals().first)

        let early = try e.library.releaseExpiredHoldbacks(fileSystem: e.fs, now: start.addingTimeInterval(29 * 86_400))
        #expect(early.released == 0 && e.fs.exists(held.holdbackPath))

        let late = try e.library.releaseExpiredHoldbacks(fileSystem: e.fs, now: start.addingTimeInterval(30 * 86_400))
        #expect(late.released == 1 && !e.fs.exists(held.holdbackPath))
        let op = try #require(try e.library.operations(batch: batch).first)
        #expect(op.releasedAt != nil)
        #expect(try e.bytes(try #require(op.holdbackPath)) == original)       // in the Trash, not deleted
        #expect(try e.library.heldOriginals().isEmpty)

        let undo = try e.library.undoBatch(batch, fileSystem: e.fs)
        #expect(undo.undone == 0 && undo.stoppedBecause?.contains("Trash") == true)
        #expect(try e.library.operationBatches().first?.canUndo == false)
    }

    @Test func retentionFollowsTheRootSetting() throws {
        let e = try Env()
        try e.library.setHoldback(days: 3, forRoot: e.env.rootID)
        e.add("a.jpg", Self.big()); try e.env.scan()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try e.apply(try e.plan(), now: start)
        #expect(try e.library.releaseExpiredHoldbacks(fileSystem: e.fs, now: start.addingTimeInterval(2 * 86_400)).released == 0)
        #expect(try e.library.releaseExpiredHoldbacks(fileSystem: e.fs, now: start.addingTimeInterval(3 * 86_400)).released == 1)
    }

    @Test func earlyReleaseByBatchOrOperation() throws {
        let e = try Env()
        e.add("a.jpg", Self.big()); try e.env.scan()
        let batchA = try #require(try e.apply(try e.plan()).batch)
        e.add("b.jpg", Self.big(quality: 0.9)); try e.env.scan()
        let batchB = try #require(try e.apply(try e.plan()).batch)
        #expect(try e.library.heldOriginals().count == 2)
        #expect(try e.library.releaseOriginals(batch: batchA, fileSystem: e.fs).released == 1)
        let remaining = try e.library.heldOriginals()
        #expect(remaining.map(\.batch) == [batchB])
        #expect(try e.library.releaseOriginals(operationIDs: remaining.map(\.operationID), fileSystem: e.fs).released == 1)
        #expect(try e.library.releaseOriginals(fileSystem: e.fs).released == 0)
    }

    @Test func aRootCanReleaseImmediatelyAndThePreviewSaysSo() throws {
        let e = try Env()
        try e.library.setHoldback(releaseImmediately: true, forRoot: e.env.rootID)
        let original = Self.big()
        e.add("a.jpg", original); try e.env.scan()
        let plan = try e.plan()
        #expect(plan.releasesImmediately)
        let outcome = try e.apply(plan)
        #expect(try outcome.released == 1 && (e.library.heldOriginals()).isEmpty)
        let op = try #require(try e.library.operations(batch: outcome.batch).first)
        #expect(try op.releasedAt != nil && (e.bytes(try #require(op.holdbackPath))) == original)
        #expect(try e.bytes("/Fake/photos/a.jpg").count <= 8_000)
    }

    // MARK: Move and rename

    final class MoveEnv {
        let e: Env
        var library: Library { e.library }
        var fs: FakeFileSystem { e.fs }
        init() throws {
            e = try Env(rule: nil)
            e.add("a.jpg", Data("aaa".utf8)); e.add("sub/b.jpg", Data("bbbb".utf8)); e.add("c.txt", Data("c".utf8))
            try e.env.scan()
        }
        func move(_ name: String, to path: String, root: Int64? = nil) throws -> MovePlan {
            try library.planMoves([MoveRequest(fileID: try e.id(name), toRootID: root, toRelativePath: path)], fileSystem: fs)
        }
    }

    @Test func renamePreviewsThenAppliesKeepingTagsAndIdentity() throws {
        let m = try MoveEnv()
        let id = try m.e.id("a.jpg")
        try m.library.addTag("keep", toFile: id)
        let plan = try m.library.planRename(fileID: id, to: "renamed.jpg", fileSystem: m.fs)
        let step = try #require(plan.steps.first)
        #expect(step.kind == .rename && step.summary == "/Fake/photos/a.jpg -> /Fake/photos/renamed.jpg")
        #expect(m.fs.exists("/Fake/photos/a.jpg"))                           // preview changed nothing

        let outcome = try m.library.applyMoves(plan, fileSystem: m.fs)
        #expect(outcome.movedFileIDs == [id] && outcome.failures.isEmpty)
        #expect(!m.fs.exists("/Fake/photos/a.jpg") && m.fs.exists("/Fake/photos/renamed.jpg"))
        #expect(try m.library.file(id: id)?.relativePath == "renamed.jpg")
        #expect(try m.library.tags(forFile: id).map { $0.name.description } == ["general:keep"])

        let undo = try m.library.undoBatch(try #require(outcome.batch), fileSystem: m.fs)
        #expect(undo.undone == 1 && m.fs.exists("/Fake/photos/a.jpg"))
        #expect(try m.library.file(id: id)?.relativePath == "a.jpg")
    }

    @Test func moveCreatesFoldersAndSearchFollowsThePath() throws {
        let m = try MoveEnv()
        let plan = try m.move("a.jpg", to: "new/deeper/a.jpg")
        #expect(plan.steps.first?.kind == .move)
        let outcome = try m.library.applyMoves(plan, fileSystem: m.fs)
        #expect(outcome.failures.isEmpty && m.fs.exists("/Fake/photos/new/deeper/a.jpg"))
        #expect(try m.library.search("\"deeper\"").map(\.relativePath) == ["new/deeper/a.jpg"])
        _ = try m.library.undoBatch(try #require(outcome.batch), fileSystem: m.fs)
        #expect(try m.fs.exists("/Fake/photos/a.jpg") && (m.library.search("\"deeper\"")).isEmpty)
    }

    @Test func movePreviewRefusesUnsafeOrClashingRequests() throws {
        let m = try MoveEnv()
        #expect(try m.move("a.jpg", to: "sub/b.jpg").skipped.first?.reason.contains("already exists") == true)
        #expect(try m.move("a.jpg", to: "../escape.jpg").skipped.count == 1)
        #expect(try m.move("a.jpg", to: "/etc/passwd").skipped.count == 1)
        #expect(try m.move("a.jpg", to: "a.jpg").skipped.first?.reason == "already named that")
        #expect(try m.move("a.jpg", to: "Photos.photoslibrary/a.jpg").skipped.count == 1)
        try m.library.setExclusions(["private"], forRoot: m.e.env.rootID)
        #expect(try m.move("a.jpg", to: "private/a.jpg").skipped.first?.reason.contains("excluded") == true)
        let clash = try m.library.planMoves([MoveRequest(fileID: try m.e.id("a.jpg"), toRelativePath: "x.jpg"),
                                             MoveRequest(fileID: try m.e.id("c.txt"), toRelativePath: "x.jpg")], fileSystem: m.fs)
        #expect(clash.steps.count == 1 && clash.skipped.count == 1)
    }

    @Test func applyRefusesAMoveWhoseDestinationAppearedAfterThePreview() throws {
        let m = try MoveEnv()
        let plan = try m.move("a.jpg", to: "taken.jpg")
        m.e.add("taken.jpg", Data("someone else".utf8))
        let outcome = try m.library.applyMoves(plan, fileSystem: m.fs)
        #expect(outcome.movedFileIDs.isEmpty && outcome.failures.count == 1)
        #expect(try m.fs.exists("/Fake/photos/a.jpg") && (m.e.bytes("/Fake/photos/taken.jpg")) == Data("someone else".utf8))
    }

    @Test func undoNeverReplacesAFileThatTookTheOldPath() throws {
        let m = try MoveEnv()
        let outcome = try m.library.applyMoves(try m.move("a.jpg", to: "b.jpg"), fileSystem: m.fs)
        m.e.add("a.jpg", Data("new tenant".utf8))
        let undo = try m.library.undoBatch(try #require(outcome.batch), fileSystem: m.fs)
        #expect(undo.undone == 0 && undo.stoppedBecause?.contains("not replacing") == true)
        #expect(try m.e.bytes("/Fake/photos/a.jpg") == Data("new tenant".utf8))
    }

    @Test func bulkMovesAreOneBatchAndUndoTogether() throws {
        let m = try MoveEnv()
        let plan = try m.library.planMoves([MoveRequest(fileID: try m.e.id("a.jpg"), toRelativePath: "1.jpg"),
                                            MoveRequest(fileID: try m.e.id("c.txt"), toRelativePath: "2.txt")], fileSystem: m.fs)
        let outcome = try m.library.applyMoves(plan, fileSystem: m.fs)
        #expect(try outcome.movedFileIDs.count == 2 && (m.library.backups().contains { $0.kind == .preBulk }))
        #expect(try m.library.undoLatestBatch(fileSystem: m.fs)?.undone == 2)
        #expect(m.fs.exists("/Fake/photos/a.jpg") && m.fs.exists("/Fake/photos/c.txt"))
    }

    @Test func moveToAnotherManagedRootOnTheSameVolume() throws {
        let m = try MoveEnv()
        try m.fs.createDirectory(at: "/Fake/archive")
        let other = try m.library.addRoot(at: "/Fake/archive", fileSystem: m.fs, registry: m.e.env.registry)
        #expect(try m.move("a.jpg", to: "a.jpg", root: other.id).skipped.first?.reason == "the destination root is not managed")
        try m.library.setManaged(true, forRoot: other.id)
        let outcome = try m.library.applyMoves(try m.move("a.jpg", to: "2024/a.jpg", root: other.id), fileSystem: m.fs)
        #expect(outcome.failures.isEmpty && m.fs.exists("/Fake/archive/2024/a.jpg"))
        let file = try #require(try m.library.file(id: try m.e.id("2024/a.jpg")))
        #expect(file.rootID == other.id)
    }

    // MARK: Crash recovery

    @Test func aMoveInterruptedAfterTheRenameIsSettledFromTheDisk() throws {
        let m = try MoveEnv()
        let id = try m.e.id("a.jpg")
        let op = try m.library.insertOperation(kind: .rename, batch: "crash", fileID: id, from: "/Fake/photos/a.jpg", to: "/Fake/photos/z.jpg", hash: nil, now: Date())
        try m.fs.move(from: "/Fake/photos/a.jpg", to: "/Fake/photos/z.jpg")    // crash before the row and journal were updated
        #expect(try m.library.recoverInterruptedOperations(fileSystem: m.fs) == 1)
        #expect(try m.library.operations(batch: "crash").first { $0.id == op }?.state == .done)
        #expect(try m.library.file(id: id)?.relativePath == "z.jpg")
    }

    @Test func aMoveInterruptedBeforeTheRenameIsMarkedFailed() throws {
        let m = try MoveEnv()
        _ = try m.library.insertOperation(kind: .rename, batch: "crash", fileID: try m.e.id("a.jpg"), from: "/Fake/photos/a.jpg", to: "/Fake/photos/z.jpg", hash: nil, now: Date())
        try m.library.recoverInterruptedOperations(fileSystem: m.fs)
        #expect(try m.library.operations(batch: "crash").first?.state == .failed && m.fs.exists("/Fake/photos/a.jpg"))
    }

    @Test func aResizeInterruptedMidSwapPutsTheOriginalBack() throws {
        let e = try Env()
        let original = Self.big()
        e.add("a.jpg", original); try e.env.scan()
        let id = try e.id("a.jpg")
        let held = "/Fake/holdback/crash/\(id)-a.jpg"
        let op = try e.library.insertOperation(kind: .resize, batch: "crash", fileID: id, from: "/Fake/photos/a.jpg", to: "/Fake/photos/a.jpg",
                                               hash: Data([1]), holdbackPath: held, now: Date())
        try e.fs.createDirectory(at: "/Fake/holdback/crash")
        try e.fs.move(from: "/Fake/photos/a.jpg", to: held)                    // crash after moving the original aside
        try e.library.recoverInterruptedOperations(fileSystem: e.fs)
        #expect(try e.bytes("/Fake/photos/a.jpg") == original)
        #expect(try e.library.operations(batch: "crash").first { $0.id == op }?.state == .failed)
    }

    @Test func aResizeInterruptedAfterTheSwapIsCompleted() throws {
        let e = try Env()
        let original = Self.big()
        e.add("a.jpg", original); try e.env.scan()
        let id = try e.id("a.jpg")
        let held = "/Fake/holdback/crash/\(id)-a.jpg"
        let op = try e.library.insertOperation(kind: .resize, batch: "crash", fileID: id, from: "/Fake/photos/a.jpg", to: "/Fake/photos/a.jpg",
                                               hash: Data([7]), holdbackPath: held, now: Date())
        try e.fs.createDirectory(at: "/Fake/holdback/crash")
        try e.fs.move(from: "/Fake/photos/a.jpg", to: held)
        e.fs.addFile("/Fake/photos/a.jpg", content: try e.t.encode(original, maxLongEdge: nil, quality: 0.4, stripLocation: false))
        try e.library.recoverInterruptedOperations(fileSystem: e.fs)
        let settled = try #require(try e.library.operations(batch: "crash").first { $0.id == op })
        #expect(settled.state == .done && settled.resultHash != nil)
        #expect(try e.library.originalsOf(fileID: id).count == 1)
        #expect(try e.library.heldOriginals().map(\.operationID) == [op])
    }

    // MARK: Real images

    @Test func realJPEGIsReencodedWithImageIOAndTheOriginalKept() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let root = try tmp.subdirectory("photos")
        let holdbackDir = tmp.path + "/holdback"
        let fs = RealFileSystem()
        let library = try Library.create(at: tmp.path + "/lib", fileSystem: fs)
        defer { try? library.close() }

        let jpeg = try Self.noisyJPEG(width: 1600, height: 1200)
        let path = root + "/big.jpg"
        try jpeg.write(to: URL(fileURLWithPath: path))
        let rootID = try library.addRoot(at: root, fileSystem: fs, registry: LibraryRegistry(preferences: InMemoryPreferences())).id
        try library.setManaged(true, forRoot: rootID)
        let limit = Int64(jpeg.count / 2)
        try library.setStandardizationRule(StandardizationRule(maxBytes: limit, maxLongEdge: 1000, qualityFloor: 0.1), forRoot: rootID)
        try library.scan(rootID: rootID, scope: .full, fileSystem: fs, options: ScanOptions(gracePeriod: 86_400, now: { Date() }))

        let transcoder = ImageIOTranscoder()
        let plan = try library.planStandardization(rootID: rootID, fileSystem: fs, transcoder: transcoder)
        let step = try #require(plan.steps.first)
        #expect((step.newWidth, step.newHeight) == (1000, 750) && step.newBytes <= limit)

        let outcome = try library.applyStandardization(plan, fileSystem: fs, transcoder: transcoder, holdback: HoldbackLocator { _ in holdbackDir })
        #expect(outcome.failures.isEmpty && outcome.resizedFileIDs.count == 1)
        let result = try Data(contentsOf: URL(fileURLWithPath: path))
        let info = try #require(transcoder.inspect(result))
        #expect(info.format == .jpeg && info.longEdge == 1000 && Int64(result.count) <= limit)
        let held = try #require(try library.heldOriginals().first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: held.holdbackPath)) == jpeg)

        try library.scan(rootID: rootID, scope: .full, fileSystem: fs, options: ScanOptions(gracePeriod: 86_400, now: { Date() }))
        let again = try library.planStandardization(rootID: rootID, fileSystem: fs, transcoder: transcoder)
        #expect(again.isEmpty && again.alreadyCompliant == 1)
    }

    static func noisyJPEG(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 42
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 33); pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 41)
            pixels[i + 2] = UInt8(truncatingIfNeeded: seed >> 49); pixels[i + 3] = 255
        }
        let image = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
