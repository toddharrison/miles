import Foundation

/// Value parsing for `key:value` filters (ADR 0009).
enum QueryFilters {
    static func parse(_ key: QueryFilterKey, _ value: String, calendar: Calendar, offset: Int) throws -> QueryFilter {
        func fail(_ message: String) -> QueryError { QueryError(message, offset: offset) }
        let lower = value.lowercased()
        switch key {
        case .type:
            guard let kind = FileKind(rawValue: lower) else {
                throw fail("unknown type '\(value)' (use \(FileKind.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            return .type(kind)
        case .ext:
            let ext = lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
            guard !ext.isEmpty, !ext.contains("*"), !ext.contains("/") else { throw fail("ext: needs a plain extension such as ext:jpg") }
            return .ext(ext)
        case .size:
            return .size(try range(value, offset: offset, parse: { s in try size(s, offset: offset).map { ($0, $0 + 1) } }))
        case .date:
            return .date(try dateRange(value, calendar: calendar, offset: offset))
        case .created:
            return .created(try dateRange(value, calendar: calendar, offset: offset))
        case .root:
            guard let id = Int64(value) else { throw fail("root: needs a root id (see 'root list')") }
            return .root(id)
        case .path:
            return .path(lower)
        case .dup:
            guard let kind = QueryFilter.Duplicate(rawValue: lower) else { throw fail("dup: takes exact or near") }
            return .dup(kind)
        case .tagged:
            return .tagged(try yesNo(lower, key: "tagged", offset: offset))
        case .missing:
            return .missing(try yesNo(lower, key: "missing", offset: offset))
        case .source:
            guard ["user", "rule", "ai"].contains(lower) else { throw fail("source: takes user, rule or ai") }
            return .source(lower)
        case .status:
            guard ["accepted", "suggested", "rejected"].contains(lower) else { throw fail("status: takes accepted, suggested or rejected") }
            return .status(lower)
        case .sort:
            preconditionFailure("sort is handled by the parser")
        }
    }

    static func yesNo(_ value: String, key: String, offset: Int) throws -> Bool {
        switch value {
        case "yes": return true
        case "no": return false
        default: throw QueryError("\(key): takes yes or no", offset: offset)
        }
    }

    // MARK: Comparisons and ranges

    /// Parses `>x`, `>=x`, `<x`, `<=x`, `=x`, a bare `x`, or `a..b` (either side optional) into a half-open range.
    /// `parse` reads one value to the half-open span it covers.
    static func range<T: Comparable & Sendable>(
        _ text: String, offset: Int,
        parse: (String) throws -> (start: T, end: T)?
    ) throws -> HalfOpenRange<T> {
        func value(_ s: String) throws -> (start: T, end: T) {
            guard let v = try parse(s) else { throw QueryError("'\(s)' is not a valid value here", offset: offset) }
            return v
        }
        if let dots = text.range(of: "..") {
            let a = String(text[..<dots.lowerBound]), b = String(text[dots.upperBound...])
            if a.isEmpty && b.isEmpty { throw QueryError("'..' needs a value on at least one side", offset: offset) }
            let lower = a.isEmpty ? nil : try value(a).start
            let upper = b.isEmpty ? nil : try value(b).end
            if let lower, let upper, lower >= upper { throw QueryError("the range '\(text)' is empty (start is after end)", offset: offset) }
            return HalfOpenRange(lower: lower, upper: upper)
        }
        for (op, kind) in [(">=", 0), ("<=", 1), (">", 2), ("<", 3), ("=", 4)] where text.hasPrefix(op) {
            let v = try value(String(text.dropFirst(op.count)))
            switch kind {
            case 0: return HalfOpenRange(lower: v.start)
            case 1: return HalfOpenRange(upper: v.end)
            case 2: return HalfOpenRange(lower: v.end)
            case 3: return HalfOpenRange(upper: v.start)
            default: return HalfOpenRange(lower: v.start, upper: v.end)
            }
        }
        let v = try value(text)
        return HalfOpenRange(lower: v.start, upper: v.end)
    }

    /// Decimal units, as Finder shows them: 1 kb is 1000 bytes.
    static func size(_ text: String, offset: Int) throws -> Int64? {
        let s = text.lowercased()
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("b", 1)]
        var number = s
        var factor = 1.0
        for (suffix, f) in units where s.hasSuffix(suffix) {
            number = String(s.dropLast(suffix.count)); factor = f; break
        }
        guard let n = Double(number), n >= 0, n.isFinite, n * factor < 9e18 else {
            throw QueryError("'\(text)' is not a size (try 500kb, 5mb, 1.5gb)", offset: offset)
        }
        return Int64((n * factor).rounded())
    }

    /// `2024`, `2024-05` or `2024-05-31`. A value covers its whole year, month or day.
    static func dateRange(_ text: String, calendar: Calendar, offset: Int) throws -> HalfOpenRange<Date> {
        try range(text, offset: offset, parse: { s -> (start: Date, end: Date)? in
            let parts = s.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard (1 ... 3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
            let n = parts.map { $0! }
            var comps = DateComponents(year: n[0], month: n.count > 1 ? n[1] : 1, day: n.count > 2 ? n[2] : 1)
            guard let start = calendar.date(from: comps),
                  calendar.dateComponents([.year, .month, .day], from: start) == DateComponents(year: comps.year, month: comps.month, day: comps.day)
            else { throw QueryError("'\(s)' is not a real date (use 2024, 2024-05 or 2024-05-31)", offset: offset) }
            comps = DateComponents()
            switch n.count {
            case 1: comps.year = 1
            case 2: comps.month = 1
            default: comps.day = 1
            }
            guard let end = calendar.date(byAdding: comps, to: start) else { return nil }
            return (start, end)
        })
    }
}
