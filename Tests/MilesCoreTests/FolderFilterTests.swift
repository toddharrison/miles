import Foundation
import Testing
@testable import MilesCore

@Suite("Folder tree and filter")
struct FolderFilterTests {
    static let sample: [(String, Int64)] = [
        ("top.jpg", 10), ("beach/day1.jpg", 10), ("beach/day2.jpg", 10),
        ("beach/raw/r1.jpg", 10), ("city/night.jpg", 10), ("my_files/a%b.jpg", 10),
    ]

    func env() throws -> SearchTests.Env { try SearchTests.Env(Self.sample) }
    func root(_ e: SearchTests.Env) throws -> RootRecord { try e.library.roots()[0] }
    func ref(_ e: SearchTests.Env, _ path: String) throws -> FolderRef { FolderRef(rootID: try root(e).id, path: path) }
    func node(_ tree: [FolderNode], _ path: String) -> FolderNode? {
        func walk(_ n: FolderNode) -> FolderNode? { n.ref.path == path ? n : n.children.lazy.compactMap(walk).first }
        return tree.lazy.compactMap(walk).first
    }

    // MARK: Tree

    @Test func treeHasRootsFoldersAndIntermediateFoldersWithDirectCounts() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        #expect(tree.count == 1)
        #expect(tree[0].ref.path == "")
        #expect(tree[0].fileCount == 1)
        #expect(tree[0].children.map(\.name) == ["beach", "city", "my_files"])
        #expect(node(tree, "beach")?.fileCount == 2)
        #expect(node(tree, "beach/raw")?.fileCount == 1)
        #expect(node(tree, "beach/raw")?.name == "raw")
    }

    @Test func aFolderOnlyHoldingSubfoldersStillShows() throws {
        let e = try SearchTests.Env([("a/b/c/x.jpg", 10)])
        let tree = try e.library.folderTree()
        #expect(node(tree, "a")?.fileCount == 0)
        #expect(node(tree, "a/b/c")?.fileCount == 1)
    }

    @Test func missingFilesAreNotCounted() throws {
        let e = try env()
        try e.library.database.write { try $0.execute(sql: "UPDATE file SET missingSince = ? WHERE relativePath = 'city/night.jpg'", arguments: [Date()]) }
        #expect(node(try e.library.folderTree(), "city") == nil)
    }

    // MARK: Checkbox state

    @Test func everythingIsCheckedByDefault() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        let filter = try e.library.folderFilter()
        #expect(filter.unchecked.isEmpty)
        #expect(tree.allSatisfy { filter.state(of: $0) == .on })
        #expect(filter.summary(of: tree) == FolderFilter.Summary(shown: 5, total: 5))
    }

    @Test func uncheckingAParentUnchecksItsWholeSubtreeAndShowsMixedAbove() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        var filter = FolderFilter()
        filter.toggle(node(tree, "beach")!)
        #expect(filter.state(of: node(tree, "beach")!) == .off)
        #expect(filter.state(of: node(tree, "beach/raw")!) == .off)
        #expect(filter.state(of: node(tree, "city")!) == .on)
        #expect(filter.state(of: tree[0]) == .mixed)
        #expect(filter.summary(of: tree) == FolderFilter.Summary(shown: 3, total: 5))
    }

    @Test func aMixedParentChecksEverythingBelowOnToggle() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        var filter = FolderFilter()
        filter.toggle(node(tree, "beach/raw")!)
        #expect(filter.state(of: node(tree, "beach")!) == .mixed)
        filter.toggle(node(tree, "beach")!)
        #expect(filter.state(of: node(tree, "beach")!) == .on)
        #expect(filter.unchecked.isEmpty)
    }

    @Test func aChildCanBeCheckedWhileItsParentStaysOff() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        var filter = FolderFilter()
        filter.toggle(node(tree, "beach")!)
        filter.toggle(node(tree, "beach/raw")!)
        #expect(filter.state(of: node(tree, "beach/raw")!) == .on)
        #expect(filter.state(of: node(tree, "beach")!) == .mixed)
        #expect(filter.includes(rootID: try root(e).id, relativePath: "beach/raw/r1.jpg"))
        #expect(!filter.includes(rootID: try root(e).id, relativePath: "beach/day1.jpg"))
    }

    // MARK: Applying it

    @Test func theGridAndSearchHideUncheckedFoldersButNothingElse() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        var filter = FolderFilter()
        filter.toggle(node(tree, "beach")!)
        let all = try e.library.files(folders: filter).map(\.relativePath)
        #expect(all == ["city/night.jpg", "my_files/a%b.jpg", "top.jpg"])
        #expect(try e.library.search("type:image", folders: filter).map(\.relativePath).sorted() == all)
        #expect(try e.library.search("\"day1\"", folders: filter).isEmpty)
        #expect(try e.library.search("\"day1\"").count == 1, "without the filter it is still found")
        #expect(try e.library.searchCount("type:image", folders: filter) == 3)
    }

    @Test func uncheckingARootFolderLeavesItsSubfoldersAlone() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        var filter = FolderFilter()
        filter.set(tree[0].ref, checked: false)
        let shown = try e.library.files(folders: filter).map(\.relativePath)
        #expect(!shown.contains("top.jpg"))
        #expect(shown.count == 5)
    }

    @Test func namesWithWildcardCharactersMatchExactly() throws {
        let e = try env()
        let tree = try e.library.folderTree()
        var filter = FolderFilter()
        filter.toggle(node(tree, "my_files")!)
        #expect(try e.library.files(folders: filter).count == 5)
        #expect(try e.library.files(folders: filter).allSatisfy { $0.relativePath != "my_files/a%b.jpg" })
    }

    @Test func filteringIsViewOnly() throws {
        let e = try env()
        let before = try e.library.fileCount()
        var filter = FolderFilter()
        filter.set(try ref(e, ""), checked: false)
        try e.library.setFolderFilter(filter)
        #expect(try e.library.fileCount() == before)
        #expect(try e.library.folderTree().count == 1)
    }

    // MARK: Persistence

    @Test func theFilterIsRememberedPerLibrary() throws {
        let e = try env()
        var filter = FolderFilter()
        filter.set(try ref(e, "beach"), checked: false)
        filter.set(try ref(e, "city"), checked: false)
        try e.library.setFolderFilter(filter)
        #expect(try e.library.folderFilter() == filter)
        try e.library.setFolderFilter(FolderFilter())
        #expect(try e.library.folderFilter().unchecked.isEmpty)
    }

    @Test func anUnreadableSavedFilterMeansEverythingShown() throws {
        let e = try env()
        try e.library.database.write { try $0.execute(sql: "INSERT OR REPLACE INTO library_meta (key, value) VALUES ('folderFilter', 'not json')") }
        #expect(try e.library.folderFilter().unchecked.isEmpty)
    }
}
