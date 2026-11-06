import Foundation
import GRDB
import Testing
@testable import MilesCore

@Suite("Hashing and exact duplicates")
struct DuplicateTests {
    static func bytes(_ text: String, count: Int = 0) -> Data {
        var data = Data(text.utf8)
        if data.count < count { data.append(Data(repeating: 0x2e, count: count - data.count)) }
        return data
    }

    final class Env {
        let env: ScannerTests.Env
        var fs: FakeFileSystem { env.fs }
        var library: Library { env.library }

        init() throws {
            env = try ScannerTests.Env()
            env.fs.volumeNeedsExistingPath = true   // as on the real disk, where a trashed path has no volume to ask
        }
        deinit { env.close() }

        func add(_ name: String, _ content: Data, dataless: Bool = false) {
            fs.addFile("/Fake/photos/\(name)", content: content, dataless: dataless)
        }

        /// Synchronous write: inside an async test the pool's async overload would otherwise be chosen.
        func write(_ body: (Database) throws -> Void) throws { try library.database.write { try body($0) } }

        func id(_ name: String) throws -> Int64 { try #require(try library.files().first { $0.relativePath == name }).id }

        func hashes(_ name: String) throws -> (partial: Data?, full: Data?) {
            let id = try id(name)
            return try library.database.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT partialHash, fullHash FROM file WHERE id = ?", arguments: [id]))
                return (row["partialHash"], row["fullHash"])
            }
        }

        /// Scans, queues hashing and works the queue until nothing is left.
        @discardableResult
        func hashEverything(scan: Bool = true) async throws -> Int {
            if scan { try env.scan() }
            var total = 0
            while true {
                let queued = try library.enqueueHashingJobs()
                let queue = JobQueue(library: library, handlers: library.taggingHandlers(fileSystem: fs), conditions: NoConditions(), sleep: { _ in })
                let summary = await queue.runUntilIdle()
                total += summary.processed
                if queued == 0 && summary.processed == 0 { return total }
            }
        }

        func group(containing name: String) throws -> DuplicateGroup {
            let id = try id(name)
            return try #require(try library.duplicateGroups(includeReviewed: true).first { $0.members.contains { $0.id == id } })
        }
    }

    // MARK: Hashing pipeline

    @Test func aUniqueSizeIsNeverHashed() async throws {
        let e = try Env()
        e.add("a.jpg", Self.bytes("aaaa"))
        e.add("b.jpg", Self.bytes("bbbbbb"))
        try await e.hashEverything()
        #expect(try e.hashes("a.jpg").partial == nil && e.hashes("a.jpg").full == nil)
        #expect(try e.hashes("b.jpg").partial == nil)
        #expect(try e.library.duplicateGroups().isEmpty)
    }

    @Test func sameSizeDifferentContentGetsOnlyAPartialHashWhenTheEndsDiffer() async throws {
        let e = try Env()
        e.add("a.bin", Self.bytes("aaaa"))
        e.add("b.bin", Self.bytes("bbbb"))
        try await e.hashEverything()
        let a = try e.hashes("a.bin"), b = try e.hashes("b.bin")
        #expect(a.partial != nil && b.partial != nil && a.partial != b.partial)
        #expect(a.full == nil && b.full == nil)
        #expect(try e.library.duplicateGroups().isEmpty)
    }

    @Test func aMatchingPartialHashLeadsToAFullHashAndOneGroup() async throws {
        let e = try Env()
        // Same size and same start, middle and end, but different bytes in between: only the full hash tells them apart.
        let big = 400_000
        var one = Data(repeating: 7, count: big), two = one
        two[big / 4] = 9
        e.add("one.bin", one); e.add("two.bin", two)
        e.add("copy1.jpg", Self.bytes("same", count: 100)); e.add("copy2.jpg", Self.bytes("same", count: 100))
        try await e.hashEverything()
        let o = try e.hashes("one.bin"), t = try e.hashes("two.bin")
        #expect(o.partial == t.partial && o.full != nil && t.full != nil && o.full != t.full)
        let groups = try e.library.duplicateGroups()
        #expect(groups.count == 1)
        #expect(Set(groups[0].members.map(\.relativePath)) == ["copy1.jpg", "copy2.jpg"])
        #expect(groups[0].kind == .exact && groups[0].status == .open)
    }

