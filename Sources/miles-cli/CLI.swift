import Foundation
import MilesAI
import MilesCore

/// `miles-cli`: scan, query and resolve duplicates without the UI. `dup resolve`, `standardize`, `mv`, `rename` (each only with `--apply`), `holdback release|expire` and
/// `ops undo` change a user's files, all through the operation journal.
enum CLI {
    static let usage = """
    usage: miles-cli [--library <dir>] [--take-over-lock] <command>

    commands:
      version
      library create <dir> [--name <name>]    create and register a library
      library list                            registered libraries
      library status                          can each library open now (drive connected, lock, schema version)
      library forget <name>                   unregister a library (files and its folder are untouched)
      root add <path>                         index a folder in place (unmanaged)
      root remove <id>                        stop indexing; forgets its records, touches no files
      root exclude <id> <pattern>...          replace the root's exclusions (a name, or a path/relative/to/root)
      root fetch-once <id> on|off             per-root: download evicted images once to build thumbnails (off by default)
      root manage <id> on|off                 opt a root in to (or out of) managed mode: move, rename, standardize. Off by default
      root standardize <id> [--max-size 5mb] [--max-edge 3000] [--min-quality 0.6] [--strip-location] | off | show
                                              the root's image rule (JPEG and HEIC only). Nothing runs until 'standardize'
      root holdback <id> [--days 30] [--release-immediately on|off]   how long originals wait, or send them to the Trash at once
      root list
      scan [--root <id>]                      scan one or all roots
      list [--root <id>] [--missing] [--limit <n>]
      query [--limit <n>] [--count] <query>   search (tags, "text", filters; see below). Prints file id, root, size, kind, path
      thumbs generate [--root <id>] [--limit <n>]   build thumbnails for local images; never downloads
      thumbs path <file-id> [small|medium]    where a file's cached thumbnail is
      thumbs fetch <root-id> [--approve <n>]        fetch-once downloads (needs the root setting; big batches need --approve)
      thumbs clear                                  delete the thumbnail cache (rebuildable)
      tag add <file-id> <tag>...              tag a file as the user (ns:value, or flat)
      tag remove <file-id> <tag>...
      tag show <file-id>                      tags on a file, with source and status
      tag list                                every tag with its file count
      tag alias <alias> <tag> | tag unalias <alias>
      tag imply <tag> <implied> | tag unimply <tag> <implied>
      backup now | backup list                snapshot Miles' own data now (database plus a JSON export of tags), or list snapshots
      restore list                            snapshots available to restore (the library must not be open elsewhere)
      restore <snapshot|latest> [--apply]     show what restoring would do; --apply does it (the current database is kept first)
      rule add <root-id> <folder-pattern> <tag>   layer 2: tag files under matching folders. '*' captures, '{1}' inserts it: Games/* game:{1}
      rule list | rule remove <id>
      jobs status | jobs run [--limit <n>] [--ignore-conditions]   work the background queue (waits on battery or a busy Mac unless told not to)
      jobs enqueue | jobs retry | jobs clear-failed | jobs failed
      jobs rerun metadata|rules|ml|llm [--root <id>]     redo a tagging layer; user tags and rejected tags are kept
      dup scan                                queue the hashing and image fingerprints that find duplicates (run it with 'jobs run'), then rebuild groups
      dup list [--all] [--limit <n>]          exact and near-duplicate (similar image) groups, most space first (--all includes reviewed ones). Near groups are suggestions: they cannot be resolved
      dup show <group>                        the copies in a group, with a suggestion for which to keep (only a suggestion)
      dup resolve <group> --action trash|clone|keep-all [--keep <file-id>] [--merge-tags] [--apply]
                                              preview what the action would do; --apply does it. You choose the action and the copy to keep every time.
                                              trash: extras go to the Trash. clone: extras become APFS clones of the kept copy (same volume only)
      ops list [--batch <id>] | ops undo [<batch>|latest]   the journal of changes Miles made to files, and undoing them
      standardize <root-id> [--apply]         preview re-encoding a managed root's images to its rule (old and new size, dimensions,
                                              quality); --apply does it. Originals wait in the holdback and 'ops undo' restores them
      mv <file-id> <path-in-root> [--root <id>] [--apply] | rename <file-id> <new-name> [--apply]   managed roots only; preview first
      holdback list | holdback release [--batch <id>] [--op <id>] | holdback expire   originals waiting after standardization; release
                                              sends them to the Trash early (ends 'ops undo' for them), expire does so for those past retention
      ai status                               the AI providers, whether each can run now, per-root AI settings and the review backlog
      root ai <id> [--auto-accept <0-1>|off] [--llm image,text|off]   per root: accept suggestions at or above a confidence; turn layer 4 (LLM) on for file kinds
      review list [--root <id>] [--min-confidence <0-1>] [--limit <n>]   AI suggestions waiting for you, most confident first
      review accept <file-id> <tag> | review reject <file-id> <tag> | review accept-all --min-confidence <0-1> [--root <id>]
      ask [--dry] [--limit <n>] <request>     plain-language search: shows the query the on-device model wrote, then runs it (--dry: only show)
      search save <name> <query> [--replace] | search list | search run <name> | search delete <name>

    Query syntax: a space is AND, 'or', -exclude, (groups), foo*, ns:value, ~literal (no alias or implication),
    "text in name or path", and filters type: ext: size: date: root: path: dup:exact dup:near tagged source: status:
    missing: sort:. Example: (cat or dog) -ns:old size:>5mb sort:-date

    The library is --library, or $MILES_LIBRARY, or the default registered library.
    """

