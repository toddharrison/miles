import Foundation
import GRDB

/// A folder inside a root, by path relative to the root. An empty path is the root itself.
public struct FolderRef: Hashable, Codable, Sendable {
    public var rootID: Int64
    public var path: String
    public init(rootID: Int64, path: String) { self.rootID = rootID; self.path = path }
}

/// One folder of the tree the sidebar shows: a root or a folder that holds, or has below it, a present file.
public struct FolderNode: Identifiable, Equatable, Sendable {
    public var ref: FolderRef
    /// Last path component. Empty for a root, whose name the caller knows from its location.
    public var name: String
    /// Files directly in this folder (not in its subfolders).
    public var fileCount: Int
    public var children: [FolderNode]
    public var id: FolderRef { ref }

    /// This folder and every folder below it.
    public var subtree: [FolderNode] { [self] + children.flatMap(\.subtree) }
}

/// Which folders the grid and search show. A view filter only (ADR 0017): it never changes indexing,
/// tagging, duplicates or any file. Everything is shown unless a folder is unchecked, and a folder
/// that appears later is shown. A checked folder shows only the files directly in it.
public struct FolderFilter: Equatable, Codable, Sendable {
    public enum State: Sendable { case on, off, mixed }
    public struct Summary: Equatable, Sendable { public var shown: Int; public var total: Int }

    public var unchecked: Set<FolderRef> = []
    public init(unchecked: Set<FolderRef> = []) { self.unchecked = unchecked }

    public var isActive: Bool { !unchecked.isEmpty }

    /// True if a file at this path is shown.
    public func includes(rootID: Int64, relativePath: String) -> Bool {
        guard !unchecked.isEmpty else { return true }
        return !unchecked.contains(FolderRef(rootID: rootID, path: Self.directory(of: relativePath)))
    }

    public func state(of node: FolderNode) -> State {
        let all = node.subtree
        let off = all.filter { unchecked.contains($0.ref) }.count
        return off == 0 ? .on : off == all.count ? .off : .mixed
    }

    public mutating func set(_ ref: FolderRef, checked: Bool) {
        if checked { unchecked.remove(ref) } else { unchecked.insert(ref) }
    }

    /// A click on a checkbox: an all-checked folder is unchecked with everything below it; an unchecked
    /// or mixed one is checked with everything below it.
    public mutating func toggle(_ node: FolderNode) {
        let check = state(of: node) != .on
        for n in node.subtree { set(n.ref, checked: check) }
    }

    public func summary(of tree: [FolderNode]) -> Summary {
        let all = tree.flatMap(\.subtree)
        return Summary(shown: all.filter { !unchecked.contains($0.ref) }.count, total: all.count)
    }

    /// SQL for the rows to keep, or nil when nothing is unchecked. Uses equality on the folder part of
    /// the path, never LIKE, so names with `%` or `_` match exactly.
    func sqlClause() -> (sql: String, arguments: [DatabaseValueConvertible])? {
        guard !unchecked.isEmpty else { return nil }
        let refs = unchecked.sorted { ($0.rootID, $0.path) < ($1.rootID, $1.path) }
        let rows = Array(repeating: "(?, ?)", count: refs.count).joined(separator: ", ")
        let args: [DatabaseValueConvertible] = refs.flatMap { [$0.rootID, $0.path.isEmpty ? "" : $0.path + "/"] as [DatabaseValueConvertible] }
        return ("(file.rootID, \(Self.directorySQL)) NOT IN (VALUES \(rows))", args)
    }

    /// The part of `relativePath` up to and including its last `/` (empty for a file at the root).
    static let directorySQL = "rtrim(file.relativePath, replace(file.relativePath, '/', ''))"

    static func directory(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }
}

extension Library {
    static let folderFilterKey = "folderFilter"

    /// The folders that hold present files, as a tree per root (ordered by root id, then name).
    public func folderTree() throws -> [FolderNode] {
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rootID, \(FolderFilter.directorySQL) AS dir, COUNT(*) AS n
                FROM file WHERE missingSince IS NULL GROUP BY rootID, dir
                """).map { (rootID: $0["rootID"] as Int64, dir: $0["dir"] as String, count: $0["n"] as Int) }
        }
        var direct: [FolderRef: Int] = [:]
        var children: [FolderRef: Set<String>] = [:]
        var rootIDs: Set<Int64> = []
        for (rootID, dir, count) in rows {
            rootIDs.insert(rootID)
            var path = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            direct[FolderRef(rootID: rootID, path: path), default: 0] += count
            while !path.isEmpty {
                let parent = FolderFilter.directory(of: path)
                children[FolderRef(rootID: rootID, path: parent), default: []].insert(path)
                path = parent
            }
        }
        func build(_ ref: FolderRef) -> FolderNode {
            let kids = (children[ref] ?? []).map { build(FolderRef(rootID: ref.rootID, path: $0)) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return FolderNode(ref: ref, name: (ref.path as NSString).lastPathComponent, fileCount: direct[ref] ?? 0, children: kids)
        }
        return rootIDs.sorted().map { build(FolderRef(rootID: $0, path: "")) }
    }

    /// The remembered filter. Missing or unreadable means everything is shown.
    public func folderFilter() throws -> FolderFilter {
        let text = try database.read { try String.fetchOne($0, sql: "SELECT value FROM library_meta WHERE key = ?", arguments: [Self.folderFilterKey]) }
        guard let data = text?.data(using: .utf8), let filter = try? JSONDecoder().decode(FolderFilter.self, from: data) else { return FolderFilter() }
        return filter
    }

    public func setFolderFilter(_ filter: FolderFilter) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(filter), as: UTF8.self)
        try database.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO library_meta (key, value) VALUES (?, ?)", arguments: [Self.folderFilterKey, text])
        }
    }
}