    @Test func placeholdersAreSkippedAndNeverDownloaded() async throws {
        let e = try Env()
        e.add("local.jpg", Self.bytes("x", count: 50))
        e.add("cloud.jpg", Self.bytes("x", count: 50), dataless: true)
        try await e.hashEverything()
        #expect(e.fs.downloads.isEmpty)
        #expect(try e.hashes("cloud.jpg").partial == nil)
        // Nothing to compare the local one with, so it is not read either.
        #expect(try e.hashes("local.jpg").partial == nil)
        #expect(try e.library.duplicateGroups().isEmpty)
    }

    @Test func aPlaceholderThatBecomesLocalIsHashedOnTheNextPass() async throws {
        let e = try Env()
        e.add("a.jpg", Self.bytes("x", count: 50))
        e.add("b.jpg", Self.bytes("x", count: 50), dataless: true)
        try await e.hashEverything()
        e.fs.addFile("/Fake/photos/b.jpg", content: Self.bytes("x", count: 50))   // downloaded by the user
        try await e.hashEverything()
        #expect(try e.library.duplicateGroups().count == 1)
    }

    @Test func aFileEditedAfterBeingIndexedIsNotHashedFromTheStaleRow() async throws {
        let e = try Env()
        e.add("a.jpg", Self.bytes("x", count: 50)); e.add("b.jpg", Self.bytes("x", count: 50))
        try e.env.scan()
        e.fs.overwrite("/Fake/photos/b.jpg", with: Self.bytes("y", count: 70), modified: Date(timeIntervalSince1970: 500))
        try await e.hashEverything()
        #expect(try e.library.duplicateGroups().isEmpty)
        #expect(try e.hashes("b.jpg").partial == nil)
    }

    @Test func hardLinksAreNotEachOthersDuplicates() async throws {
        let e = try Env()
        e.add("a.jpg", Self.bytes("x", count: 50))
        try e.env.scan()
        // Same volume and file ID under a second name: the fake gives a new ID per file, so force the identity in the index.
        e.add("b.jpg", Self.bytes("x", count: 50))
        try e.env.scan()
        try e.write { db in
            try db.execute(sql: "UPDATE file SET fileID = (SELECT fileID FROM file WHERE relativePath = 'a.jpg') WHERE relativePath = 'b.jpg'")
        }
        try await e.hashEverything(scan: false)
        #expect(try e.library.duplicateGroups().isEmpty)
        #expect(try e.hashes("b.jpg").partial == nil)
    }

    @Test func changingAFileDropsItFromItsGroupAndReopensAReviewedOne() async throws {
        let e = try Env()
        for n in ["a", "b", "c"] { e.add("\(n).jpg", Self.bytes("same", count: 60)) }
        try await e.hashEverything()
        var group = try e.group(containing: "a.jpg")
        #expect(group.members.count == 3)
        try e.library.setDuplicateGroupReviewed(group.id, reviewed: true)
        #expect(try e.library.duplicateGroups().isEmpty)

        e.fs.overwrite("/Fake/photos/c.jpg", with: Self.bytes("other", count: 60), modified: Date(timeIntervalSince1970: 9))
        try await e.hashEverything()
        try e.library.refreshDuplicateGroups()
        group = try e.group(containing: "a.jpg")
        #expect(group.members.count == 2)
        #expect(group.status == .open, "a changed membership reopens the group")
    }

