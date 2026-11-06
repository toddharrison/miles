# 0012. Libraries and portable mode

- Status: accepted
- Date: 2026-11-06
- Amends: [0002](0002-database-sqlite-grdb.md) (database location), [0005](0005-backup-of-miles-data.md) (backup destination)

## Context

The user wants one library for their home directory on the local computer and a separate library for an external drive that travels between machines, together with a copy of the macOS app kept on that drive. ADR 0002 put the database in Application Support only.

## Decision

**Libraries**
- A **library** is one location holding one database and everything Miles owns for it: thumbnails (ADR 0011), backups, exports, the operation journal, and the lock file.
- The default library lives in `~/Library/Application Support`. A **portable library** lives in a user-chosen folder, typically on an external drive.
- Miles keeps a registry of known libraries in app preferences. Several libraries can exist. Libraries are **independent in v1**: no cross-library tags, duplicate detection or search.
- A **root belongs to exactly one library**. Miles refuses roots that overlap with another library's roots, including a root nested in another's.
- Roots on an external volume are stored as **volume plus relative path**, so a library keeps working when the drive mounts at a different path or on another Mac.
- The database is **never** placed in iCloud or any synced folder (ADR 0002 stands). A library location must be on a local filesystem (APFS or HFS+). Network shares and exFAT are refused or warned about.
- If a library's location is unavailable (for example the drive is not mounted), Miles reports it and **never creates a new empty library** in its place.

**Concurrency and versions**
- A **lock file** in the library allows one opener at a time, across Macs and app copies.
- The database records its **schema version**. An older app refuses to open a newer database. A newer app takes a backup first, then migrates.
- A **macOS copy of the app may be kept on the external drive** to run Miles on another Mac. v1 targets macOS only. The core logic stays in a Swift package separate from the UI so other front ends remain possible.

**Holdback**
- The image standardization holdback (ADR 0006) is **per volume**: a Miles folder on the same volume as the file, so the move is instant and safe. It is therefore not always inside the library folder. Journal entries record the holdback location.

**Backups**
- Backups remain local only (ADR 0005). A portable library's backups are stored **in the library folder, on the drive itself**. They exist for recovery from database corruption and similar problems, not as protection against losing the drive. Backing up the backups, and the drive, is the user's responsibility. Miles does not warn about it or require a second destination.

## Consequences

- A drive can move between Macs and carry its own tags, thumbnails and app copy.
- Each library is self-contained, so nothing links the two libraries. Duplicates across them are not detected.
- The lock file means a crash can leave a stale lock, so there must be a clear way to take over a lock after confirming nothing else has it open.
- Version gating means an app copy on the drive can fall behind the home Mac's app. The older copy refuses the newer database.
- Per-volume holdback means a library folder is not the whole picture of what Miles has written, and the UI and docs must say where holdbacks live.
- Backups on the same drive do not survive losing the drive. Accepted: the user owns that risk.
- AI providers may differ per Mac (ADR 0003). Provider and model are already recorded per suggestion.
