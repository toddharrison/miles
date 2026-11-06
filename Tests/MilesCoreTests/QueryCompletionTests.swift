import Foundation
import Testing
@testable import MilesCore

@Suite("Query completion")
struct QueryCompletionTests {
    func tag(_ text: String, _ count: Int) -> TagInfo { TagInfo(id: 0, name: try! TagName(text), fileCount: count) }
    var tags: [TagInfo] { [tag("cat", 5), tag("catfish", 2), tag("animal:cat", 9), tag("dog", 7), tag("year:2024", 3)] }
    func complete(_ q: String) -> [String] { QueryCompletion.suggestions(for: q, tags: tags) }

    @Test func filterKeysCompleteFromTheirPrefix() {
        #expect(complete("ex") == ["ext:"])
        #expect(complete("cat si").contains("cat size:"))
        #expect(!complete("ty").contains("ext:"))
    }

    @Test func tagsCompleteMostUsedFirstAndKeepTheRestOfTheQuery() {
        #expect(complete("ca") == ["animal:cat", "cat", "catfish"])
        #expect(complete("dog ca").first == "dog animal:cat")
    }

    @Test func prefixMatchesComeBeforeContainsMatches() {
        #expect(complete("fish") == ["catfish"])
        #expect(complete("at").first == "animal:cat")
    }

    @Test func fixedValuesCompleteAfterAColon() {
        #expect(complete("type:v") == ["type:video"])
        #expect(complete("type:") .contains("type:image"))
        #expect(complete("tagged:n") == ["tagged:no"])
        #expect(complete("sort:-d") == ["sort:-date"])
        #expect(complete("size:>5mb") == [])
    }

    @Test func namespaceValuesCompleteFromThatNamespace() {
        #expect(complete("year:20") == ["year:2024"])
        #expect(complete("animal:c") == ["animal:cat"])
    }

    @Test func leadingMarksAreKept() {
        #expect(complete("-ca").first == "-animal:cat")
        #expect(complete("(ca").first == "(animal:cat")
        #expect(complete("~ca").first == "~animal:cat")
        #expect(complete("-ty") == ["-type:"])
    }

    @Test func nothingInsideQuotesOrAfterASpace() {
        #expect(complete("\"beach ca") == [])
        #expect(complete("cat ") == [])
        #expect(complete("") == [])
    }

    @Test func anExactMatchIsNotOfferedBack() {
        #expect(!complete("dog").contains("dog"))
        #expect(!complete("type:image").contains("type:image"))
    }

    @Test func limitIsRespected() {
        #expect(QueryCompletion.suggestions(for: "ca", tags: tags, limit: 2).count == 2)
    }
}
