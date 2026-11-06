import Foundation
import MilesAI
import MilesCore

/// `ai status`, `review`, `ask` and `root ai`: the AI layers and their review queue (ADR 0003, 0010, 0015).
extension CLI {
    static func aiCommand(_ args: inout [String], library: Library) throws {
        let usage = "usage: ai status"
        guard args.first == "status" else { throw Failure(message: usage) }
        let statuses = blocking { await AIPipeline().status() }
        for s in statuses {
            let state: String
            switch s.availability {
            case .available: state = "available"
            case .unavailable(let why): state = "unavailable: \(why)"
            }
            print("layer \(s.layer.rawValue)\t\(s.provider.id)\t\(s.provider.model)\t\(state)")
        }
        for root in try library.roots() {
            let kinds = root.layer4Kinds.map(\.rawValue).sorted().joined(separator: ", ")
            let threshold = root.autoAcceptThreshold.map { String(format: "%.2f", $0) } ?? "off"
            print("root \(root.id): layer 4 \(kinds.isEmpty ? "off" : "on for \(kinds)"), auto-accept \(threshold)")
        }
        print("\(try library.suggestionCount()) suggestions waiting for review")
    }

    static func reviewCommand(_ args: inout [String], library: Library) throws {
        let usage = """
        usage: review list [--root <id>] [--min-confidence <0-1>] [--limit <n>] | review accept <file-id> <tag> | review reject <file-id> <tag>
               review accept-all --min-confidence <0-1> [--root <id>]
        """
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        func confidence(_ value: String?) throws -> Double? {
            guard let value else { return nil }
            guard let d = Double(value), (0...1).contains(d) else { throw Failure(message: "--min-confidence needs a number from 0 to 1") }
            return d
        }
        switch sub {
        case "list":
            let root = try take("--root", from: &args).map { try rootID($0) }
            let minimum = try confidence(take("--min-confidence", from: &args))
            let limit = try take("--limit", from: &args).map { value -> Int in
                guard let n = Int(value), n > 0 else { throw Failure(message: "--limit needs a positive number") }
                return n
            } ?? 50
            let items = try library.reviewQueue(rootID: root, minConfidence: minimum, limit: limit)
            for s in items {
                print("file \(s.fileID)\t\(s.tag)\t\(s.confidence.map { String(format: "%.2f", $0) } ?? "-")\t\(s.provider ?? "-")/\(s.model ?? "-")\t\(s.relativePath)")
            }
            let total = try library.suggestionCount(rootID: root)
            print(items.isEmpty ? "nothing to review" : "showing \(items.count) of \(total)")
        case "accept", "reject":
            guard args.count == 2, let id = Int64(args[0]) else { throw Failure(message: usage) }
            let tag = try TagName(args[1])
            if sub == "accept" { try library.acceptSuggestion(fileID: id, tag: tag) } else { try library.rejectSuggestion(fileID: id, tag: tag) }
            print("\(sub == "accept" ? "accepted" : "rejected") \(tag) on file \(id)\(sub == "reject" ? "; it will not be suggested again for this file" : "")")
        case "accept-all":
            guard let minimum = try confidence(take("--min-confidence", from: &args)) else { throw Failure(message: "accept-all needs --min-confidence") }
            let root = try take("--root", from: &args).map { try rootID($0) }
            print("accepted \(try library.acceptSuggestions(minConfidence: minimum, rootID: root)) suggestions")
        default:
            throw Failure(message: usage)
        }
    }

    /// `ask "<request>"`: translates a request into a query, shows it, and runs it unless `--dry`.
    static func askCommand(_ args: inout [String], library: Library) throws {
        let dry = takeFlag("--dry", from: &args)
        let limit = try take("--limit", from: &args).map { value -> Int in
            guard let n = Int(value), n > 0 else { throw Failure(message: "--limit needs a positive number") }
            return n
        }
        let request = args.joined(separator: " ")
        guard !request.isEmpty else { throw Failure(message: "usage: ask [--dry] [--limit <n>] <what you are looking for>") }
        let result = blocking { () async -> Result<QueryTranslation, Error> in
            do { return .success(try await QueryTranslator().translate(request, in: library)) } catch { return .failure(error) }
        }
        let translation = try result.get()
        print("query: \(translation.query)")
        print("(written by the on-device model \(translation.provider.id); it can be wrong, so check it)")
        if dry { return }
        var rest = [translation.query]
        if let limit { rest = ["--limit", String(limit), translation.query] }
        try queryCommand(&rest, library: library)
    }

    /// `root ai <id> [--auto-accept 0.9|off] [--llm image,text|off]`
    static func rootAICommand(_ args: inout [String], library: Library) throws {
        let usage = "usage: root ai <id> [--auto-accept <0-1>|off] [--llm image,text,...|off]"
        args.removeFirst()   // "ai"
        let autoAccept = take("--auto-accept", from: &args)
        let llm = take("--llm", from: &args)
        let id = try rootID(args.first)
        if autoAccept == nil && llm == nil {
            guard let root = try library.roots().first(where: { $0.id == id }) else { throw Failure(message: "no root \(id)") }
            let kinds = root.layer4Kinds.map(\.rawValue).sorted().joined(separator: ", ")
            print("root \(id): layer 4 \(kinds.isEmpty ? "off" : "on for \(kinds)"), auto-accept \(root.autoAcceptThreshold.map { String(format: "%.2f", $0) } ?? "off")")
            return
        }
        if let autoAccept {
            if autoAccept == "off" { try library.setAutoAcceptThreshold(nil, forRoot: id) } else {
                guard let value = Double(autoAccept) else { throw Failure(message: usage) }
                try library.setAutoAcceptThreshold(value, forRoot: id)
            }
            print("root \(id): auto-accept \(autoAccept)")
        }
        if let llm {
            var kinds: Set<FileKind> = []
            if llm != "off" {
                for name in llm.split(separator: ",") {
                    guard let kind = FileKind(rawValue: String(name)) else { throw Failure(message: "unknown file kind '\(name)' (use \(FileKind.allCases.map(\.rawValue).joined(separator: ", ")))") }
                    kinds.insert(kind)
                }
            }
            try library.setLayer4Kinds(kinds, forRoot: id)
            print("root \(id): layer 4 \(kinds.isEmpty ? "off" : "on for \(kinds.map(\.rawValue).sorted().joined(separator: ", "))")")
        }
    }

    /// Queue versions for the AI layers that have a usable provider right now.
    static func aiVersions() -> [TagLayer: Int] { blocking { await AIPipeline().layerVersions() } }
}
