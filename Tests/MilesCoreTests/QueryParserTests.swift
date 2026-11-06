import Foundation
import Testing
@testable import MilesCore

@Suite("Query parser")
struct QueryParserTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func parse(_ q: String) throws -> ParsedQuery { try QueryParser.parse(q, calendar: utc) }
    func tag(_ p: String, ns: String? = nil, literal: Bool = false) -> QueryExpr { .tag(namespace: ns, pattern: p, literal: literal) }

    func expectError(_ q: String, contains fragment: String, at offset: Int? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try parse(q)
            Issue.record("expected an error for \(q)", sourceLocation: sourceLocation)
        } catch let e as QueryError {
            #expect(e.message.contains(fragment), "message was: \(e.message)", sourceLocation: sourceLocation)
            if let offset { #expect(e.offset == offset, sourceLocation: sourceLocation) }
        } catch {
            Issue.record("wrong error type \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func emptyQueryMatchesEverything() throws {
        #expect(try parse("").expr == nil)
        #expect(try parse("   ").expr == nil)
    }

    @Test func spaceIsAnd() throws {
        #expect(try parse("cat dog").expr == .and([tag("cat"), tag("dog")]))
        #expect(try parse("cat").expr == tag("cat"))
    }

    @Test func orBindsLooserThanAnd() throws {
        #expect(try parse("a b or c").expr == .or([.and([tag("a"), tag("b")]), tag("c")]))
        #expect(try parse("a OR b").expr == .or([tag("a"), tag("b")]))
    }

    @Test func parenthesesGroup() throws {
        #expect(try parse("(a or b) c").expr == .and([.or([tag("a"), tag("b")]), tag("c")]))
        #expect(try parse("((a))").expr == tag("a"))
    }

    @Test func minusNegates() throws {
        #expect(try parse("a -b").expr == .and([tag("a"), .not(tag("b"))]))
        #expect(try parse("-(a or b)").expr == .not(.or([tag("a"), tag("b")])))
        #expect(try parse("-\"x y\"").expr == .not(.text("x y")))
        #expect(try parse("foo-bar").expr == tag("foo-bar"))
    }

    @Test func namespacesAndWildcards() throws {
        #expect(try parse("character:alice").expr == tag("alice", ns: "character"))
        #expect(try parse("Character:Alice").expr == tag("alice", ns: "character"))
        #expect(try parse("character:*").expr == tag("*", ns: "character"))
        #expect(try parse("foo*").expr == tag("foo*"))
        #expect(try parse("a*b*").expr == tag("a*b*"))
        #expect(try parse("character:\"john doe\"").expr == tag("john_doe", ns: "character"))
    }

    @Test func tildeIsLiteral() throws {
        #expect(try parse("~cat").expr == tag("cat", literal: true))
        #expect(try parse("-~ns:cat").expr == .not(tag("cat", ns: "ns", literal: true)))
    }

    @Test func quotedTextIsNameOrPathText() throws {
        #expect(try parse("\"beach day\"").expr == .text("beach day"))
        #expect(try parse("\"say \\\"hi\\\"\"").expr == .text("say \"hi\""))
        #expect(try parse("\"or\"").expr == .text("or"))
    }

    @Test func filters() throws {
        #expect(try parse("type:image").expr == .filter(.type(.image)))
        #expect(try parse("ext:.JPG").expr == .filter(.ext("jpg")))
        #expect(try parse("root:3").expr == .filter(.root(3)))
        #expect(try parse("path:\"my folder\"").expr == .filter(.path("my folder")))
        #expect(try parse("dup:exact").expr == .filter(.dup(.exact)))
        #expect(try parse("missing:yes").expr == .filter(.missing(true)))
        #expect(try parse("source:ai status:suggested").expr == .and([.filter(.source("ai")), .filter(.status("suggested"))]))
        #expect(try parse("TYPE:video").expr == .filter(.type(.video)))
    }

    @Test func taggedKeyword() throws {
        #expect(try parse("tagged").expr == .filter(.tagged(true)))
        #expect(try parse("-tagged").expr == .not(.filter(.tagged(true))))
        #expect(try parse("tagged:no").expr == .filter(.tagged(false)))
        #expect(try parse("general:tagged").expr == tag("tagged", ns: "general"))
    }

    @Test func sizeComparisonsAndRanges() throws {
        #expect(try parse("size:>5mb").expr == .filter(.size(.init(lower: 5_000_001))))
        #expect(try parse("size:>=5mb").expr == .filter(.size(.init(lower: 5_000_000))))
        #expect(try parse("size:<1kb").expr == .filter(.size(.init(upper: 1000))))
        #expect(try parse("size:<=1kb").expr == .filter(.size(.init(upper: 1001))))
        #expect(try parse("size:1mb..10mb").expr == .filter(.size(.init(lower: 1_000_000, upper: 10_000_001))))
        #expect(try parse("size:..2gb").expr == .filter(.size(.init(upper: 2_000_000_001))))
        #expect(try parse("size:1.5kb..").expr == .filter(.size(.init(lower: 1500))))
        #expect(try parse("size:100").expr == .filter(.size(.init(lower: 100, upper: 101))))
        #expect(try parse("size:=100b").expr == .filter(.size(.init(lower: 100, upper: 101))))
    }

    @Test func dateValuesCoverTheirPeriod() throws {
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: day))! }
        #expect(try parse("date:2024").expr == .filter(.date(.init(lower: d(2024, 1, 1), upper: d(2025, 1, 1)))))
        #expect(try parse("date:2024-02").expr == .filter(.date(.init(lower: d(2024, 2, 1), upper: d(2024, 3, 1)))))
        #expect(try parse("date:>2024-05-01").expr == .filter(.date(.init(lower: d(2024, 5, 2)))))
        #expect(try parse("date:>=2024-05-01").expr == .filter(.date(.init(lower: d(2024, 5, 1)))))
        #expect(try parse("date:<2024-05-01").expr == .filter(.date(.init(upper: d(2024, 5, 1)))))
        #expect(try parse("date:2024-01-01..2024-06-30").expr == .filter(.date(.init(lower: d(2024, 1, 1), upper: d(2024, 7, 1)))))
        #expect(try parse("created:2023").expr == .filter(.created(.init(lower: d(2023, 1, 1), upper: d(2024, 1, 1)))))
    }

    @Test func sortDirective() throws {
        #expect(try parse("sort:size").sort == QuerySort(key: .size, descending: false))
        #expect(try parse("cat sort:-date").sort == QuerySort(key: .date, descending: true))
        #expect(try parse("cat sort:-date").expr == tag("cat"))
        #expect(try parse("sort:random").expr == nil)
        #expect(try parse("sort:name cat").expr == tag("cat"))
    }

    // MARK: Errors

    @Test func malformedQueriesAreErrorsNotTextSearch() {
        expectError("(a", contains: "never closed", at: 0)
        expectError("a)", contains: "no matching", at: 1)
        expectError("()", contains: "empty parentheses")
        expectError("a or", contains: "needs a term after", at: 2)
        expectError("or a", contains: "needs a term before", at: 0)
        expectError("a or or b", contains: "needs a term after")
        expectError("(a or)", contains: "needs a term after")
        expectError("a -", contains: "'-' needs a term", at: 2)
        expectError("\"open", contains: "never closed", at: 0)
        expectError("\"\"", contains: "at least one letter")
        expectError("\"...\"", contains: "at least one letter")
        expectError("~", contains: "needs a tag")
        expectError("a\"b\"", contains: "put a space")
        expectError("ns:\"x\"y", contains: "after the closing quote")
        expectError(":x", contains: "needs both")
        expectError("ns:", contains: "needs both")
        expectError("*:x", contains: "namespace")
        expectError("a:b*:c", contains: "cannot contain")
    }

    @Test func badFilterValues() {
        expectError("type:spreadsheet", contains: "unknown type", at: 0)
        expectError("size:big", contains: "not a size")
        expectError("size:>", contains: "not a size")
        expectError("size:5mb..1mb", contains: "empty")
        expectError("size:..", contains: "at least one side")
        expectError("date:2024-13", contains: "not a real date")
        expectError("date:2024-02-30", contains: "not a real date")
        expectError("date:yesterday", contains: "not a valid value")
        expectError("root:abc", contains: "root id")
        expectError("tagged:maybe", contains: "yes or no")
        expectError("source:robot", contains: "source:")
        expectError("status:x", contains: "status:")
        expectError("dup:far", contains: "dup:")
        expectError("ext:*", contains: "plain extension")
        expectError("type:", contains: "needs a value")
        expectError("~type:image", contains: "'~' applies to tags")
    }

    @Test func sortRestrictions() {
        expectError("sort:weight", contains: "unknown sort")
        expectError("-sort:size", contains: "cannot be negated")
        expectError("(sort:size)", contains: "parentheses")
        expectError("a or b sort:size", contains: "'or'")
        expectError("sort:size sort:date", contains: "only one")
        expectError("sort:-random", contains: "no direction")
    }

    @Test func reservedKeysCannotBeNamespaces() throws {
        for key in QueryFilterKey.allCases {
            #expect(throws: TagError.reservedNamespace(key.rawValue)) { try TagName(namespace: key.rawValue, value: "x") }
        }
        #expect(throws: TagError.reservedNamespace("type")) { try TagName("TYPE:image") }
    }
}