    struct Failure: Error { let message: String }

    static func run(_ arguments: [String]) -> Int32 {
        do {
            try dispatch(arguments)
            return 0
        } catch let failure as Failure {
            FileHandle.standardError.write(Data("error: \(failure.message)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func dispatch(_ raw: [String]) throws {
        var args = raw
        let libraryOption = take("--library", from: &args)
        let takeOver = takeFlag("--take-over-lock", from: &args)
        guard let command = args.first else { print(usage); return }
        args.removeFirst()

        let fs = RealFileSystem()
        let registry = LibraryRegistry(preferences: UserDefaultsPreferences(UserDefaults(suiteName: "app.miles.Miles") ?? .standard))

        switch command {
        case "version", "--version":
            print("miles-cli \(MilesCore.version)")

        case "help", "--help", "-h":
            print(usage)

        case "library":
            try libraryCommand(&args, fs: fs, registry: registry)

        case "restore":
            try restoreCommand(&args, option: libraryOption, fs: fs, registry: registry, takeOver: takeOver)

        case "root", "scan", "list", "query", "tag", "search", "thumbs", "backup", "rule", "jobs", "dup", "ops", "standardize", "mv", "rename", "holdback", "ai", "review", "ask":
            let library = try openLibrary(libraryOption, fs: fs, registry: registry, takeOver: takeOver)
            defer { try? library.close() }
            // A crash or quit part-way through a file operation is settled from the disk before anything else runs.
            let settled = try library.recoverInterruptedOperations(fileSystem: fs)
            if settled > 0 { print("settled \(settled) interrupted operations; see 'ops list'") }
            switch command {
            case "root": try rootCommand(&args, library: library, fs: fs, registry: registry)
            case "scan": try scanCommand(&args, library: library, fs: fs)
            case "query": try queryCommand(&args, library: library)
            case "tag": try tagCommand(&args, library: library)
            case "search": try searchCommand(&args, library: library)
            case "thumbs": try thumbsCommand(&args, library: library, fs: fs)
            case "backup": try backupCommand(&args, library: library)
            case "rule": try ruleCommand(&args, library: library)
            case "jobs": try jobsCommand(&args, library: library, fs: fs)
            case "dup": try dupCommand(&args, library: library, fs: fs)
            case "ops": try opsCommand(&args, library: library, fs: fs)
            case "standardize": try standardizeCommand(&args, library: library, fs: fs)
            case "mv", "rename": try moveCommand(command, &args, library: library, fs: fs)
            case "holdback": try holdbackCommand(&args, library: library, fs: fs)
            case "ai": try aiCommand(&args, library: library)
            case "review": try reviewCommand(&args, library: library)
            case "ask": try askCommand(&args, library: library)
            default: try listCommand(&args, library: library)
            }

        default:
            throw Failure(message: "unknown command '\(command)'\n\n\(usage)")
        }
    }

    // MARK: library

    static func libraryCommand(_ args: inout [String], fs: FileSystem, registry: LibraryRegistry) throws {
        switch args.first {
        case "create":
            args.removeFirst()
            let name = take("--name", from: &args)
            guard let dir = args.first else { throw Failure(message: "library create needs a folder") }
            let library = try Library.create(at: dir, fileSystem: fs)
            defer { try? library.close() }
            let label = name ?? (library.directory as NSString).lastPathComponent
            registry.register(library, name: label)
            print("created library '\(label)' at \(library.directory)")
        case "list":
            for record in registry.libraries {
                let path = record.location.resolve(fileSystem: fs).map { $0 } ?? "(drive not mounted)"
                let mark = record.id == registry.defaultLibraryID ? "*" : " "
                print("\(mark) \(record.name)\t\(path)")
            }
        case "status":
            for record in registry.libraries {
                let availability = registry.availability(of: record, fileSystem: fs)
                print("\(record.name)\t\(availability.message(libraryName: record.name))")
                if availability.needsTakeOverConfirmation { print("\t(open it with --take-over-lock only if nothing else has it open)") }
            }
        case "forget":
            args.removeFirst()
            guard let name = args.first else { throw Failure(message: "library forget needs a name") }
            let matches = registry.libraries.filter { $0.name == name }
            guard matches.count == 1, let record = matches.first else {
                throw Failure(message: matches.isEmpty ? "no library named '\(name)'" : "several libraries are named '\(name)'")
            }
            registry.unregister(record.id)
            print("forgot library '\(name)'; its folder was left as it is")
        default:
            throw Failure(message: "usage: library create <dir> | library list | library status | library forget <name>")
        }
    }

    static func openLibrary(_ option: String?, fs: FileSystem, registry: LibraryRegistry, takeOver: Bool) throws -> Library {
        if let path = option ?? ProcessInfo.processInfo.environment["MILES_LIBRARY"] {
            return try Library.open(at: path, fileSystem: fs, takeOverLock: takeOver)
        }
        guard let id = registry.defaultLibraryID else {
            throw Failure(message: "no library: pass --library <dir>, set MILES_LIBRARY, or run 'library create <dir>'")
        }
        return try registry.open(id, fileSystem: fs, takeOverLock: takeOver)
    }

    // MARK: backup and restore

    static func backupCommand(_ args: inout [String], library: Library) throws {
        switch args.first {
        case "now":
            let info = try library.createBackup(kind: .manual)
            print("wrote \(info.path) (\(info.size) bytes, schema v\(info.schemaVersion))")
            if let export = info.exportPath { print("wrote \(export)") }
        case "list":
            for info in try library.backups() { printBackup(info) }
        default:
            throw Failure(message: "usage: backup now | backup list")
        }
    }

    static func printBackup(_ info: BackupInfo) {
        print("\(info.name)\t\(info.kind.rawValue)\tschema v\(info.schemaVersion)\t\(info.size) bytes\(info.exportPath == nil ? "" : "\t+export")")
    }

    /// Restore works on a closed library, so it resolves the folder itself instead of opening it.
    static func restoreCommand(_ args: inout [String], option: String?, fs: FileSystem, registry: LibraryRegistry, takeOver: Bool) throws {
        let apply = takeFlag("--apply", from: &args)
        guard let what = args.first else { throw Failure(message: "usage: restore list | restore <snapshot|latest> [--apply]") }
        guard let directory = try libraryDirectory(option, fs: fs, registry: registry) else {
            throw Failure(message: "no library: pass --library <dir>, set MILES_LIBRARY, or register one")
        }
        if what == "list" {
            for info in LibraryRestore.snapshots(inLibraryAt: directory) { printBackup(info) }
            return
        }
        let path = try LibraryRestore.resolveSnapshot(what, libraryDirectory: directory)
        let preview = try LibraryRestore.preview(snapshotPath: path)
        print("snapshot \((path as NSString).lastPathComponent): schema v\(preview.schemaVersion), \(preview.roots) roots, \(preview.files) files, \(preview.tags) tags")
        if preview.willMigrate { print("it is older than this build (v\(preview.currentSchemaVersion)) and will be migrated forward") }
        guard apply else {
            print("dry run: nothing changed. Add --apply to restore into \(directory). The current database is kept as a pre-restore snapshot first and thumbnails are rebuilt.")
            return
        }
        let result = try LibraryRestore.restore(snapshotPath: path, toLibraryAt: directory, fileSystem: fs, takeOverLock: takeOver)
        print("restored\(result.migrated ? " and migrated forward" : "")")
        if let kept = result.safetyBackup { print("previous database kept at \(kept)") }
        print("run 'scan' to bring the index up to date with the files on disk")
    }

    static func libraryDirectory(_ option: String?, fs: FileSystem, registry: LibraryRegistry) throws -> String? {
        if let path = option ?? ProcessInfo.processInfo.environment["MILES_LIBRARY"] { return URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        guard let id = registry.defaultLibraryID, let record = registry.libraries.first(where: { $0.id == id }) else { return nil }
        guard let path = record.location.resolve(fileSystem: fs) else {
            throw Failure(message: "the default library's drive is not mounted")
        }
        return path
    }

    // MARK: root

    static func rootCommand(_ args: inout [String], library: Library, fs: FileSystem, registry: LibraryRegistry) throws {
        guard let sub = args.first else { throw Failure(message: "usage: root add|remove|exclude|manage|standardize|holdback|ai|list") }
        if ["manage", "standardize", "holdback"].contains(sub) { try rootManagedCommand(&args, library: library, fs: fs); return }
        if sub == "ai" { try rootAICommand(&args, library: library); return }
        args.removeFirst()
        switch sub {
        case "add":
            guard let path = args.first else { throw Failure(message: "root add needs a folder") }
            let root = try library.addRoot(at: path, fileSystem: fs, registry: registry)
            print("added root \(root.id): \(root.location.resolve(fileSystem: fs) ?? path) (unmanaged)")
        case "remove":
            let id = try rootID(args.first)
            let dropped = try library.removeRoot(id: id)
            print("removed root \(id) and \(dropped) file records. No files on disk were touched.")
        case "exclude":
            let id = try rootID(args.first)
            try library.setExclusions(Array(args.dropFirst()), forRoot: id)
            print("root \(id) exclusions: \(args.dropFirst().isEmpty ? "(none)" : args.dropFirst().joined(separator: ", "))")
        case "fetch-once":
            let id = try rootID(args.first)
            guard args.count == 2, ["on", "off"].contains(args[1]) else { throw Failure(message: "usage: root fetch-once <id> on|off") }
            try library.setFetchOnce(args[1] == "on", forRoot: id)
            print("root \(id): fetch once \(args[1])")
        case "list":
            for status in try library.rootStatuses(fileSystem: fs) {
                let root = status.root
                let path = status.path ?? "(drive not mounted or folder missing; files kept in the index)"
                let excluded = (root.exclusions.isEmpty ? "" : "  excludes: \(root.exclusions.joined(separator: ", "))") + (root.fetchOnce ? "  fetch-once" : "") + printRoot(root)
                print("\(root.id)\t\(root.mode)\t\(try library.fileCount(rootID: root.id)) files\t\(path)\(excluded)")
            }
        default:
            throw Failure(message: "usage: root add|remove|exclude|list")
        }
    }

    // MARK: scan, list

    static func scanCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        let only = try take("--root", from: &args).map { try rootID($0) }
        let roots = try library.roots().filter { only == nil || $0.id == only }
        if let only, roots.isEmpty { throw Failure(message: "no root \(only)") }
        if roots.isEmpty { print("no roots; add one with 'root add <path>'") }
        for root in roots {
            let started = Date()
            let r = try library.scan(rootID: root.id, fileSystem: fs)
            guard r.rootAvailable else {
                print("root \(root.id): not available (drive unmounted or folder gone); nothing changed")
                continue
            }
            var line = "root \(root.id): \(r.added) added, \(r.updated) updated, \(r.unchanged) unchanged, \(r.moved) moved, "
                + "\(r.markedMissing) newly missing, \(r.removed) removed (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)"
            if !r.skippedDirectories.isEmpty { line += "\n  skipped \(r.skippedDirectories.count) unreadable or cloud-only directories" }
            if r.missingCheckSkipped { line += "\n  too many skipped directories: missing-file check not run" }
            print(line)
        }
        let queued = try library.enqueueDueJobs(ai: aiVersions())
        if queued > 0 { print("queued \(queued) tagging, hashing, fingerprint and AI jobs; run them with 'jobs run'") }
    }

    // MARK: rules and jobs

    static func ruleCommand(_ args: inout [String], library: Library) throws {
        let usage = "usage: rule add <root-id> <folder-pattern> <tag> | rule list | rule remove <id>"
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        switch sub {
        case "add":
            guard args.count == 3 else { throw Failure(message: usage) }
            let rule = try library.addTagRule(rootID: try rootID(args[0]), pattern: args[1], tag: args[2])
            print("rule \(rule.id): \(rule.pattern) -> \(rule.tag); run 'jobs run' to apply it")
        case "list":
            for rule in try library.tagRules() { print("\(rule.id)\troot \(rule.rootID)\t\(rule.pattern)\t\(rule.tag)") }
        case "remove":
            guard let id = args.first.flatMap({ Int64($0) }) else { throw Failure(message: usage) }
            try library.removeTagRule(id: id)
            print("removed rule \(id); run 'jobs run' to update tags")
        default:
            throw Failure(message: usage)
        }
    }

    static func jobsCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        let usage = "usage: jobs status | jobs run [--limit <n>] [--ignore-conditions] | jobs enqueue | jobs retry | jobs clear-failed | jobs failed | jobs rerun metadata|rules|ml|llm [--root <id>]"
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        switch sub {
        case "status":
            let c = try library.jobCounts()
            print("\(c.queued) queued, \(c.running) running, \(c.failed) failed")
        case "enqueue":
            print("queued \(try library.enqueueDueJobs(ai: aiVersions())) jobs")
        case "run":
            let ignore = takeFlag("--ignore-conditions", from: &args)
            let limit = try take("--limit", from: &args).map { value -> Int in
                guard let n = Int(value), n > 0 else { throw Failure(message: "--limit needs a positive number") }
                return n
            }
            try library.recoverInterruptedJobs()
            let handlers = blocking { await AIPipeline().allHandlers(library: library, fileSystem: fs) }
            let queue = JobQueue(library: library, handlers: handlers, conditions: ignore ? NoConditions() : SystemConditions())
            let summary = blocking { await queue.runUntilIdle(limit: limit) }
            print("ran \(summary.processed) jobs, \(summary.failed) failed")
            switch summary.end {
            case .paused(let reason): print("paused: \(reason) (use --ignore-conditions to run anyway)")
            case .limit: print("stopped at the limit; \(try library.jobCounts().queued) still queued")
            default: break
            }
        case "retry":
            print("retrying \(try library.retryFailedJobs()) failed jobs")
        case "clear-failed":
            print("cleared \(try library.clearFailedJobs()) failed jobs")
        case "failed":
            for job in try library.jobs(state: .failed) {
                print("\(job.id)\t\(job.kind.rawValue)\tfile \(job.fileID.map(String.init) ?? "-")\t\(job.error ?? "")")
            }
        case "rerun":
            let only = try take("--root", from: &args).map { try rootID($0) }
            let layer: TagLayer
            switch args.first {
            case "metadata": layer = .metadata
            case "rules": layer = .pathRules
            case "ml": layer = .systemML
            case "llm": layer = .llm
            default: throw Failure(message: usage)
            }
            if layer.isAI {
                guard let version = aiVersions()[layer] else { throw Failure(message: "no usable provider for layer \(layer.rawValue) (see 'ai status')") }
                print("queued \(try library.rerunAILayer(layer, version: version, rootID: only)) jobs; pending suggestions are replaced, accepted and rejected ones stay")
            } else {
                print("queued \(try library.rerunLayer(layer, rootID: only)) jobs")
            }
        default:
            throw Failure(message: usage)
        }
    }

    // MARK: duplicates and the journal

    static func groupID(_ value: String?) throws -> Int64 {
        guard let value, let id = Int64(value) else { throw Failure(message: "expected a duplicate group id (see 'dup list')") }
        return id
    }

    static func megabytes(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

    static func dupCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        let usage = "usage: dup scan | dup list [--all] [--limit <n>] | dup show <group> | dup resolve <group> --action trash|clone|keep-all [--keep <file-id>] [--merge-tags] [--apply]"
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        switch sub {
        case "scan":
            let queued = try library.enqueueHashingJobs() + library.enqueueFingerprintJobs()
            try library.refreshDuplicateGroups()
            try library.refreshNearDuplicateGroups()
            print("queued \(queued) hashing and fingerprint jobs\(queued > 0 ? "; run them with 'jobs run', then 'dup list'" : "")")
        case "list":
            let all = takeFlag("--all", from: &args)
            let limit = try take("--limit", from: &args).map { value -> Int in
                guard let n = Int(value), n > 0 else { throw Failure(message: "--limit needs a positive number") }
                return n
            }
            try library.refreshDuplicateGroups()
            try library.refreshNearDuplicateGroups()
            let groups = try library.duplicateGroups(includeReviewed: all, limit: limit)
            for g in groups {
                let similarity = g.kind == .near ? "\tsimilar (suggestion only)" : ""
                print("group \(g.id)\t\(g.kind.rawValue)\t\(g.members.count) copies\t\(megabytes(g.extraBytes)) extra\t\(g.status.rawValue)\(similarity)\t\(g.members.first?.relativePath ?? "")")
            }
            if groups.isEmpty { print("no duplicate groups (hashing is staged: 'dup scan', then 'jobs run')") }
        case "show":
            let id = try groupID(args.first)
            guard let group = try library.duplicateGroup(id: id) else { throw Failure(message: "no group \(id)") }
            let suggestion = library.suggestKeep(in: group)
            print("group \(group.id): \(group.members.count) copies, \(megabytes(group.extraBytes)) in the extra copies, \(group.status.rawValue)")
            for m in group.members {
                let paths = (try? library.file(id: m.id)).flatMap { $0 }.flatMap { try? library.absolutePath(of: $0, fileSystem: fs) } ?? m.relativePath
                print("  file \(m.id)\t\(m.tagCount) tags\t\(m.icloudStatus == "local" ? "" : "not downloaded\t")\(paths)")
            }
            if let suggestion { print("suggestion (yours to decide): keep file \(suggestion.fileID), \(suggestion.reason)") }
        case "resolve":
            let apply = takeFlag("--apply", from: &args)
            let merge = takeFlag("--merge-tags", from: &args)
            guard let actionName = take("--action", from: &args), let action = ResolutionAction(rawValue: actionName) else {
                throw Failure(message: "choose an action: --action trash|clone|keep-all\n\(usage)")
            }
            let keep = try take("--keep", from: &args).map { try fileID($0) }
            let id = try groupID(args.first)
            let plan = try library.planResolution(groupID: id, action: action, keep: keep, mergeTags: merge, fileSystem: fs)
            print("group \(id): \(action.rawValue)\(keep.map { ", keeping file \($0)" } ?? "")")
            for step in plan.steps { print("  \(step.kind.rawValue) file \(step.fileID): \(step.path)\n      \(step.summary)") }
            for skip in plan.skipped { print("  skip file \(skip.fileID): \(skip.path): \(skip.reason)") }
            if !plan.tagsToMerge.isEmpty { print("  tags the kept copy gains: \(plan.tagsToMerge.joined(separator: ", "))") }
            if action != .keepAll { print("  frees about \(megabytes(plan.bytesFreed)); every file is checked again before it is touched") }
            guard apply else { print("preview only; add --apply to do it"); return }
            let outcome = try library.applyResolution(plan, fileSystem: fs)
            for f in outcome.failures { print("  failed file \(f.fileID): \(f.reason)") }
            if outcome.tagsMerged > 0 { print("  merged \(outcome.tagsMerged) tags") }
            if let batch = outcome.batch { print("done: \(outcome.resolvedFileIDs.count) copies; undo with 'ops undo \(batch)'") }
            else if action == .keepAll { print("group \(id) marked reviewed") }
            if !outcome.failures.isEmpty { throw Failure(message: "\(outcome.failures.count) copies were not changed") }
        default:
            throw Failure(message: usage)
        }
    }

    static func opsCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        let usage = "usage: ops list [--batch <id>] | ops undo [<batch>|latest]"
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        switch sub {
        case "list":
            let batch = take("--batch", from: &args)
            if batch == nil {
                for b in try library.operationBatches() {
                    print("\(b.batch)\t\(b.createdAt.formatted(date: .abbreviated, time: .standard))\t\(b.operations) operations\t\(b.done) done, \(b.undone) undone")
                }
            } else {
                for op in try library.operations(batch: batch) {
                    print("\(op.id)\t\(op.kind.rawValue)\t\(op.state.rawValue)\t\(op.fromPath) -> \(op.toPath)\(op.error.map { "\t(\($0))" } ?? "")")
                }
            }
        case "undo":
            let result: UndoResult?
            if let target = args.first, target != "latest" { result = try library.undoBatch(target, fileSystem: fs) }
            else { result = try library.undoLatestBatch(fileSystem: fs) }
            guard let result else { print("nothing to undo"); return }
            print("undone \(result.undone) operations")
            if let why = result.stoppedBecause { throw Failure(message: "stopped: \(why)") }
        default:
            throw Failure(message: usage)
        }
    }

    final class Box<V>: @unchecked Sendable { var value: V? }

    /// Runs async work to completion from the synchronous command line.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = await work(); done.signal() }
        done.wait()
        return box.value!
    }

