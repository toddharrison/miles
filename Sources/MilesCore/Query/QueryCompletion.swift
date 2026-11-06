import Foundation

/// Autocomplete for the search box (ADR 0009 syntax). Pure text in, text out, so it can be tested.
/// Each suggestion is the whole query with its last word replaced, because that is what the search field takes.
public enum QueryCompletion {
    public static func suggestions(for query: String, tags: [TagInfo], limit: Int = 8) -> [String] {
        // Inside an open quote, or after a space, there is no word to complete.
        guard query.filter({ $0 == "\"" }).count % 2 == 0, let last = query.last, !last.isWhitespace else { return [] }
        let start = query.lastIndex(where: { $0.isWhitespace }).map { query.index(after: $0) } ?? query.startIndex
        let head = String(query[..<start])
        let word = query[start...]
        let marks = word.prefix(while: { "-(~".contains($0) })
        let body = String(word.dropFirst(marks.count)).lowercased()
        guard !body.isEmpty else { return [] }
        let prefix = head + marks

        var found: [String] = []
        if let colon = body.firstIndex(of: ":") {
            let key = String(body[..<colon]), typed = String(body[body.index(after: colon)...])
            if let filterKey = QueryFilterKey(rawValue: key) {
                found = fixedValues(for: filterKey).filter { $0.hasPrefix(typed) }.map { "\(key):\($0)" }
            } else {
                found = rankedTags(tags, matching: typed) { $0.name.namespace == key }.map { $0.name.description }
            }
        } else {
            found = QueryFilterKey.allCases.map(\.rawValue).filter { $0.hasPrefix(body) }.map { $0 + ":" }
            found += rankedTags(tags, matching: body) { _ in true }.map { $0.name.display }
        }
        return found.filter { $0 != body }.prefix(limit).map { prefix + $0 }
    }

    /// Values a filter takes from a fixed list. Others (`size:`, `date:`, `ext:`) are free-form, so nothing is offered.
    private static func fixedValues(for key: QueryFilterKey) -> [String] {
        switch key {
        case .type: FileKind.allCases.map(\.rawValue)
        case .sort: QuerySort.Key.allCases.flatMap { $0 == .random ? [$0.rawValue] : [$0.rawValue, "-" + $0.rawValue] }
        case .source: ["user", "rule", "ai"]
        case .status: ["accepted", "suggested", "rejected"]
        case .dup: ["exact", "near"]
        case .tagged, .missing: ["yes", "no"]
        default: []
        }
    }

    /// Tags whose name starts with, then merely contains, what was typed; the most used first within each.
    private static func rankedTags(_ tags: [TagInfo], matching typed: String, where include: (TagInfo) -> Bool) -> [TagInfo] {
        func rank(_ t: TagInfo) -> Int? {
            let value = t.name.value, display = t.name.display
            if typed.isEmpty || value.hasPrefix(typed) || display.hasPrefix(typed) { return 0 }
            return display.contains(typed) ? 1 : nil
        }
        return tags.filter(include).compactMap { t in rank(t).map { (t, $0) } }
            .sorted { ($0.1, -$0.0.fileCount, $0.0.name.display) < ($1.1, -$1.0.fileCount, $1.0.name.display) }
            .map(\.0)
    }
}
