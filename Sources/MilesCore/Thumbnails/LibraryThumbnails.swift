import Foundation
import GRDB

extension Library {
    /// Where a file's thumbnail of `size` is (or would be) cached. Keyed by `file.id`, which survives
    /// moves and renames. The file may not exist: check before reading.
    public func thumbnailPath(fileID: Int64, size: ThumbnailSize) -> String {
        "\(directory)/thumbnails/\(size.rawValue)/\(fileID / 1000)/\(fileID).jpg"
    }

    /// Deletes Miles' own derived thumbnail files and records. Never touches user files; the cache
    /// can always be rebuilt (ADR 0011).
    public func clearThumbnailCache() throws {
        try database.write { try $0.execute(sql: "DELETE FROM thumbnail") }
        let dir = directory + "/thumbnails"
        if FileManager.default.fileExists(atPath: dir) { try FileManager.default.removeItem(atPath: dir) }
    }

    /// Removes size folders Miles no longer makes (the 512 size was dropped to save disk space). Derived data only.
    public func removeObsoleteThumbnailSizes() {
        let keep = Set(ThumbnailSize.allCases.map { String($0.rawValue) })
        let base = directory + "/thumbnails"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] where Int(name) != nil && !keep.contains(name) {
            try? FileManager.default.removeItem(atPath: base + "/" + name)
        }
    }

    public func file(id: Int64) throws -> IndexedFile? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT id, rootID, relativePath, size, modified, kind, icloudStatus, missingSince FROM file WHERE id = ?",
                             arguments: [id]).map(Self.indexedFile)
        }
    }

    /// Current absolute path of an indexed file, or throws if its root's drive is not mounted.
    public func absolutePath(of file: IndexedFile, fileSystem fs: FileSystem) throws -> String {
        guard let root = try roots().first(where: { $0.id == file.rootID }),
              let base = root.location.resolve(fileSystem: fs) else { throw ThumbnailError.rootUnavailable(file.rootID) }
        return (base == "/" ? "" : base) + "/" + file.relativePath
    }

    /// Per-root "fetch once to build a thumbnail" setting. Off by default (ADR 0011).
    public func setFetchOnce(_ enabled: Bool, forRoot rootID: Int64) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE root SET fetchOnce = ? WHERE id = ?", arguments: [enabled, rootID])
            guard db.changesCount == 1 else { throw LibraryError.invalidRoot("root \(rootID)") }
        }
    }

    /// Local images with no thumbnail, or one made from an older version of the file.
    func filesNeedingThumbnails(rootID: Int64?, limit: Int?) throws -> [Int64] {
        try database.read { db in
            var sql = """
                SELECT f.id FROM file f LEFT JOIN thumbnail t ON t.fileID = f.id
                WHERE f.kind = 'image' AND f.missingSince IS NULL AND f.icloudStatus = 'local'
                  AND (t.fileID IS NULL OR t.sourceSize <> f.size OR t.sourceModified <> f.modified)
                """
            var args: [DatabaseValueConvertible] = []
            if let rootID { sql += " AND f.rootID = ?"; args.append(rootID) }
            sql += " ORDER BY f.id"
            if let limit { sql += " LIMIT ?"; args.append(limit) }
            return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Evicted images that have no thumbnail at all (the candidates for "fetch once").
    func placeholdersWithoutThumbnails(rootID: Int64) throws -> [IndexedFile] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, f.rootID, f.relativePath, f.size, f.modified, f.kind, f.icloudStatus, f.missingSince
                FROM file f LEFT JOIN thumbnail t ON t.fileID = f.id
                WHERE f.rootID = ? AND f.kind = 'image' AND f.missingSince IS NULL AND f.icloudStatus = 'dataless' AND t.fileID IS NULL
                ORDER BY f.id
                """, arguments: [rootID]).map(Self.indexedFile)
        }
    }

    static func indexedFile(_ row: Row) -> IndexedFile {
        IndexedFile(id: row["id"], rootID: row["rootID"], relativePath: row["relativePath"], size: row["size"],
                    modified: row["modified"], kind: row["kind"], icloudStatus: row["icloudStatus"], missingSince: row["missingSince"])
    }
}
