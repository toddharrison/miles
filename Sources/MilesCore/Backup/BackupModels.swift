import Foundation

/// Why a snapshot was taken (ADR 0005). Scheduled and manual snapshots are rotated by age; the
/// "safety" kinds guard one specific risky step and are kept by count.
public enum BackupKind: String, CaseIterable, Sendable {
    case scheduled
    case manual
    case preMigration = "pre-migration"
    case preBulk = "pre-bulk"
    case preRestore = "pre-restore"

    /// Taken just before a risky step rather than on a schedule.
    var isSafetySnapshot: Bool { self == .preMigration || self == .preBulk || self == .preRestore }
    /// Kinds that also get a JSON export of tags and rules next to them.
    var writesExport: Bool { self == .scheduled || self == .manual }
}

/// One snapshot in a library's `backups/` folder. Everything here comes from the file name, so
/// listing never opens the databases.
public struct BackupInfo: Equatable, Identifiable, Sendable {
    public var name: String
    public var path: String
    public var kind: BackupKind
    public var createdAt: Date
    public var schemaVersion: Int
    public var size: Int64
    /// The JSON export written alongside, if any.
    public var exportPath: String?
    public var id: String { name }
}

/// Schedule and rotation. Exact counts are an implementation detail of ADR 0005.
public struct BackupPolicy: Equatable, Sendable {
    /// A scheduled snapshot is due when the newest one is older than this.
    public var interval: TimeInterval = 24 * 3600
    /// Newest scheduled snapshot of each of the last N days that have one.
    public var dailies = 7
    /// Newest scheduled snapshot of each of the last N weeks that have one.
    public var weeklies = 4
    /// Pre-migration, pre-bulk and pre-restore snapshots kept, per kind.
    public var safetyKept = 5
    /// A bulk operation reuses a pre-bulk snapshot taken this recently.
    public var bulkReuseWindow: TimeInterval = 600

    public init() {}
}

public enum BackupError: Error, Equatable, Sendable {
    case integrityCheckFailed(path: String, detail: String)
    case snapshotNotFound(String)
    case snapshotFromDifferentLibrary
    case snapshotUnreadable(path: String, detail: String)
}

extension BackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .integrityCheckFailed(let p, let d): "The backup at \(p) failed its integrity check (\(d)) and was discarded."
        case .snapshotNotFound(let n): "No backup named '\(n)'."
        case .snapshotFromDifferentLibrary: "That snapshot belongs to a different library, so it was not restored."
        case .snapshotUnreadable(let p, let d): "The snapshot \(p) cannot be read (\(d))."
        }
    }
}

/// File naming for snapshots: `snapshot-<UTC time>-v<schema>-<kind>.sqlite`.
enum BackupNaming {
    static let folder = "backups"

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return f
    }

    static func stem(kind: BackupKind, schemaVersion: Int, at date: Date) -> String {
        "snapshot-\(formatter().string(from: date))-v\(schemaVersion)-\(kind.rawValue)"
    }

    static func timestamp(_ date: Date) -> String { formatter().string(from: date) }

    static func parse(_ fileName: String) -> (kind: BackupKind, schemaVersion: Int, date: Date)? {
        guard fileName.hasSuffix(".sqlite") else { return nil }
        let stem = String(fileName.dropLast(".sqlite".count))
        let parts = stem.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "snapshot", parts[2].hasPrefix("v"),
              let version = Int(parts[2].dropFirst()),
              let date = formatter().date(from: String(parts[1])),
              let kind = BackupKind(rawValue: String(parts[3])) else { return nil }
        return (kind, version, date)
    }
}
