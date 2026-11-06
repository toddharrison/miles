import Foundation
import MilesCore

/// `miles-cli`: scan and list without the UI. Reads and indexes only; no command here changes a user's files.
enum CLI {
    static let usage = """
    usage: miles-cli [--library <dir>] [--take-over-lock] <command>

    commands:
      version
      library create <dir> [--name <name>]    create and register a library
      library list                            registered libraries
      library forget <name>                   unregister a library (files and its folder are untouched)
      root add <path>                         index a folder in place (unmanaged)
      root remove <id>                        stop indexing; forgets its records, touches no files
      root exclude <id> <pattern>...          replace the root's exclusions (a name, or a path/relative/to/root)
      root fetch-once <id> on|off             per-root: download evicted images once to build thumbnails (off by default)
      root list
      scan [--root <id>]                      scan one or all roots
      list [--root <id>] [--missing] [--limit <n>]
      query [--limit <n>] [--count] <query>   search (tags, "text", filters; see below). Prints file id, root, size, kind, path
      thumbs generate [--root <id>] [--limit <n>]   build thumbnails for local images; never downloads
      thumbs path <file-id> [small|medium|large]    where a file's cached thumbnail is
      thumbs fetch <root-id> [--approve <n>]        fetch-once downloads (needs the root setting; big batches need --approve)
      thumbs clear                                  delete the thumbnail cache (rebuildable)
      tag add <file-id> <tag>...              tag a file as the user (ns:value, or flat)
      tag remove <file-id> <tag>...
      tag show <file-id>                      tags on a file, with source and status
      tag list                                every tag with its file count
      tag alias <alias> <tag> | tag unalias <alias>
      tag imply <tag> <implied> | tag unimply <tag> <implied>
      search save <name> <query> [--replace] | search list | search run <name> | search delete <name>

    Query syntax: a space is AND, 'or', -exclude, (groups), foo*, ns:value, ~literal (no alias or implication),
    "text in name or path", and filters type: ext: size: date: root: path: dup:exact tagged source: status:
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

        case "root", "scan", "list", "query", "tag", "search", "thumbs":
            let library = try openLibrary(libraryOption, fs: fs, registry: registry, takeOver: takeOver)
            defer { try? library.close() }
            switch command {
            case "root": try rootCommand(&args, library: library, fs: fs, registry: registry)
            case "scan": try scanCommand(&args, library: library, fs: fs)
            case "query": try queryCommand(&args, library: library)
            case "tag": try tagCommand(&args, library: library)
            case "search": try searchCommand(&args, library: library)
            case "thumbs": try thumbsCommand(&args, library: library, fs: fs)
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
            throw Failure(message: "usage: library create <dir> | library list | library forget <name>")
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

    // MARK: root

    static func rootCommand(_ args: inout [String], library: Library, fs: FileSystem, registry: LibraryRegistry) throws {
        guard let sub = args.first else { throw Failure(message: "usage: root add|remove|exclude|list") }
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
            for root in try library.roots() {
                let path = root.location.resolve(fileSystem: fs) ?? "(drive not mounted)"
                let excluded = (root.exclusions.isEmpty ? "" : "  excludes: \(root.exclusions.joined(separator: ", "))") + (root.fetchOnce ? "  fetch-once" : "")
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
            guard let id = args.first.flatMap(Int64.init) else { throw Failure(message: "usage: thumbs path <file-id> [small|medium|large]") }
            let name = args.dropFirst().first ?? "medium"
            guard let size = ThumbnailSize.allCases.first(where: { "\($0)" == name }) else { throw Failure(message: "size is small, medium or large") }
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
