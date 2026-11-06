import Foundation

/// Parser for the query syntax in ADR 0009.
///
///     query  := or
///     or     := and ('or' and)*
///     and    := unary+                      (a space is AND)
///     unary  := '-' unary | '(' or ')' | term
///     term   := "quoted text" | key:value | key:"quoted value" | '~'? tag
///
/// `sort:` is a directive, not a condition: it is allowed only at the top level, not negated,
/// grouped or inside an `or`.
public enum QueryParser {
    public static func parse(_ text: String, calendar: Calendar = .current) throws -> ParsedQuery {
        var parser = Parser(tokens: try lex(text), calendar: calendar)
        return try parser.parseQuery()
    }

    // MARK: Lexer

    struct Token {
        enum Kind {
            case lparen, rparen, minus, or
            case text(String)
            case term(literal: Bool, key: String?, value: String)
        }
        var kind: Kind
        var offset: Int
    }

    static func lex(_ source: String) throws -> [Token] {
        let chars = Array(source)
        var tokens: [Token] = []
        var i = 0

        func isBreak(_ c: Character) -> Bool { c.isWhitespace || c == "(" || c == ")" || c == "\"" }

        /// Reads a quoted string starting at the opening quote. Supports \" and \\ escapes.
        func readQuoted(from start: Int) throws -> (String, next: Int) {
            var out = ""
            var j = start + 1
            while j < chars.count {
                let c = chars[j]
                if c == "\\", j + 1 < chars.count, chars[j + 1] == "\"" || chars[j + 1] == "\\" {
                    out.append(chars[j + 1]); j += 2; continue
                }
                if c == "\"" { return (out, j + 1) }
                out.append(c); j += 1
            }
            throw QueryError("this quote is never closed", offset: start)
        }

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            switch c {
            case "(": tokens.append(Token(kind: .lparen, offset: i)); i += 1
            case ")": tokens.append(Token(kind: .rparen, offset: i)); i += 1
            case "\"":
                let (text, next) = try readQuoted(from: i)
                guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                    throw QueryError("quoted text needs at least one letter or digit", offset: i)
                }
                tokens.append(Token(kind: .text(text), offset: i))
                i = next
            case "-" where i + 1 < chars.count && !chars[i + 1].isWhitespace:
                tokens.append(Token(kind: .minus, offset: i)); i += 1
            case "-":
                throw QueryError("'-' needs a term right after it", offset: i)
            default:
                let start = i
                var raw = ""
                var quotedValue: String?
                while i < chars.count, !isBreak(chars[i]) { raw.append(chars[i]); i += 1 }
                if i < chars.count, chars[i] == "\"" {
                    guard raw.hasSuffix(":"), raw.count > 1 else {
                        throw QueryError("put a space before a quoted string, or write key:\"value\"", offset: i)
                    }
                    let (text, next) = try readQuoted(from: i)
                    quotedValue = text
                    i = next
                    if i < chars.count, !isBreak(chars[i]) || chars[i] == "\"" {
                        throw QueryError("unexpected text after the closing quote", offset: i)
                    }
                }
                var literal = false
                if raw.hasPrefix("~") { literal = true; raw.removeFirst() }
                if raw.isEmpty { throw QueryError("'~' needs a tag right after it", offset: start) }

                if quotedValue == nil, !raw.contains(":"), raw.lowercased() == "or", !literal {
                    tokens.append(Token(kind: .or, offset: start))
                    continue
                }
                var key: String?
                var value = raw
                if let quoted = quotedValue {
                    key = String(raw.dropLast())
                    value = quoted
                } else if let colon = raw.firstIndex(of: ":") {
                    key = String(raw[..<colon])
                    value = String(raw[raw.index(after: colon)...])
                }
                tokens.append(Token(kind: .term(literal: literal, key: key, value: value), offset: start))
            }
        }
        return tokens
    }

    // MARK: Parser

    struct Parser {
        let tokens: [Token]
        let calendar: Calendar
        var index = 0
        var depth = 0
        var sort: QuerySort?
        var sortOffset: Int?

        init(tokens: [Token], calendar: Calendar) {
            self.tokens = tokens
            self.calendar = calendar
        }

        var peek: Token? { index < tokens.count ? tokens[index] : nil }
        var endOffset: Int { (tokens.last?.offset ?? 0) + 1 }

        mutating func parseQuery() throws -> ParsedQuery {
            if tokens.isEmpty { return ParsedQuery(expr: nil, sort: nil) }
            let expr = try parseOr()
            if let token = peek {
                if case .rparen = token.kind { throw QueryError("this ')' has no matching '('", offset: token.offset) }
                throw QueryError("unexpected input", offset: token.offset)
            }
            return ParsedQuery(expr: expr, sort: sort)
        }

        /// Returns nil when the branch holds only a `sort:` directive.
        mutating func parseOr() throws -> QueryExpr? {
            var branches: [QueryExpr?] = []
            var sawSort = false
            var orOffsets: [Int] = []
            while true {
                let sortsBefore = sort != nil
                let branch = try parseAnd(afterOr: orOffsets.last)
                if !sortsBefore && sort != nil { sawSort = true }
                branches.append(branch)
                guard let token = peek, case .or = token.kind else { break }
                orOffsets.append(token.offset)
                index += 1
            }
            if branches.count > 1, sawSort {
                throw QueryError("sort: cannot be combined with 'or'; put it at the end of the whole query", offset: sortOffset)
            }
            if branches.count == 1 { return branches[0] }
            return .or(branches.compactMap { $0 })
        }

        mutating func parseAnd(afterOr: Int?) throws -> QueryExpr? {
            var items: [QueryExpr] = []
            let sortBefore = sort != nil
            loop: while let token = peek {
                switch token.kind {
                case .rparen, .or: break loop
                default: if let item = try parseUnary(negated: false) { items.append(item) }
                }
            }
            if !items.isEmpty { return items.count == 1 ? items[0] : .and(items) }
            if sort != nil && !sortBefore { return nil }   // only a sort: directive
            if let afterOr { throw QueryError("'or' needs a term after it", offset: afterOr) }
            if let token = peek, case .or = token.kind { throw QueryError("'or' needs a term before it", offset: token.offset) }
            throw QueryError("expected a term here", offset: peek?.offset ?? endOffset)
        }

        mutating func parseUnary(negated: Bool) throws -> QueryExpr? {
            guard let token = peek else { throw QueryError("expected a term here", offset: endOffset) }
            index += 1
            switch token.kind {
            case .minus:
                guard let inner = try parseUnary(negated: true) else { return nil }
                return .not(inner)
            case .lparen:
                depth += 1
                defer { depth -= 1 }
                if let next = peek, case .rparen = next.kind { throw QueryError("empty parentheses", offset: token.offset) }
                guard let inner = try parseOr() else { throw QueryError("expected a term here", offset: token.offset) }
                guard let close = peek, case .rparen = close.kind else {
                    throw QueryError("this '(' is never closed", offset: token.offset)
                }
                index += 1
                return inner
            case .rparen, .or:
                throw QueryError("expected a term here", offset: token.offset)
            case .text(let text):
                return .text(text)
            case .term(let literal, let key, let value):
                return try term(literal: literal, key: key, value: value, offset: token.offset, negated: negated)
            }
        }

        mutating func term(literal: Bool, key: String?, value: String, offset: Int, negated: Bool) throws -> QueryExpr? {
            // A bare `tagged` is the filter (so `-tagged` finds untagged files, ADR 0009).
            if key == nil, value.lowercased() == "tagged", !literal { return .filter(.tagged(true)) }

            if let key, let filterKey = QueryFilterKey(rawValue: key.lowercased()) {
                if literal { throw QueryError("'~' applies to tags, not to the \(filterKey.rawValue): filter", offset: offset) }
                if value.isEmpty { throw QueryError("\(filterKey.rawValue): needs a value", offset: offset) }
                if filterKey == .sort { try setSort(value, offset: offset, negated: negated); return nil }
                return .filter(try QueryFilters.parse(filterKey, value, calendar: calendar, offset: offset))
            }

            if let key, key.isEmpty || value.isEmpty {
                throw QueryError("'\(key.isEmpty ? ":" : key + ":")' needs both a namespace and a name", offset: offset)
            }
            if let key, key.contains("*") { throw QueryError("wildcards are allowed in the tag name, not the namespace", offset: offset) }
            do {
                let ns = try key.map { try TagName.normalize($0, what: "namespace") }
                let pattern = try TagName.normalizePattern(value)
                return .tag(namespace: ns, pattern: pattern, literal: literal)
            } catch let error as TagError {
                throw QueryError(error.localizedDescription, offset: offset)
            }
        }

        mutating func setSort(_ value: String, offset: Int, negated: Bool) throws {
            if negated { throw QueryError("sort: cannot be negated; use sort:-key for descending", offset: offset) }
            if depth > 0 { throw QueryError("sort: cannot go inside parentheses; put it at the end of the whole query", offset: offset) }
            if sort != nil { throw QueryError("only one sort: is allowed", offset: offset) }
            let descending = value.hasPrefix("-")
            let name = descending ? String(value.dropFirst()) : value
            guard let key = QuerySort.Key(rawValue: name.lowercased()) else {
                throw QueryError("unknown sort '\(value)' (use \(QuerySort.Key.allCases.map(\.rawValue).joined(separator: ", ")), optionally with a leading -)", offset: offset)
            }
            if key == .random && descending { throw QueryError("sort:random has no direction", offset: offset) }
            sort = QuerySort(key: key, descending: descending)
            sortOffset = offset
        }
    }
}

extension TagName {
    /// Like `normalize`, but `*` is allowed (a wildcard in a query).
    static func normalizePattern(_ text: String) throws -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_").lowercased()
        if collapsed.isEmpty { throw TagError.invalidName(text, reason: "the name is empty") }
        if let bad = collapsed.first(where: { forbidden.contains($0) && $0 != "*" }) {
            throw TagError.invalidName(text, reason: "the name cannot contain '\(bad)'")
        }
        return collapsed
    }
}