    static func listCommand(_ args: inout [String], library: Library) throws {
        let only = try take("--root", from: &args).map { try rootID($0) }
        let includeMissing = takeFlag("--missing", from: &args)
        let limit = try take("--limit", from: &args).map { value -> Int in
            guard let n = Int(value), n > 0 else { throw Failure(message: "--limit needs a positive number") }
            return n
        }
        for file in try library.files(rootID: only, includeMissing: includeMissing, limit: limit) {
            var flags = ""
            if file.icloudStatus != "local" { flags += " [\(file.icloudStatus)]" }
            if file.missingSince != nil { flags += " [missing]" }
            print("\(file.rootID)\t\(file.size)\t\(file.kind ?? "-")\t\(file.relativePath)\(flags)")
        }
    }

    // MARK: query, tag, search

    static func queryCommand(_ args: inout [String], library: Library) throws {
        let limit = try take("--limit", from: &args).map { value -> Int in
            guard let n = Int(value), n > 0 else { throw Failure(message: "--limit needs a positive number") }
            return n
        }
        let countOnly = takeFlag("--count", from: &args)
        let query = args.joined(separator: " ")
        do {
            if countOnly { print(try library.searchCount(query)); return }
            printFiles(try library.search(query, limit: limit))
        } catch let error as QueryError {
            var message = error.message
            if let offset = error.offset {
                message += "\n  \(query)\n  \(String(repeating: " ", count: offset))^"
            }
            throw Failure(message: message)
        }
    }

