import Foundation
import GRDB

public struct SavedSearch: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var query: String
}

extension Library {
    /// Files matching a query in the syntax of ADR 0009. A malformed query throws `QueryError`.
    public func search(_ query: String, limit: Int? = nil, offset: Int = 0) throws -> [IndexedFile] {
        let compiled = try QueryCompiler.compile(try QueryParser.parse(query))
        return try database.read { db in
            var sql = """
                SELECT file.id, file.rootID, file.relativePath, file.size, file.modified, file.kind, file.icloudStatus, file.missingSince
                FROM file WHERE \(compiled.whereSQL) ORDER BY \(compiled.orderSQL)
                """
            var args = compiled.arguments
            if let limit { sql += " LIMIT ? OFFSET ?"; args.append(limit.databaseValue); args.append(offset.databaseValue) }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                IndexedFile(id: $0["id"], rootID: $0["rootID"], relativePath: $0["relativePath"], size: $0["size"],
                            modified: $0["modified"], kind: $0["kind"], icloudStatus: $0["icloudStatus"],
                            missingSince: $0["missingSince"])
            }
        }
    }

    public func searchCount(_ query: String) throws -> Int {
        let compiled = try QueryCompiler.compile(try QueryParser.parse(query))
        return try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file WHERE \(compiled.whereSQL)",
                             arguments: StatementArguments(compiled.arguments)) ?? 0
        }
    }

    // MARK: Saved searches (stored as query strings, so they follow later alias and implication changes)

    /// Saves a query under a name. The query must parse and compile. An existing name is refused unless `overwrite`.
    @discardableResult
    public func saveSearch(name rawName: String, query: String, overwrite: Bool = false) throws -> SavedSearch {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw TagError.invalidName(rawName, reason: "a saved search needs a name") }
        _ = try QueryCompiler.compile(try QueryParser.parse(query))
        return try database.write { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM saved_search WHERE name = ?)", arguments: [name]) == true
            if exists && !overwrite { throw TagError.duplicateSearchName(name) }
            try db.execute(sql: """
                INSERT INTO saved_search (name, query, createdAt) VALUES (?, ?, ?)
                ON CONFLICT (name) DO UPDATE SET query = excluded.query
                """, arguments: [name, query, Date()])
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM saved_search WHERE name = ?", arguments: [name])!
            return SavedSearch(id: id, name: name, query: query)
        }
    }

    public func savedSearches() throws -> [SavedSearch] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, query FROM saved_search ORDER BY name COLLATE NOCASE").map {
                SavedSearch(id: $0["id"], name: $0["name"], query: $0["query"])
            }
        }
    }

    public func deleteSavedSearch(name: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM saved_search WHERE name = ?", arguments: [name])
            if db.changesCount == 0 { throw TagError.unknownSearch(name) }
        }
    }

    /// Runs a saved search with the query as it is now stored.
    public func runSavedSearch(name: String, limit: Int? = nil) throws -> [IndexedFile] {
        let query = try database.read { db in
            try String.fetchOne(db, sql: "SELECT query FROM saved_search WHERE name = ?", arguments: [name])
        }
        guard let query else { throw TagError.unknownSearch(name) }
        return try search(query, limit: limit)
    }
}
