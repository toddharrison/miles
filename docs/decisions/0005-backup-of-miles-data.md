# 0005. Automated backup of Miles' own data

- Status: accepted
- Date: 2026-11-06

## Context

The user's files already exist on disk and are covered by whatever backup the user already uses. The data that only Miles holds, namely tags, tag sources and review decisions, path rules, and the operation journal, would be lost if the database were lost or corrupted. Backups are required to be automatic.

## Decision

- Miles backs up **its own data only**. It does not back up or copy the user's files.
- Backups are **automatic**: on a schedule, and also before schema migrations and before bulk operations.
- Snapshots are taken with SQLite's online backup API (or `VACUUM INTO`), safe while the app is running.
- Snapshots are **local only**, in a folder in Miles' Application Support area by default. No cloud or other destination in v1.
- Old snapshots are rotated (a recent set of dailies plus weeklies; exact counts set in implementation).
- Alongside snapshots, Miles writes a periodic **portable export** of tags and rules (JSON), so the data outlives the database format.
- Snapshot integrity is checked (`PRAGMA integrity_check`) and a failed backup surfaces to the user.
- Restore is a supported, tested feature, not only a file copy.

## Consequences

- Cheap, small backups because only the database and exports are copied.
- Local-only snapshots do not protect against loss of the Mac's disk. Application Support is covered by Time Machine if the user has it enabled, and a second destination can be added later as a new decision.
- Miles can warn if its backup folder is excluded from Time Machine, but does not manage Time Machine.
- Restore must be designed and tested with the migration system (ADR 0002): restoring an older snapshot needs to migrate forward cleanly.
