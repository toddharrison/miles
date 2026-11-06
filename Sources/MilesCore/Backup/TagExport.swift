import Foundation
import GRDB

/// The portable export of tags and rules (ADR 0005): plain JSON that outlives the database format.
/// Files are identified by root (volume and relative path) plus path, never by row id.
struct TagExport: Codable {
    static let formatVersion = 1

    struct Namespace: Codable { var name: String; var isDefault: Bool; var isSystem: Bool? }
    struct Tag: Codable { var namespace: String; var name: String }
    struct Alias: Codable { var namespace: String; var name: String; var tag: String }
    struct Implication: Codable { var tag: String; var implies: String }
    struct SavedSearch: Codable { var name: String; var query: String }
    struct FileTag: Codable {
        var rootVolumeID: String
        var rootPath: String
        var path: String
        var tag: String
        var source: String
        var status: String
        var confidence: Double?
        var provider: String?
        var model: String?
        /// The tagging layer that made a rule or AI row (ADR 0014). Absent in older exports.
        var layer: Int?
    }

    var formatVersion = TagExport.formatVersion
    var exportedAt: Date
    var schemaVersion: Int
    var libraryID: String?
    var namespaces: [Namespace]
    var tags: [Tag]
    var aliases: [Alias]
    var implications: [Implication]
    var savedSearches: [SavedSearch]
    var fileTags: [FileTag]
    /// Path and metadata rules (`tag_rule`).
    var tagRules: [[String: String]]

    static func make(from db: Database, schemaVersion: Int, now: Date) throws -> TagExport {
        let qualified = "n.name || ':' || t.name"
        return TagExport(
            exportedAt: now, schemaVersion: schemaVersion,
            libraryID: try String.fetchOne(db, sql: "SELECT value FROM library_meta WHERE key = ?", arguments: [LibraryDatabase.metaLibraryIDKey]),
            namespaces: try Row.fetchAll(db, sql: "SELECT name, isDefault, isSystem FROM namespace ORDER BY name").map { Namespace(name: $0["name"], isDefault: $0["isDefault"], isSystem: $0["isSystem"]) },
            tags: try Row.fetchAll(db, sql: "SELECT n.name AS ns, t.name AS name FROM tag t JOIN namespace n ON n.id = t.namespaceID ORDER BY n.name, t.name")
                .map { Tag(namespace: $0["ns"], name: $0["name"]) },
            aliases: try Row.fetchAll(db, sql: """
                SELECT n.name AS ns, a.name AS name, n2.name || ':' || t.name AS tag FROM tag_alias a
                JOIN namespace n ON n.id = a.namespaceID JOIN tag t ON t.id = a.tagID
                JOIN namespace n2 ON n2.id = t.namespaceID ORDER BY n.name, a.name
                """).map { Alias(namespace: $0["ns"], name: $0["name"], tag: $0["tag"]) },
            implications: try Row.fetchAll(db, sql: """
                SELECT n.name || ':' || t.name AS tag, n2.name || ':' || t2.name AS implied FROM tag_implication i
                JOIN tag t ON t.id = i.tagID JOIN namespace n ON n.id = t.namespaceID
                JOIN tag t2 ON t2.id = i.impliesTagID JOIN namespace n2 ON n2.id = t2.namespaceID
                ORDER BY tag, implied
                """).map { Implication(tag: $0["tag"], implies: $0["implied"]) },
            savedSearches: try Row.fetchAll(db, sql: "SELECT name, query FROM saved_search ORDER BY name").map { SavedSearch(name: $0["name"], query: $0["query"]) },
            fileTags: try Row.fetchAll(db, sql: """
                SELECT r.volumeID AS vol, r.relativePath AS root, f.relativePath AS path, \(qualified) AS tag,
                       ft.source, ft.status, ft.confidence, ft.provider, ft.model, ft.layer
                FROM file_tag ft JOIN file f ON f.id = ft.fileID JOIN root r ON r.id = f.rootID
                JOIN tag t ON t.id = ft.tagID JOIN namespace n ON n.id = t.namespaceID
                ORDER BY r.id, f.relativePath, tag
                """).map {
                FileTag(rootVolumeID: $0["vol"], rootPath: $0["root"], path: $0["path"], tag: $0["tag"], source: $0["source"],
                        status: $0["status"], confidence: $0["confidence"], provider: $0["provider"], model: $0["model"], layer: $0["layer"])
            },
            tagRules: try db.tableExists("tag_rule")
                ? Row.fetchAll(db, sql: "SELECT * FROM tag_rule").map { row in
                    Dictionary(uniqueKeysWithValues: row.columnNames.compactMap { c in
                        String.fromDatabaseValue(row[c] as DatabaseValue).map { (c, $0) } })
                }
                : [])
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