    @Test func suggestionsAreOnlySuggestions() async throws {
        let e = try Env()
        e.add("deep/folder/a.jpg", Self.bytes("same", count: 60)); e.add("b.jpg", Self.bytes("same", count: 60))
        try await e.hashEverything()
        let group = try e.group(containing: "b.jpg")
        let suggestion = try #require(e.library.suggestKeep(in: group))
        #expect(suggestion.fileID == (try e.id("b.jpg")) && suggestion.reason == "shortest path")
        try e.library.addTag("keeper", toFile: try e.id("deep/folder/a.jpg"))
        let tagged = try e.group(containing: "b.jpg")
        #expect(e.library.suggestKeep(in: tagged)?.fileID == (try e.id("deep/folder/a.jpg")))
        #expect(try e.fs.exists("/Fake/photos/b.jpg"), "nothing is touched by suggesting")
    }
}

@Suite("Resolving duplicates and the operation journal")
struct ResolutionTests {
    typealias Env = DuplicateTests.Env
    static func same() -> Data { DuplicateTests.bytes("same", count: 80) }

    func trio() async throws -> Env {
        let e = try Env()
        e.add("a.jpg", Self.same()); e.add("sub/b.jpg", Self.same()); e.add("sub/c.jpg", Self.same())
        try await e.hashEverything()
        return e
    }

