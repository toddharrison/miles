import Foundation
import GRDB
import Testing
@testable import MilesCore

@Suite("Tags and search")
struct SearchTests {
    final class Env {
        let env: ScannerTests.Env
        var library: Library { env.library }
        var ids: [String: Int64] = [:]

        init(_ files: [(String, Int64)] = []) throws {
            env = try ScannerTests.Env()
            for (path, size) in files { env.fs.addFile("/Fake/photos/" + path, size: size) }
            try env.scan()
            for f in try library.files() { ids[f.relativePath] = f.id }
        }
        deinit { env.close() }

        func scalar<T: DatabaseValueConvertible & StatementColumnConvertible>(_ sql: String) throws -> T? {
            try library.database.read { try T.fetchOne($0, sql: sql) }
        }
        func id(_ path: String) -> Int64 { ids[path]! }
        func tag(_ path: String, _ tags: String...) throws { for t in tags { try library.addTag(t, toFile: id(path)) } }
        func names(_ q: String) throws -> [String] { try library.search(q).map(\.relativePath) }
    }

    static let sample: [(String, Int64)] = [
        ("beach/day1.jpg", 4_000_000), ("beach/day2.png", 9_000_000), ("city/night.jpg", 500),
        ("notes/todo.txt", 20), ("movies/clip.mov", 50_000_000_00), ("my_files/a%b.jpg", 10),
    ]

    // MARK: Migration

    @Test func migrationCreatesTagSchemaAndDefaultNamespace() throws {
        let e = try Env(); 
        for t in ["namespace", "tag", "tag_alias", "tag_implication", "file_tag", "file_fts", "saved_search"] {
            let exists = try e.library.database.read { try $0.tableExists(t) }
            #expect(exists, "\(t)")
        }
        #expect(try e.scalar("SELECT name FROM namespace WHERE isDefault = 1") == "general")
    }

