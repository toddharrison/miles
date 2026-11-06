import Foundation
import GRDB

public struct TagInfo: Equatable, Sendable {
    public var id: Int64
    public var name: TagName
    public var fileCount: Int
}

public struct FileTagInfo: Equatable, Sendable {
    public var name: TagName
    public var source: String
    public var status: String
    public var confidence: Double?
    public var provider: String?
    public var model: String?
}

/// Manual tagging and tag-vocabulary management (ADR 0008). Tags attach to `file` rows, so they survive moves.
extension Library {
    // MARK: Adding and removing

    /// Adds a tag as the user. A name that is an alias resolves to its canonical tag. User tags win:
    /// an existing rule or AI row for the same tag (even a rejected or suggested one) becomes a user tag.
    /// Returns the canonical name that was applied.
    @discardableResult
    public func addTag(_ text: String, toFile fileID: Int64) throws -> TagName {
        let name = try TagName(text)
        return try database.write { db in
            try requireFile(db, fileID)
            let tagID = try canonicalTagID(db, for: name, createIfMissing: true)!
            try db.execute(sql: """
                INSERT INTO file_tag (fileID, tagID, source, confidence, status, provider, model, createdAt)
                VALUES (?, ?, 'user', NULL, 'accepted', NULL, NULL, ?)
                ON CONFLICT (fileID, tagID) DO UPDATE SET
                  source = 'user', confidence = NULL, status = 'accepted', provider = NULL, model = NULL
                  WHERE source <> 'user' OR status <> 'accepted'
                """, arguments: [fileID, tagID, Date()])
            return try tagName(db, tagID)
        }
    }

    /// Removes a tag the user no longer wants. A user tag is deleted. A rule or AI tag is kept as
    /// `rejected` so it is not applied or suggested again for that file. Returns false if nothing changed.
    @discardableResult
    public func removeTag(_ text: String, fromFile fileID: Int64) throws -> Bool {
        let name = try TagName(text)
        return try database.write { db in
            try requireFile(db, fileID)
            guard let tagID = try canonicalTagID(db, for: name, createIfMissing: false) else { return false }
            try db.execute(sql: "DELETE FROM file_tag WHERE fileID = ? AND tagID = ? AND source = 'user'", arguments: [fileID, tagID])
            if db.changesCount > 0 { return true }
            try db.execute(sql: "UPDATE file_tag SET status = 'rejected' WHERE fileID = ? AND tagID = ? AND status <> 'rejected'",
                           arguments: [fileID, tagID])
            return db.changesCount > 0
        }
    }