    @Test func aPreviewChangesNothing() async throws {
        let e = try await trio()
        let group = try e.group(containing: "a.jpg")
        let plan = try e.library.planResolution(groupID: group.id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        #expect(plan.steps.map(\.kind) == [.trash, .trash])
        #expect(plan.steps.map(\.path) == ["/Fake/photos/sub/b.jpg", "/Fake/photos/sub/c.jpg"])
        #expect(plan.bytesFreed == 160)
        #expect(e.fs.exists("/Fake/photos/sub/b.jpg") && e.fs.exists("/Fake/photos/sub/c.jpg"))
        #expect(try e.library.operations().isEmpty)
    }

    @Test func theUserMustChooseWhichCopyToKeep() async throws {
        let e = try await trio()
        let group = try e.group(containing: "a.jpg")
        #expect(throws: OperationError.refused("choose which copy to keep")) {
            try e.library.planResolution(groupID: group.id, action: .trash, keep: nil, fileSystem: e.fs)
        }
        #expect(throws: OperationError.self) {
            try e.library.planResolution(groupID: group.id, action: .trash, keep: 9999, fileSystem: e.fs)
        }
    }

    @Test func trashingJournalsFirstKeepsTheChosenCopyAndSendsOthersToTheTrash() async throws {
        let e = try await trio()
        let group = try e.group(containing: "a.jpg")
        let keep = try e.id("a.jpg")
        let plan = try e.library.planResolution(groupID: group.id, action: .trash, keep: keep, fileSystem: e.fs)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)

        #expect(outcome.failures.isEmpty && outcome.resolvedFileIDs.count == 2)
        #expect(e.fs.exists("/Fake/photos/a.jpg"))
        #expect(!e.fs.exists("/Fake/photos/sub/b.jpg") && !e.fs.exists("/Fake/photos/sub/c.jpg"))
        let ops = try e.library.operations(batch: try #require(outcome.batch))
        #expect(ops.count == 2 && ops.allSatisfy { $0.kind == .trash && $0.state == .done && $0.originalHash != nil })
        #expect(ops.allSatisfy { $0.toPath.hasPrefix(FakeFileSystem.trashDirectory) && e.fs.exists($0.toPath) })
        #expect(try e.library.files().map(\.relativePath) == ["a.jpg"], "trashed files leave the index view")
        #expect(try e.library.duplicateGroups(includeReviewed: true).isEmpty)
        #expect(try e.library.backups().contains { $0.kind == .preBulk }, "a bulk action takes a safety snapshot first")
    }

    @Test func undoPutsEverythingBackAndTagsSurvive() async throws {
        let e = try await trio()
        let b = try e.id("sub/b.jpg")
        try e.library.addTag("vacation", toFile: b)
        let group = try e.group(containing: "a.jpg")
        let plan = try e.library.planResolution(groupID: group.id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)

        let result = try e.library.undoBatch(try #require(outcome.batch), fileSystem: e.fs)
        #expect(result == UndoResult(undone: 2, stoppedBecause: nil))
        #expect(e.fs.exists("/Fake/photos/sub/b.jpg") && e.fs.exists("/Fake/photos/sub/c.jpg"))
        #expect(try e.library.files().count == 3)
        #expect(try e.library.tags(forFile: b).map { $0.name.description } == ["general:vacation"])
        #expect(try e.library.operations().allSatisfy { $0.state == .undone })
        #expect(try e.library.duplicateGroups().count == 1, "the group is back")
        #expect(try e.library.undoLatestBatch(fileSystem: e.fs) == nil, "nothing left to undo")
    }

    @Test func undoNeverReplacesAFileThatAppearedAtTheOldPath() async throws {
        let e = try await trio()
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)
        e.fs.addFile("/Fake/photos/sub/c.jpg", content: Data("new work".utf8))
        let result = try e.library.undoBatch(try #require(outcome.batch), fileSystem: e.fs)
        #expect(result.stoppedBecause?.contains("not replacing") == true)
        #expect(try e.fs.readFile(at: "/Fake/photos/sub/c.jpg") == Data("new work".utf8))
    }

    @Test func undoSaysSoWhenTheTrashWasEmptied() async throws {
        let e = try await trio()
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)
        for op in try e.library.operations() { e.fs.removeItem(op.toPath) }
        let result = try e.library.undoBatch(try #require(outcome.batch), fileSystem: e.fs)
        #expect(result.undone == 0 && result.stoppedBecause?.contains("no longer in the Trash") == true)
    }

    @Test func aFileEditedSinceItWasHashedIsRefusedAndLeftAlone() async throws {
        let e = try await trio()
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        // Same size, same time, different bytes: only re-hashing notices.
        e.fs.overwrite("/Fake/photos/sub/b.jpg", with: DuplicateTests.bytes("diff!", count: 80), modified: Date(timeIntervalSince1970: 0))
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)
        #expect(outcome.failures.map(\.fileID) == [try e.id("sub/b.jpg")])
        #expect(outcome.failures.first?.reason.contains("no longer matches") == true)
        #expect(e.fs.exists("/Fake/photos/sub/b.jpg"))
        #expect(!e.fs.exists("/Fake/photos/sub/c.jpg"), "the other copy was still resolved")
    }

    @Test func aPlaceholderIsSkippedInThePreview() async throws {
        let e = try await trio()
        e.fs.setDataless("/Fake/photos/sub/c.jpg")
        try e.write { try $0.execute(sql: "UPDATE file SET icloudStatus = 'dataless' WHERE relativePath = 'sub/c.jpg'") }
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        #expect(plan.steps.count == 1 && plan.skipped.count == 1)
        #expect(plan.skipped[0].reason.contains("not downloaded"))
        #expect(e.fs.downloads.isEmpty)
    }

    @Test func keepAllJustMarksTheGroupReviewed() async throws {
        let e = try await trio()
        let group = try e.group(containing: "a.jpg")
        let plan = try e.library.planResolution(groupID: group.id, action: .keepAll, keep: nil, fileSystem: e.fs)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)
        #expect(outcome.batch == nil)
        #expect(try e.library.operations().isEmpty)
        #expect(try e.library.duplicateGroups().isEmpty)
        #expect(try e.library.duplicateGroups(includeReviewed: true).first?.status == .reviewed)
        #expect(e.fs.exists("/Fake/photos/sub/b.jpg"))
    }

    // MARK: Tag merge

    @Test func tagMergeIsOfferedAndKeepsEveryCopysTags() async throws {
        let e = try await trio()
        let (a, b) = (try e.id("a.jpg"), try e.id("sub/b.jpg"))
        try e.library.addTag("shared", toFile: a); try e.library.addTag("shared", toFile: b)
        try e.library.addTag("only_b", toFile: b); try e.library.addTag("ns:only_c", toFile: try e.id("sub/c.jpg"))
        let gid = try e.group(containing: "a.jpg").id

        let without = try e.library.planResolution(groupID: gid, action: .trash, keep: a, mergeTags: false, fileSystem: e.fs)
        #expect(without.tagsToMerge.isEmpty)
        let plan = try e.library.planResolution(groupID: gid, action: .trash, keep: a, mergeTags: true, fileSystem: e.fs)
        #expect(plan.tagsToMerge.contains("general:only_b") && plan.tagsToMerge.contains("ns:only_c") && !plan.tagsToMerge.contains("general:shared"))
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)
        #expect(outcome.tagsMerged == 2)
        #expect(Set(try e.library.tags(forFile: a).map { $0.name.description }) == ["general:shared", "general:only_b", "ns:only_c"])
    }

    @Test func aTagTheKeptCopyRejectedIsNotMergedBack() async throws {
        let e = try await trio()
        let (a, b) = (try e.id("a.jpg"), try e.id("sub/b.jpg"))
        try e.library.addTag("junk", toFile: a)
        try e.library.removeTag("junk", fromFile: a)      // a user tag is simply removed
        try e.library.addTag("junk", toFile: b)
        try e.write { db in               // as if a rule tag had been rejected on the kept copy
            try db.execute(sql: "INSERT INTO file_tag (fileID, tagID, source, status, createdAt) SELECT ?, id, 'rule', 'rejected', ? FROM tag WHERE name = 'junk'", arguments: [a, Date()])
        }
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .trash, keep: a, mergeTags: true, fileSystem: e.fs)
        #expect(plan.tagsToMerge.isEmpty)
    }

    // MARK: Clone

    @Test func cloneReplacesEachExtraWithACloneAndKeepsEveryPathValid() async throws {
        let e = try await trio()
        let group = try e.group(containing: "a.jpg")
        let before = try #require(e.fs.exists("/Fake/photos/sub/b.jpg") ? try e.fs.metadata(at: "/Fake/photos/sub/b.jpg").fileID : nil)
        let plan = try e.library.planResolution(groupID: group.id, action: .clone, keep: try e.id("a.jpg"), fileSystem: e.fs)
        #expect(plan.steps.map(\.kind) == [.clone, .clone] && plan.bytesFreed == 160)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)

        #expect(outcome.failures.isEmpty)
        for path in ["/Fake/photos/a.jpg", "/Fake/photos/sub/b.jpg", "/Fake/photos/sub/c.jpg"] {
            #expect(try e.fs.readFile(at: path) == Self.same())
        }
        #expect(try e.fs.metadata(at: "/Fake/photos/sub/b.jpg").fileID != before)
        #expect(try e.library.files().count == 3, "every path is still indexed")
        let ops = try e.library.operations(batch: try #require(outcome.batch))
        #expect(ops.map(\.kind) == [.trash, .clone, .trash, .clone] && ops.allSatisfy { $0.state == .done })
        #expect(try e.library.duplicateGroups().isEmpty && e.library.duplicateGroups(includeReviewed: true).count == 1)
    }

    @Test func undoingACloneRestoresTheOriginalFiles() async throws {
        let e = try await trio()
        // Give the extras their own metadata so a restore is visible.
        let originalID = try e.fs.metadata(at: "/Fake/photos/sub/b.jpg").fileID
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .clone, keep: try e.id("a.jpg"), fileSystem: e.fs)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)
        let result = try e.library.undoBatch(try #require(outcome.batch), fileSystem: e.fs)
        #expect(result.undone == 4 && result.stoppedBecause == nil)
        #expect(try e.fs.metadata(at: "/Fake/photos/sub/b.jpg").fileID == originalID, "the original file itself is back, not a copy")
        #expect(try e.library.files().count == 3)
        #expect(try e.library.operations().allSatisfy { $0.state == .undone })
        #expect(try e.library.duplicateGroups().count == 1)
    }

    @Test func cloneIsNotOfferedAcrossVolumes() async throws {
        let e = try await trio()
        e.fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Ext", filesystemType: "exfat"))
        try e.fs.createDirectory(at: "/Volumes/Ext/pics")
        let other = try e.library.addRoot(at: "/Volumes/Ext/pics", fileSystem: e.fs, registry: e.env.registry)
        e.fs.addFile("/Volumes/Ext/pics/d.jpg", content: Self.same())
        try e.library.scan(rootID: other.id, fileSystem: e.fs)
        try await e.hashEverything()
        let group = try e.group(containing: "a.jpg")
        #expect(group.members.count == 4)
        let plan = try e.library.planResolution(groupID: group.id, action: .clone, keep: try e.id("a.jpg"), fileSystem: e.fs)
        #expect(plan.steps.count == 2)
        #expect(plan.skipped.map(\.path) == ["/Volumes/Ext/pics/d.jpg"] && plan.skipped[0].reason.contains("same APFS volume"))
        // Trash works across volumes.
        let trash = try e.library.planResolution(groupID: group.id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        #expect(trash.steps.count == 3)
    }

    @Test func aCloneThatFailsAfterTheTrashPutsTheOriginalBack() async throws {
        let e = try await trio()
        let kept = try e.id("a.jpg"), extra = try e.id("sub/b.jpg")
        let batch = "test-batch"
        let trash = try e.library.performTrash(fileID: extra, batch: batch, fileSystem: e.fs, now: Date())
        e.fs.addVolume(VolumeInfo(id: "EXT", mountPoint: "/Volumes/Ext", filesystemType: "exfat"))
        try e.fs.createDirectory(at: "/Volumes/Ext/pics")
        #expect(throws: OperationError.self) {
            try e.library.performClone(keptID: kept, replacedID: extra, replacedPath: "/Volumes/Ext/pics/b.jpg", trashOperation: trash,
                                       batch: batch, fileSystem: e.fs, now: Date())
        }
        #expect(try e.fs.readFile(at: "/Fake/photos/sub/b.jpg") == Self.same(), "restored")
        let states = try e.library.operations(batch: batch).map(\.state)
        #expect(states == [.undone, .failed])
    }

    // MARK: Crash recovery

    @Test func aTrashInterruptedBeforeItRanIsMarkedFailedAndTheFileIsUntouched() async throws {
        let e = try await trio()
        let id = try e.id("sub/b.jpg")
        try e.write { db in
            try db.execute(sql: """
                INSERT INTO operation (batch, kind, fileID, fromPath, toPath, state, createdAt)
                VALUES ('x', 'trash', ?, '/Fake/photos/sub/b.jpg', '', 'pending', ?)
                """, arguments: [id, Date()])
        }
        #expect(try e.library.recoverInterruptedOperations(fileSystem: e.fs) == 1)
        let op = try #require(try e.library.operations().first)
        #expect(op.state == .failed && op.error?.contains("not touched") == true)
        #expect(e.fs.exists("/Fake/photos/sub/b.jpg"))
        #expect(try e.library.recoverInterruptedOperations(fileSystem: e.fs) == 0)
    }

    @Test func anUndoInterruptedAfterTheMoveIsSettledAsUndone() async throws {
        let e = try await trio()
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        let outcome = try e.library.applyResolution(plan, fileSystem: e.fs)
        let op = try #require(try e.library.operations(batch: try #require(outcome.batch)).first)
        try e.fs.move(from: op.toPath, to: op.fromPath)    // the move happened, the crash came before the journal update
        try e.write { try $0.execute(sql: "UPDATE operation SET state = 'undoing' WHERE id = ?", arguments: [op.id]) }
        #expect(try e.library.recoverInterruptedOperations(fileSystem: e.fs) == 1)
        #expect(try e.library.operations().first { $0.id == op.id }?.state == .undone)
        #expect(try e.library.files().map(\.relativePath).contains("sub/b.jpg"))
    }

    @Test func aStaleGroupIsRefusedRatherThanGuessed() async throws {
        let e = try await trio()
        let plan = try e.library.planResolution(groupID: try e.group(containing: "a.jpg").id, action: .trash, keep: try e.id("a.jpg"), fileSystem: e.fs)
        try e.write { try $0.execute(sql: "DELETE FROM dup_group") }
        #expect(throws: OperationError.self) { try e.library.applyResolution(plan, fileSystem: e.fs) }
        #expect(e.fs.exists("/Fake/photos/sub/b.jpg"))
    }
}
