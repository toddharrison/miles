import Foundation
import MilesCore

/// Managed-root commands: opt in, standardization rules, move and rename, holdback. Everything that changes a
/// file previews first and needs `--apply`, and goes through the operation journal (`ops undo`).
extension CLI {
    /// `5mb`, `500kb`, `2gb` (decimal, like the `size:` query filter) or plain bytes.
    static func parseSize(_ text: String) throws -> Int64 {
        let lower = text.lowercased()
        for (suffix, factor) in [("gb", 1_000_000_000.0), ("mb", 1_000_000.0), ("kb", 1_000.0), ("b", 1.0)] where lower.hasSuffix(suffix) {
            if let n = Double(lower.dropLast(suffix.count)), n > 0 { return Int64(n * factor) }
        }
        if let n = Int64(lower), n > 0 { return n }
        throw Failure(message: "'\(text)' is not a size (try 5mb or 500kb)")
    }

    static func describe(_ rule: StandardizationRule) -> String {
        var parts: [String] = []
        if let size = rule.maxBytes { parts.append("max \(megabytes(size))") }
        if let edge = rule.maxLongEdge { parts.append("long edge \(edge)px") }
        parts.append("quality floor \(rule.qualityFloor)")
        if rule.stripLocation { parts.append("strip location") }
        return parts.joined(separator: ", ")
    }

    static func printRoot(_ root: RootRecord) -> String {
        guard root.isManaged else { return "" }
        var text = "  managed"
        if let rule = root.standardization { text += "  standardize: \(describe(rule))" }
        text += "  holdback \(root.releaseImmediately ? "released immediately" : "\(root.holdbackDays) days")"
        return text
    }