    /// Tags on a file. Rejected rows are left out unless asked for.
    public func tags(forFile fileID: Int64, includeRejected: Bool = false) throws -> [FileTagInfo] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.name AS ns, t.name AS value, ft.source, ft.status, ft.confidence, ft.provider, ft.model
                FROM file_tag ft JOIN tag t ON t.id = ft.tagID JOIN namespace n ON n.id = t.namespaceID
                WHERE ft.fileID = ? \(includeRejected ? "" : "AND ft.status <> 'rejected'")
                ORDER BY n.name, t.name
                """, arguments: [fileID]).map {
                FileTagInfo(name: TagName(unchecked: $0["ns"], $0["value"]), source: $0["source"], status: $0["status"],
                            confidence: $0["confidence"], provider: $0["provider"], model: $0["model"])
            }
        }
    }

    /// Every tag with the number of files it is accepted on, ordered by namespace then name.
    public func allTags() throws -> [TagInfo] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, n.name AS ns, t.name AS value,
                       (SELECT COUNT(*) FROM file_tag ft WHERE ft.tagID = t.id AND ft.status = 'accepted') AS n
                FROM tag t JOIN namespace n ON n.id = t.namespaceID ORDER BY n.name, t.name
                """).map { TagInfo(id: $0["id"], name: TagName(unchecked: $0["ns"], $0["value"]), fileCount: $0["n"]) }
        }
    }

    /// Creates a namespace. Filter keys are refused (ADR 0009). Adding a tag creates its namespace on demand.
    public func createNamespace(_ text: String) throws {
        let name = try TagName.normalize(text, what: "namespace")
        if QueryFilterKey.isReserved(name) { throw TagError.reservedNamespace(name) }
        try database.write { db in _ = try ensureNamespace(db, name) }
    }

    // MARK: Aliases and implications (schema from the start, UI later; ADR 0008)

    /// Makes `alias` another name for the existing tag `tag`. A name that is already a real tag cannot
    /// become an alias. Re-pointing an existing alias is allowed.
    public func setAlias(_ aliasText: String, for tagText: String) throws {
        let alias = try TagName(aliasText), target = try TagName(tagText)
        try database.write { db in
            guard let targetID = try existingTagID(db, target) else { throw TagError.unknownTag(target.description) }
            if try existingTagID(db, alias) != nil { throw TagError.aliasConflict(alias: alias.description) }
            let nsID = try ensureNamespace(db, alias.namespace)
            try db.execute(sql: "INSERT OR REPLACE INTO tag_alias (namespaceID, name, tagID) VALUES (?, ?, ?)",
                           arguments: [nsID, alias.value, targetID])
        }
    }

    public func removeAlias(_ aliasText: String) throws {
        let alias = try TagName(aliasText)
        try database.write { db in
            try db.execute(sql: "DELETE FROM tag_alias WHERE name = ? AND namespaceID = (SELECT id FROM namespace WHERE name = ?)",
                           arguments: [alias.value, alias.namespace])
        }
    }

    /// `tag` implies `implied`: a search for `implied` also finds files tagged `tag` (transitively).
    public func addImplication(_ tagText: String, implies impliedText: String) throws {
        let tag = try TagName(tagText), implied = try TagName(impliedText)
        try database.write { db in
            let a = try canonicalTagID(db, for: tag, createIfMissing: true)!
            let b = try canonicalTagID(db, for: implied, createIfMissing: true)!
            if a == b { throw TagError.selfImplication(tag.description) }
            try db.execute(sql: "INSERT OR IGNORE INTO tag_implication (tagID, impliesTagID) VALUES (?, ?)", arguments: [a, b])
        }
    }

    public func removeImplication(_ tagText: String, implies impliedText: String) throws {
        let tag = try TagName(tagText), implied = try TagName(impliedText)
        try database.write { db in
            guard let a = try existingTagID(db, tag), let b = try existingTagID(db, implied) else { return }
            try db.execute(sql: "DELETE FROM tag_implication WHERE tagID = ? AND impliesTagID = ?", arguments: [a, b])
        }
    }

    // MARK: Internals

    private func requireFile(_ db: Database, _ id: Int64) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM file WHERE id = ?)", arguments: [id]) == true else {
            throw TagError.unknownFile(id)
        }
    }

    private func ensureNamespace(_ db: Database, _ name: String) throws -> Int64 {
        try db.execute(sql: "INSERT OR IGNORE INTO namespace (name, isDefault) VALUES (?, 0)", arguments: [name])
        return try Int64.fetchOne(db, sql: "SELECT id FROM namespace WHERE name = ?", arguments: [name])!
    }

    private func existingTagID(_ db: Database, _ name: TagName) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT t.id FROM tag t JOIN namespace n ON n.id = t.namespaceID WHERE n.name = ? AND t.name = ?",
                           arguments: [name.namespace, name.value])
    }

    /// The tag's id, following an alias. Creates the tag (and namespace) when asked and nothing matches.
    private func canonicalTagID(_ db: Database, for name: TagName, createIfMissing: Bool) throws -> Int64? {
        if let id = try existingTagID(db, name) { return id }
        if let id = try Int64.fetchOne(db, sql: """
            SELECT a.tagID FROM tag_alias a JOIN namespace n ON n.id = a.namespaceID WHERE n.name = ? AND a.name = ?
            """, arguments: [name.namespace, name.value]) { return id }
        guard createIfMissing else { return nil }
        let nsID = try ensureNamespace(db, name.namespace)
        try db.execute(sql: "INSERT INTO tag (namespaceID, name, createdAt) VALUES (?, ?, ?)", arguments: [nsID, name.value, Date()])
        return db.lastInsertedRowID
    }

    private func tagName(_ db: Database, _ id: Int64) throws -> TagName {
        let row = try Row.fetchOne(db, sql: "SELECT n.name AS ns, t.name AS value FROM tag t JOIN namespace n ON n.id = t.namespaceID WHERE t.id = ?",
                                   arguments: [id])!
        return TagName(unchecked: row["ns"], row["value"])
    }
}
