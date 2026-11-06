import Foundation
import GRDB

/// Snapshots of Miles' own data (ADR 0005, 0012). They live in the library folder's `backups/`, which
/// for a portable library is on the drive itself. Nothing here reads or writes a user's files.
extension Library {
    public var backupsDirectory: String { directory + "/" + BackupNaming.folder }

    /// Takes a snapshot with `VACUUM INTO` (safe while the app runs), checks the copy with
    /// `PRAGMA integrity_check`, and only then gives it its final name. A copy that fails the check is
    /// deleted and reported. Scheduled and manual snapshots also get a JSON export of tags and rules.
    @discardableResult
    public func createBackup(kind: BackupKind, now: Date = Date()) throws -> BackupInfo {
        try Self.snapshot(of: database, into: backupsDirectory, kind: kind, schemaVersion: try schemaVersion, now: now)
    }

    /// Existing snapshots, newest first.
    public func backups() throws -> [BackupInfo] { Self.listBackups(in: backupsDirectory) }

    /// Takes a scheduled snapshot if the newest one is older than the policy interval, then rotates.
    /// Returns nil when nothing was due. A failure is thrown so the caller can surface it.
    @discardableResult
    public func runScheduledBackupIfDue(policy: BackupPolicy = BackupPolicy(), now: Date = Date()) throws -> BackupInfo? {
        let newest = try backups().first { $0.kind == .scheduled }
        if let newest, now.timeIntervalSince(newest.createdAt) < policy.interval { return nil }
        let info = try createBackup(kind: .scheduled, now: now)
        try rotateBackups(policy: policy, now: now)
        return info
    }

    /// Call before any bulk change to Miles' data (dropping a root and its records, and from Step 6 on,
    /// bulk file operations). Reuses a pre-bulk snapshot taken within the policy's reuse window.
    @discardableResult
    public func backupBeforeBulkOperation(policy: BackupPolicy = BackupPolicy(), now: Date = Date()) throws -> BackupInfo {
        if let recent = try backups().first(where: { $0.kind == .preBulk }),
           now.timeIntervalSince(recent.createdAt) < policy.bulkReuseWindow { return recent }
        let info = try createBackup(kind: .preBulk, now: now)
        try rotateBackups(policy: policy, now: now)
        return info
    }

    /// Deletes snapshots (and their exports) beyond the policy. Manual snapshots are never rotated.
    public func rotateBackups(policy: BackupPolicy = BackupPolicy(), now: Date = Date()) throws {
        let all = try backups()
        var keep = Set<String>()

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let scheduled = all.filter { $0.kind == .scheduled }   // newest first
        func keepNewestPerBucket(_ limit: Int, key: (Date) -> Int) {
            var seen = Set<Int>()
            for info in scheduled {
                let k = key(info.createdAt)
                guard seen.insert(k).inserted else { continue }
                if seen.count > limit { break }
                keep.insert(info.name)
            }
        }
        keepNewestPerBucket(policy.dailies) { Int(floor($0.timeIntervalSince1970 / 86_400)) }
        keepNewestPerBucket(policy.weeklies) {
            let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0)
            return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
        }
        for kind in BackupKind.allCases where kind.isSafetySnapshot {
            for info in all.filter({ $0.kind == kind }).prefix(policy.safetyKept) { keep.insert(info.name) }
        }
        for info in all where info.kind == .manual { keep.insert(info.name) }

        for info in all where !keep.contains(info.name) {
            try? FileManager.default.removeItem(atPath: info.path)
            if let export = info.exportPath { try? FileManager.default.removeItem(atPath: export) }
        }
        // Half-written snapshots left by a crash.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory)) ?? [] where name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(atPath: backupsDirectory + "/" + name)
        }
    }

    // MARK: Shared with restore

    static func listBackups(in directory: String) -> [BackupInfo] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name -> BackupInfo? in
            guard let parsed = BackupNaming.parse(name) else { return nil }
            let path = directory + "/" + name
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            let export = String(path.dropLast(".sqlite".count)) + ".json"
            return BackupInfo(name: name, path: path, kind: parsed.kind, createdAt: parsed.date, schemaVersion: parsed.schemaVersion,
                              size: size, exportPath: fm.fileExists(atPath: export) ? export : nil)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Copies `writer`'s database into `directory`. The partial file is verified before it is renamed.
    static func snapshot(of writer: some DatabaseWriter, into directory: String, kind: BackupKind,
                         schemaVersion: Int, now: Date) throws -> BackupInfo {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stem = BackupNaming.stem(kind: kind, schemaVersion: schemaVersion, at: now)
        let final = directory + "/" + stem + ".sqlite"
        let partial = final + ".partial"
        try? fm.removeItem(atPath: partial)

        do {
            try writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO ?", arguments: [partial]) }
            try verifyIntegrity(atPath: partial)
            var exportPath: String?
            if kind.writesExport {
                let data = try writer.read { db in try TagExport.make(from: db, schemaVersion: schemaVersion, now: now).encoded() }
                let path = directory + "/" + stem + ".json"
                try data.write(to: URL(fileURLWithPath: path + ".partial"), options: .atomic)
                try fm.moveItem(atPath: path + ".partial", toPath: path)
                exportPath = path
            }
            guard !fm.fileExists(atPath: final) else { throw CocoaError(.fileWriteFileExists) }
            try fm.moveItem(atPath: partial, toPath: final)
            let size = ((try? fm.attributesOfItem(atPath: final))?[.size] as? NSNumber)?.int64Value ?? 0
            return BackupInfo(name: stem + ".sqlite", path: final, kind: kind, createdAt: now,
                              schemaVersion: schemaVersion, size: size, exportPath: exportPath)
        } catch {
            try? fm.removeItem(atPath: partial)
            try? fm.removeItem(atPath: directory + "/" + stem + ".json.partial")
            throw error
        }
    }

    /// `PRAGMA integrity_check` on a database file, opened read-only.
    static func verifyIntegrity(atPath path: String) throws {
        let result: [String]
        do {
            let queue = try DatabaseQueue(path: path, configuration: LibraryDatabase.configuration(readonly: true))
            result = try queue.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }
        } catch {
            throw BackupError.integrityCheckFailed(path: path, detail: error.localizedDescription)
        }
        guard result == ["ok"] else {
            throw BackupError.integrityCheckFailed(path: path, detail: result.prefix(3).joined(separator: "; "))
        }
    }
}