    static func printFiles(_ files: [IndexedFile]) {
        for file in files {
            var flags = ""
            if file.icloudStatus != "local" { flags += " [\(file.icloudStatus)]" }
            if file.missingSince != nil { flags += " [missing]" }
            print("\(file.id)\t\(file.rootID)\t\(file.size)\t\(file.kind ?? "-")\t\(file.relativePath)\(flags)")
        }
    }

    static func fileID(_ value: String?) throws -> Int64 {
        guard let value, let id = Int64(value) else { throw Failure(message: "expected a file id (the first column of 'query' output)") }
        return id
    }

    static func tagCommand(_ args: inout [String], library: Library) throws {
        let usage = "usage: tag add|remove <file-id> <tag>... | tag show <file-id> | tag list | tag alias <alias> <tag> | tag unalias <alias> | tag imply|unimply <tag> <implied>"
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        switch sub {
        case "add", "remove":
            let id = try fileID(args.first)
            let tags = Array(args.dropFirst())
            if tags.isEmpty { throw Failure(message: "tag \(sub) needs at least one tag") }
            for tag in tags {
                if sub == "add" {
                    print("tagged \(id): \(try library.addTag(tag, toFile: id).display)")
                } else {
                    print(try library.removeTag(tag, fromFile: id) ? "removed \(tag) from \(id)" : "\(id) had no \(tag) to remove")
                }
            }
        case "show":
            for t in try library.tags(forFile: try fileID(args.first), includeRejected: true) {
                var line = "\(t.name.display)\t\(t.source)\t\(t.status)"
                if let c = t.confidence { line += "\t\(String(format: "%.2f", c))" }
                print(line)
            }
        case "list":
            for t in try library.allTags() { print("\(t.fileCount)\t\(t.name.display)") }
        case "alias":
            guard args.count == 2 else { throw Failure(message: "usage: tag alias <alias> <tag>") }
            try library.setAlias(args[0], for: args[1])
            print("\(args[0]) is now an alias for \(args[1])")
        case "unalias":
            guard args.count == 1 else { throw Failure(message: "usage: tag unalias <alias>") }
            try library.removeAlias(args[0])
        case "imply", "unimply":
            guard args.count == 2 else { throw Failure(message: "usage: tag \(sub) <tag> <implied>") }
            if sub == "imply" { try library.addImplication(args[0], implies: args[1]) } else { try library.removeImplication(args[0], implies: args[1]) }
            print("\(args[0]) \(sub == "imply" ? "now implies" : "no longer implies") \(args[1])")
        default:
            throw Failure(message: usage)
        }
    }

