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
      root list
      scan [--root <id>]                      scan one or all roots
      list [--root <id>] [--missing] [--limit <n>]

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

        case "root", "scan", "list":
            let library = try openLibrary(libraryOption, fs: fs, registry: registry, takeOver: takeOver)
            defer { try? library.close() }
            switch command {
            case "root": try rootCommand(&args, library: library, fs: fs, registry: registry)
            case "scan": try scanCommand(&args, library: library, fs: fs)
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
        case "list":
            for root in try library.roots() {
                let path = root.location.resolve(fileSystem: fs) ?? "(drive not mounted)"
                let excluded = root.exclusions.isEmpty ? "" : "  excludes: \(root.exclusions.joined(separator: ", "))"
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