    static func rootManagedCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        let sub = args.removeFirst()
        let id = try rootID(args.first)
        args.removeFirst()
        switch sub {
        case "manage":
            guard let value = args.first, ["on", "off"].contains(value) else { throw Failure(message: "usage: root manage <id> on|off") }
            try library.setManaged(value == "on", forRoot: id)
            print("root \(id): \(value == "on" ? "managed. Miles may now move and rename files here, and standardize images if you set a rule, always after a preview" : "unmanaged (read-only)")")
        case "standardize":
            if args.first == "off" { try library.setStandardizationRule(nil, forRoot: id); print("root \(id): no standardization rule"); return }
            if args.first == "show" || args.isEmpty {
                let rule = try library.roots().first { $0.id == id }?.standardization
                print(rule.map(describe) ?? "no rule"); return
            }
            var rule = StandardizationRule()
            rule.maxBytes = try take("--max-size", from: &args).map(parseSize)
            rule.maxLongEdge = try take("--max-edge", from: &args).map { value -> Int in
                guard let n = Int(value), n > 0 else { throw Failure(message: "--max-edge needs a pixel count") }
                return n
            }
            if let q = take("--min-quality", from: &args) {
                guard let value = Double(q) else { throw Failure(message: "--min-quality needs a number from 0.1 to 1") }
                rule.qualityFloor = value
            }
            rule.stripLocation = takeFlag("--strip-location", from: &args)
            try library.setStandardizationRule(rule, forRoot: id)
            print("root \(id) rule: \(describe(rule)). Nothing runs until you preview and apply: standardize \(id)")
        case "holdback":
            let days = try take("--days", from: &args).map { value -> Int in
                guard let n = Int(value), n >= 0 else { throw Failure(message: "--days needs a number of days") }
                return n
            }
            let release = take("--release-immediately", from: &args)
            if let release, !["on", "off"].contains(release) { throw Failure(message: "--release-immediately takes on or off") }
            try library.setHoldback(days: days, releaseImmediately: release.map { $0 == "on" }, forRoot: id)
            print("root \(id) holdback updated")
        default:
            throw Failure(message: "usage: root manage|standardize|holdback <id> ...")
        }
    }

    static func standardizeCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        let apply = takeFlag("--apply", from: &args)
        let id = try rootID(args.first)
        let transcoder = ImageIOTranscoder()
        let plan = try library.planStandardization(rootID: id, fileSystem: fs, transcoder: transcoder)
        print("root \(id): \(describe(plan.rule))")
        for step in plan.steps { print("  \(step.path)\n      \(step.summary)") }
        for skip in plan.skipped { print("  skip \(skip.path): \(skip.reason)") }
        print("\(plan.steps.count) to re-encode, \(plan.alreadyCompliant) already compliant, \(plan.skipped.count) skipped; frees about \(megabytes(plan.bytesFreed))")
        if !plan.isEmpty {
            print(plan.releasesImmediately
                  ? "  this root releases originals immediately: they go to the Trash right after the run and 'ops undo' will not be able to bring them back (the Trash can)"
                  : "  originals wait in the holdback for \(plan.holdbackDays) days, and 'ops undo' restores them until then")
        }
        guard apply else { print("preview only; add --apply to do it"); return }
        let outcome = try library.applyStandardization(plan, fileSystem: fs, transcoder: transcoder,
                                                       holdback: .standard(libraryID: library.id))
        for f in outcome.failures { print("  failed file \(f.fileID): \(f.reason)") }
        if let batch = outcome.batch {
            print("done: \(outcome.resizedFileIDs.count) files, freed \(megabytes(outcome.bytesFreed))"
                  + (outcome.released > 0 ? "; \(outcome.released) originals sent to the Trash" : "; undo with 'ops undo \(batch)'"))
        }
        if !outcome.failures.isEmpty { throw Failure(message: "\(outcome.failures.count) files were not changed") }
    }

    static func moveCommand(_ command: String, _ args: inout [String], library: Library, fs: FileSystem) throws {
        let apply = takeFlag("--apply", from: &args)
        let plan: MovePlan
        if command == "rename" {
            guard args.count == 2 else { throw Failure(message: "usage: rename <file-id> <new-name> [--apply]") }
            plan = try library.planRename(fileID: try fileID(args[0]), to: args[1], fileSystem: fs)
        } else {
            let root = try take("--root", from: &args).map { try rootID($0) }
            guard args.count == 2 else { throw Failure(message: "usage: mv <file-id> <path-relative-to-root> [--root <id>] [--apply]") }
            plan = try library.planMoves([MoveRequest(fileID: try fileID(args[0]), toRootID: root, toRelativePath: args[1])], fileSystem: fs)
        }
        for step in plan.steps { print("  \(step.kind.rawValue) file \(step.fileID): \(step.summary)") }
        for skip in plan.skipped { print("  skip file \(skip.fileID): \(skip.reason)") }
        guard !plan.isEmpty else { throw Failure(message: "nothing to do") }
        guard apply else { print("preview only; add --apply to do it"); return }
        let outcome = try library.applyMoves(plan, fileSystem: fs)
        for f in outcome.failures { print("  failed file \(f.fileID): \(f.reason)") }
        if let batch = outcome.batch { print("done; undo with 'ops undo \(batch)'") }
        if !outcome.failures.isEmpty { throw Failure(message: "\(outcome.failures.count) files were not moved") }
    }

    static func holdbackCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        let usage = "usage: holdback list | holdback release [--batch <id>] [--op <id>] | holdback expire"
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        switch sub {
        case "list":
            let held = try library.heldOriginals()
            for h in held {
                print("op \(h.operationID)\tbatch \(h.batch)\t\(h.holdbackUntil.map { "until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "no expiry")\t\(h.path)")
            }
            if held.isEmpty { print("no originals in the holdback") }
        case "release":
            let batch = take("--batch", from: &args)
            let op = try take("--op", from: &args).map { value -> Int64 in
                guard let n = Int64(value) else { throw Failure(message: "--op needs an operation id (see 'holdback list')") }
                return n
            }
            let result = try library.releaseOriginals(batch: batch, operationIDs: op.map { [$0] }, fileSystem: fs)
            print("sent \(result.released) originals to the Trash; 'ops undo' can no longer restore them (the Trash can)")
            for f in result.failures { print("  \(f)") }
        case "expire":
            let result = try library.releaseExpiredHoldbacks(fileSystem: fs)
            print("sent \(result.released) expired originals to the Trash")
            for f in result.failures { print("  \(f)") }
        default:
            throw Failure(message: usage)
        }
    }
}