    @Test func upgradingAV1LibraryBackfillsTheSearchIndex() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try tmp.subdirectory("lib")
        let id = UUID()
        do {   // a database as Step 1 left it: only the v1 migration applied, with an indexed file
            let pool = try DatabasePool(path: dir + "/library.sqlite", configuration: LibraryDatabase.configuration())
            try LibraryDatabase.makeMigrator().migrate(pool, upTo: "v1-root-file-meta")
            try pool.write { db in
                try db.execute(sql: "INSERT INTO library_meta (key, value) VALUES ('library_id', ?)", arguments: [id.uuidString])
                try db.execute(sql: "INSERT INTO root (volumeID, relativePath, createdAt) VALUES ('v', 'r', ?)", arguments: [Date()])
                try db.execute(sql: """
                    INSERT INTO file (rootID, relativePath, volumeID, fileID, size, modified, firstSeen, lastSeen)
                    VALUES (1, 'a/b/pic.jpg', 'v', 1, 1, ?, ?, ?)
                    """, arguments: [Date(), Date(), Date()])
            }
            try pool.close()
        }
        let library = try Library.open(at: dir, fileSystem: RealFileSystem())
        defer { try? library.close() }
        #expect(try library.schemaVersion == LibraryDatabase.currentSchemaVersion)
        #expect(try library.search("\"pic\"").map(\.relativePath) == ["a/b/pic.jpg"])
        #expect(try library.search("\"a b\"").map(\.relativePath) == ["a/b/pic.jpg"])
    }

    // MARK: Tag operations

    @Test func addAndRemoveManualTags() throws {
        let e = try Env(Self.sample)
        let f = e.id("city/night.jpg")
        #expect(try e.library.addTag("Night Sky", toFile: f) == (try TagName("night_sky")))
        try e.library.addTag("place:Paris", toFile: f)
        let tags = try e.library.tags(forFile: f)
        #expect(tags.map(\.name.description) == ["general:night_sky", "place:paris"])
        #expect(tags.allSatisfy { $0.source == "user" && $0.status == "accepted" })
        #expect(try e.library.removeTag("night sky", fromFile: f))
        #expect(try e.library.removeTag("night sky", fromFile: f) == false)
        #expect(try e.library.tags(forFile: f).map(\.name.description) == ["place:paris"])
    }

    @Test func addingTwiceIsHarmless() throws {
        let e = try Env(Self.sample)
        let f = e.id("city/night.jpg")
        try e.library.addTag("x", toFile: f); try e.library.addTag("x", toFile: f)
        #expect(try e.library.tags(forFile: f).count == 1)
    }

    @Test func invalidTagsAndFilesAreRefused() throws {
        let e = try Env(Self.sample)
        let f = e.id("city/night.jpg")
        #expect(throws: TagError.self) { try e.library.addTag("", toFile: f) }
        #expect(throws: TagError.self) { try e.library.addTag("a*b", toFile: f) }
        #expect(throws: TagError.self) { try e.library.addTag("-x", toFile: f) }
        #expect(throws: TagError.self) { try e.library.addTag("(x)", toFile: f) }
        #expect(throws: TagError.self) { try e.library.addTag("tagged", toFile: f) }
        #expect(throws: TagError.reservedNamespace("size")) { try e.library.addTag("size:big", toFile: f) }
        #expect(throws: TagError.unknownFile(9999)) { try e.library.addTag("x", toFile: 9999) }
        #expect(throws: TagError.reservedNamespace("type")) { try e.library.createNamespace("Type") }
        try e.library.createNamespace("character")
    }

    @Test func userTagsWinOverRuleAndAI() throws {
        let e = try Env(Self.sample)
        let f = e.id("city/night.jpg")
        // Simulate an AI suggestion and a rejected rule tag, which later steps will write.
        try e.library.database.write { db in
            try db.execute(sql: "INSERT INTO tag (namespaceID, name, createdAt) VALUES (1, 'night', ?), (1, 'dark', ?)", arguments: [Date(), Date()])
            try db.execute(sql: """
                INSERT INTO file_tag (fileID, tagID, source, confidence, status, provider, model, createdAt)
                VALUES (?, 1, 'ai', 0.8, 'suggested', 'p', 'm', ?), (?, 2, 'rule', NULL, 'accepted', NULL, NULL, ?)
                """, arguments: [f, Date(), f, Date()])
        }
        #expect(try e.names("night").isEmpty)                 // suggested does not match a plain search
        #expect(try e.names("source:ai status:suggested") == ["city/night.jpg"])
        try e.library.addTag("night", toFile: f)               // user accepts: becomes a user tag
        let night = try #require(try e.library.tags(forFile: f).first { $0.name.value == "night" })
        #expect(night.source == "user" && night.status == "accepted" && night.provider == nil)
        #expect(try e.names("night") == ["city/night.jpg"])
        // Removing a rule tag keeps a rejection so it is not applied again.
        #expect(try e.library.removeTag("dark", fromFile: f))
        #expect(try e.library.tags(forFile: f).map(\.name.value) == ["night"])
        #expect(try e.library.tags(forFile: f, includeRejected: true).contains { $0.name.value == "dark" && $0.status == "rejected" })
        #expect(try e.names("dark").isEmpty)
        #expect(try e.names("status:rejected") == ["city/night.jpg"])
    }

    @Test func tagsSurviveAMove() throws {
        let e = try Env(Self.sample)
        try e.tag("city/night.jpg", "keeper")
        let before = e.id("city/night.jpg")
        let fs = e.env.fs
        fs.move("/Fake/photos/city/night.jpg", to: "/Fake/photos/city/renamed.jpg")
        try e.env.scan()
        #expect(try e.names("keeper") == ["city/renamed.jpg"])
        #expect(try e.library.search("keeper").first?.id == before)
        #expect(try e.names("\"renamed\"") == ["city/renamed.jpg"])   // FTS follows the new path
        #expect(try e.names("\"night\"").isEmpty)
    }

    @Test func allTagsListsCounts() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "sun"); try e.tag("beach/day2.png", "sun", "sea")
        let all = try e.library.allTags()
        #expect(all.map(\.name.description) == ["general:sea", "general:sun"])
        #expect(all.map(\.fileCount) == [1, 2])
    }

    // MARK: Search

    @Test func tagAndBooleanSearch() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "sun", "sea"); try e.tag("beach/day2.png", "sun"); try e.tag("city/night.jpg", "moon")
        #expect(try e.names("sun") == ["beach/day1.jpg", "beach/day2.png"])
        #expect(try e.names("sun sea") == ["beach/day1.jpg"])
        #expect(try e.names("sun -sea") == ["beach/day2.png"])
        #expect(try e.names("sea or moon") == ["beach/day1.jpg", "city/night.jpg"])
        #expect(try e.names("(sea or moon) -sun") == ["city/night.jpg"])
        #expect(try e.names("nonexistent").isEmpty)
        #expect(try e.names("nosuchns:sun").isEmpty)
    }

    @Test func wildcardsAndLikeCharactersInTagNames() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "character:alice", "snake_case"); try e.tag("beach/day2.png", "character:bob", "snakeXcase")
        #expect(try e.names("character:*") == ["beach/day1.jpg", "beach/day2.png"])
        #expect(try e.names("character:a*") == ["beach/day1.jpg"])
        #expect(try e.names("snake_case") == ["beach/day1.jpg"])        // '_' is not a LIKE wildcard
        #expect(try e.names("snake_*") == ["beach/day1.jpg"])
        #expect(try e.names("*case") == ["beach/day1.jpg", "beach/day2.png"])
        #expect(throws: QueryError.self) { try e.library.search("general:character:a") }
    }

    @Test func aliasesResolveInQueriesAndWhenAdding() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "cat")
        try e.library.setAlias("kitty", for: "cat")
        #expect(try e.names("kitty") == ["beach/day1.jpg"])
        #expect(try e.names("~kitty").isEmpty)                  // literal: no alias resolution
        #expect(try e.names("~cat") == ["beach/day1.jpg"])
        #expect(try e.library.addTag("kitty", toFile: e.id("city/night.jpg")) == (try TagName("cat")))
        #expect(try e.names("cat") == ["beach/day1.jpg", "city/night.jpg"])
        #expect(try e.library.allTags().map(\.name.value) == ["cat"])
        #expect(throws: TagError.aliasConflict(alias: "general:cat")) { try e.library.setAlias("cat", for: "cat") }
        #expect(throws: TagError.unknownTag("general:dog")) { try e.library.setAlias("pup", for: "dog") }
        try e.library.removeAlias("kitty")
        #expect(try e.names("kitty").isEmpty)
    }

    @Test func implicationsExpandTransitively() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "poodle"); try e.tag("beach/day2.png", "cat"); try e.tag("city/night.jpg", "rock")
        try e.library.addImplication("poodle", implies: "dog")
        try e.library.addImplication("dog", implies: "animal")
        try e.library.addImplication("cat", implies: "animal")
        #expect(try e.names("animal") == ["beach/day1.jpg", "beach/day2.png"])
        #expect(try e.names("dog") == ["beach/day1.jpg"])
        #expect(try e.names("~animal").isEmpty)                 // literal: no expansion
        #expect(try e.names("~poodle") == ["beach/day1.jpg"])
        #expect(try e.names("animal -dog") == ["beach/day2.png"])
        try e.library.addImplication("animal", implies: "poodle")   // a cycle must not hang
        #expect(try e.names("poodle").count == 2)
        try e.library.removeImplication("dog", implies: "animal")
        #expect(try e.names("animal") == ["beach/day2.png"])
        #expect(throws: TagError.selfImplication("general:dog")) { try e.library.addImplication("dog", implies: "dog") }
    }

    @Test func implicationsAndAliasesCombine() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "poodle")
        try e.library.addImplication("poodle", implies: "dog")
        try e.library.setAlias("doggo", for: "dog")
        #expect(try e.names("doggo") == ["beach/day1.jpg"])
    }

    @Test func quotedTextMatchesNameOrPath() throws {
        let e = try Env(Self.sample)
        #expect(try e.names("\"beach\"") == ["beach/day1.jpg", "beach/day2.png"])    // path text
        #expect(try e.names("\"night\"") == ["city/night.jpg"])                      // name text
        #expect(try e.names("\"beach day1\"") == ["beach/day1.jpg"])               // a phrase spans the '/' in the path
        #expect(try e.names("\"day\"") == ["beach/day1.jpg", "beach/day2.png"])     // last word is a prefix
        #expect(try e.names("\"ay1\"").isEmpty)                                    // but not a substring
        #expect(try e.names("\"CITY\"") == ["city/night.jpg"])
        #expect(try e.names("\"say \\\"x\\\"\"").isEmpty)                            // quotes cannot break the FTS query
        #expect(try e.names("\"AND OR NOT\"").isEmpty)                               // FTS keywords are plain text
        #expect(try e.names("\"beach\" -\"day2\"") == ["beach/day1.jpg"])
    }

    @Test func tagsAreInTheFTSIndexButNotMatchedByQuotedText() throws {
        let e = try Env(Self.sample)
        try e.tag("city/night.jpg", "moonlit")
        #expect(try e.scalar("SELECT rowid FROM file_fts WHERE file_fts MATCH 'tags:moonlit'") == e.id("city/night.jpg"))
        #expect(try e.names("\"moonlit\"").isEmpty)
        try e.library.removeTag("moonlit", fromFile: e.id("city/night.jpg"))
        #expect(try e.scalar("SELECT COUNT(*) FROM file_fts WHERE file_fts MATCH 'tags:moonlit'") == 0)
    }

    @Test func typeExtSizePathFilters() throws {
        let e = try Env(Self.sample)
        #expect(try e.names("type:image") == ["beach/day1.jpg", "beach/day2.png", "city/night.jpg", "my_files/a%b.jpg"])
        #expect(try e.names("type:video") == ["movies/clip.mov"])
        #expect(try e.names("ext:jpg") == ["beach/day1.jpg", "city/night.jpg", "my_files/a%b.jpg"])
        #expect(try e.names("size:>1mb type:image") == ["beach/day1.jpg", "beach/day2.png"])
        #expect(try e.names("size:1mb..5mb") == ["beach/day1.jpg"])
        #expect(try e.names("size:<=20") == ["my_files/a%b.jpg", "notes/todo.txt"])
        #expect(try e.names("path:beach") == ["beach/day1.jpg", "beach/day2.png"])
        #expect(try e.names("path:my_files") == ["my_files/a%b.jpg"])
        #expect(try e.names("path:y_f") == ["my_files/a%b.jpg"])
        #expect(try e.names("path:a%b") == ["my_files/a%b.jpg"])
        #expect(try e.names("path:x_x").isEmpty)
        #expect(try e.names("root:\(e.env.rootID)").count == Self.sample.count)
        #expect(try e.names("root:999").isEmpty)
    }

    @Test func dateFilter() throws {
        let e = try Env()
        let fs = e.env.fs
        let cal = Calendar.current
        func at(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
        fs.addFile("/Fake/photos/old.jpg", size: 1, modified: at(2023, 12, 31))
        fs.addFile("/Fake/photos/mid.jpg", size: 1, modified: at(2024, 5, 15))
        fs.addFile("/Fake/photos/new.jpg", size: 1, modified: at(2025, 1, 1))
        try e.env.scan()
        #expect(try e.names("date:2024") == ["mid.jpg"])
        #expect(try e.names("date:2024-05") == ["mid.jpg"])
        #expect(try e.names("date:2024-05-15") == ["mid.jpg"])
        #expect(try e.names("date:2024-05-14").isEmpty)
        #expect(try e.names("date:>2024-05-15") == ["new.jpg"])
        #expect(try e.names("date:>=2024-05-15") == ["mid.jpg", "new.jpg"])
        #expect(try e.names("date:<2024") == ["old.jpg"])
        #expect(try e.names("date:2023-12..2024-05") == ["mid.jpg", "old.jpg"])
        #expect(try e.names("-date:2024") == ["new.jpg", "old.jpg"])
    }

    @Test func taggedFilter() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "sun")
        #expect(try e.names("tagged") == ["beach/day1.jpg"])
        #expect(try e.names("tagged:yes") == ["beach/day1.jpg"])
        #expect(try e.library.searchCount("-tagged") == Self.sample.count - 1)
        #expect(try e.library.searchCount("tagged:no") == Self.sample.count - 1)
        #expect(try e.library.searchCount("tagged:no type:video") == 1)
    }

    @Test func sourceAndStatusDescribeTheSameTagRow() throws {
        let e = try Env(Self.sample)
        let f = e.id("city/night.jpg")
        try e.tag("city/night.jpg", "user_tag")
        try e.library.database.write { db in
            try db.execute(sql: "INSERT INTO tag (namespaceID, name, createdAt) VALUES (1, 'ai_tag', ?)", arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO file_tag (fileID, tagID, source, confidence, status, createdAt)
                VALUES (?, (SELECT id FROM tag WHERE name = 'ai_tag'), 'ai', 0.5, 'suggested', ?)
                """, arguments: [f, Date()])
        }
        #expect(try e.names("source:ai status:suggested") == ["city/night.jpg"])
        #expect(try e.names("source:user status:suggested").isEmpty)   // different rows must not combine
        #expect(try e.names("source:ai") == ["city/night.jpg"])
        #expect(try e.names("status:accepted source:user") == ["city/night.jpg"])
        #expect(try e.names("source:rule").isEmpty)
    }

    @Test func missingFilesHiddenUnlessAsked() throws {
        let e = try Env(Self.sample)
        e.env.fs.removeItem("/Fake/photos/notes/todo.txt")
        try e.env.scan()
        #expect(try e.names("type:text").isEmpty)
        #expect(try e.names("type:text missing:yes") == ["notes/todo.txt"])
        #expect(try e.names("missing:yes") == ["notes/todo.txt"])
        #expect(try e.library.searchCount("missing:no") == Self.sample.count - 1)
    }

    @Test func exactDuplicatesByFullHash() throws {
        let e = try Env(Self.sample)
        try e.library.database.write { db in
            try db.execute(sql: "UPDATE file SET fullHash = x'AA' WHERE relativePath IN ('beach/day1.jpg', 'city/night.jpg')")
            try db.execute(sql: "UPDATE file SET fullHash = x'BB' WHERE relativePath = 'notes/todo.txt'")
        }
        #expect(try e.names("dup:exact") == ["beach/day1.jpg", "city/night.jpg"])
        #expect(try e.names("-dup:exact").contains("beach/day2.png"))
    }

    @Test func sorting() throws {
        let e = try Env(Self.sample)
        #expect(try e.names("type:image sort:size") == ["my_files/a%b.jpg", "city/night.jpg", "beach/day1.jpg", "beach/day2.png"])
        #expect(try e.names("type:image sort:-size") == ["beach/day2.png", "beach/day1.jpg", "city/night.jpg", "my_files/a%b.jpg"])
        #expect(try e.names("type:image sort:name").first == "my_files/a%b.jpg")
        #expect(try e.names("sort:-path").first == "notes/todo.txt")
        #expect(Set(try e.names("sort:random")) == Set(Self.sample.map(\.0)))
        #expect(try e.library.search("sort:size", limit: 2).count == 2)
        #expect(try e.library.search("sort:size", limit: 2, offset: 5).count == 1)
    }

    @Test func unsupportedFiltersFailClearly() throws {
        let e = try Env(Self.sample)
        for q in ["dup:near", "created:2024", "sort:created", "cat created:2024"] {
            #expect(throws: QueryError.self, "\(q)") { try e.library.search(q) }
        }
    }

    @Test func malformedQueryNeverFallsBackToTextSearch() throws {
        let e = try Env(Self.sample)
        #expect(throws: QueryError.self) { try e.library.search("(beach") }
        #expect(throws: QueryError.self) { try e.library.search("type:bogus") }
        #expect(throws: QueryError.self) { try e.library.saveSearch(name: "bad", query: "a or") }
    }

    @Test func emptyQueryListsEverythingPresent() throws {
        let e = try Env(Self.sample)
        #expect(try e.library.search("").count == Self.sample.count)
        #expect(try e.library.searchCount("sort:size") == Self.sample.count)
    }

    // MARK: Saved searches

    @Test func savedSearchesStoreTheQueryStringAndFollowLaterChanges() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "poodle"); try e.tag("beach/day2.png", "cat")
        try e.library.saveSearch(name: "Pets", query: "animal type:image")
        #expect(try e.library.runSavedSearch(name: "Pets").isEmpty)
        try e.library.addImplication("poodle", implies: "animal")
        try e.library.addImplication("cat", implies: "animal")
        #expect(try e.library.runSavedSearch(name: "Pets").map(\.relativePath) == ["beach/day1.jpg", "beach/day2.png"])
        #expect(try e.library.savedSearches() == [SavedSearch(id: 1, name: "Pets", query: "animal type:image")])

        #expect(throws: TagError.duplicateSearchName("Pets")) { try e.library.saveSearch(name: "Pets", query: "x") }
        try e.library.saveSearch(name: "Pets", query: "cat", overwrite: true)
        #expect(try e.library.runSavedSearch(name: "Pets").count == 1)
        try e.library.deleteSavedSearch(name: "Pets")
        #expect(throws: TagError.unknownSearch("Pets")) { try e.library.runSavedSearch(name: "Pets") }
        #expect(throws: TagError.unknownSearch("Pets")) { try e.library.deleteSavedSearch(name: "Pets") }
    }

    @Test func removingARootRemovesItsIndexRows() throws {
        let e = try Env(Self.sample)
        try e.tag("beach/day1.jpg", "sun")
        _ = try e.library.removeRoot(id: e.env.rootID)
        #expect(try e.scalar("SELECT COUNT(*) FROM file_fts") == 0)
        #expect(try e.scalar("SELECT COUNT(*) FROM file_tag") == 0)
        #expect(try e.scalar("SELECT COUNT(*) FROM tag") == 1)   // the vocabulary stays
    }
}