    static func searchCommand(_ args: inout [String], library: Library) throws {
        let usage = "usage: search save <name> <query> [--replace] | search list | search run <name> | search delete <name>"
        guard let sub = args.first else { throw Failure(message: usage) }
        args.removeFirst()
        switch sub {
        case "save":
            let replace = takeFlag("--replace", from: &args)
            guard let name = args.first else { throw Failure(message: usage) }
            let saved = try library.saveSearch(name: name, query: args.dropFirst().joined(separator: " "), overwrite: replace)
            print("saved '\(saved.name)': \(saved.query)")
        case "list":
            for s in try library.savedSearches() { print("\(s.name)\t\(s.query)") }
        case "run":
            guard let name = args.first else { throw Failure(message: usage) }
            printFiles(try library.runSavedSearch(name: name))
        case "delete":
            guard let name = args.first else { throw Failure(message: usage) }
            try library.deleteSavedSearch(name: name)
            print("deleted '\(name)'")
        default:
            throw Failure(message: usage)
        }
    }

    // MARK: thumbs

    static func thumbsCommand(_ args: inout [String], library: Library, fs: FileSystem) throws {
        guard let sub = args.first else { throw Failure(message: "usage: thumbs generate|path|fetch|clear") }
        args.removeFirst()
        let service = ThumbnailService(library: library, fileSystem: fs)
        switch sub {
        case "generate":
            let root = try take("--root", from: &args).map { try rootID($0) }
            let limit = take("--limit", from: &args).flatMap(Int.init)
            let b = try service.generateMissing(rootID: root, limit: limit)
            print("generated \(b.generated), skipped \(b.skippedNotLocal) not on disk (nothing downloaded), \(b.unsupported) unsupported, \(b.failed) failed")
        case "path":
            guard let id = args.first.flatMap(Int64.init) else { throw Failure(message: "usage: thumbs path <file-id> [small|medium]") }
            let name = args.dropFirst().first ?? "medium"
            guard let size = ThumbnailSize.allCases.first(where: { "\($0)" == name }) else { throw Failure(message: "size is small or medium") }
            let path = library.thumbnailPath(fileID: id, size: size)
            guard FileManager.default.fileExists(atPath: path) else { throw Failure(message: "no thumbnail for file \(id) yet") }
            print(path)
        case "fetch":
            let root = try rootID(args.first)
            let approve = take("--approve", from: &args).flatMap(Int.init)
            do {
                let b = try service.fetchOnce(rootID: root, approvedCount: approve)
                print("fetched and generated \(b.generated), \(b.failed) failed, \(b.unsupported) unsupported")
            } catch let ThumbnailError.needsApproval(plan) {
                throw Failure(message: "\(plan.fileCount) files (\(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))) would be downloaded. Re-run with --approve \(plan.fileCount) to go ahead")
            }
        case "clear":
            try library.clearThumbnailCache()
            print("thumbnail cache cleared")
        default:
            throw Failure(message: "usage: thumbs generate|path|fetch|clear")
        }
    }

    // MARK: argument helpers

    static func rootID(_ value: String?) throws -> Int64 {
        guard let value, let id = Int64(value) else { throw Failure(message: "expected a root id (see 'root list')") }
        return id
    }

    static func take(_ name: String, from args: inout [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        args.removeSubrange(i ... i + 1)
        return value
    }

    static func takeFlag(_ name: String, from args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }
}
