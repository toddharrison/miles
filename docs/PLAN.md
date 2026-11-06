# Implementation plan

Order follows risk: nothing that changes files comes before the journal, undo and backup that make those changes safe. Structure and target are in [ADR 0013](decisions/0013-project-structure-and-deployment-target.md). Invariants every step must respect are in [ARCHITECTURE.md](ARCHITECTURE.md).

**How to use this file:** work top to bottom. Tick a box only when the task is done and its tests pass. When a task changes a decision, write or supersede an ADR first. Update the README, [DATA-MODEL.md](DATA-MODEL.md) and this file in the same commit as the code they describe.

**Status:** design complete (ADRs 0001–0013). Steps 0 and 1 done (skeleton and libraries; indexing of unmanaged roots). Next: Step 2.

## Modules

| Module | Responsibility |
|---|---|
| `MilesCore` | Database and migrations (GRDB), library registry, lock and version gating, scanner and indexer, hashing, query parser to SQL, tag model and rules, duplicates, operations journal and undo, thumbnails, backup, job queue |
| `MilesAI` | Provider protocol and default providers (Foundation Models, Vision, NaturalLanguage). MLX and Ollama are later, separate providers. |
| `MilesApp` | SwiftUI app, AppKit for the thumbnail grid |
| `miles-cli` | Scan, query and restore without the UI |

## First end-to-end slice: steps 0 to 3

Index a folder, browse it as a thumbnail grid, search by tag. Nothing in it can change a user's files.

## Step 0: Skeleton (ADR 0002, 0012, 0013)
- [x] Create the Xcode project (`MilesApp`, macOS 27 minimum, non-sandboxed) and the local Swift package with `MilesCore`, `MilesAI` and a `miles-cli` target
- [x] Add GRDB as a package dependency; confirm `MilesCore` imports no SwiftUI or AppKit
- [x] Filesystem protocol with a real implementation and a fake for tests (placeholders, missing drives, moves)
- [x] Swift Testing set up; one passing test per module
- [x] Record the real build, test and CLI commands in [CLAUDE.md](../CLAUDE.md)
- [x] Database setup with GRDB migrations; initial migration creates `root` and `file` plus the schema version record
- [x] Library create and open: location validation (local filesystem only, never iCloud or synced folders), refuse unavailable locations without creating a new library
- [x] Lock file with stale-lock detection and a way to take over; refuse to open a newer schema version
- [x] Library registry in app preferences
- [x] Volume-relative root paths (volume identity plus relative path)
- [x] Overlapping roots refused, including across libraries
- [x] Update README status and tick these boxes

## Step 1: Indexing of unmanaged roots (ADR 0001, 0004)
- [x] Add and remove roots (default mode unmanaged), with per-root exclusions. A root may not be or sit inside an app-owned library
- [x] Scanner: walk a root, write `file` rows (size, modified time, kind, volume and file ID)
- [x] Exclusions: `.photoslibrary` and other app-owned library packages never indexed
- [x] Re-match moved or renamed files by volume and file ID, then by hash
- [x] Missing files: mark missing-since, remove after the grace period
- [x] iCloud status: detect dataless files, index metadata only, never trigger a download
- [x] File-change events plus periodic reconciliation
- [x] `miles-cli scan` and `miles-cli list`
- [x] Million-file synthetic scale test (`MILES_SCALE_TESTS=1 swift test --filter ScaleTests/millionFiles`; about 37 s first scan and 10 s rescan in a debug build. A 50,000-file variant runs in every `swift test`)

## Step 2: Tags and search (ADR 0008, 0009)
- [ ] Migrations: `namespace`, `tag`, `tag_alias`, `tag_implication`, `file_tag`
- [ ] Default namespace for flat tags; reserved filter keys refused as namespaces
- [ ] Manual tag add and remove (`user` source)
- [ ] Query grammar and parser with tests: AND, `-`, `or`, parentheses, wildcards, quoted text, filters, `~` literal
- [ ] Compile queries to SQL; alias resolution and implication expansion
- [ ] FTS5 over name, path and tags
- [ ] Clear parse errors, no loose-text fallback
- [ ] Saved searches stored as query strings
- [ ] `miles-cli query`

## Step 3: Thumbnails and grid (ADR 0011)
- [ ] Thumbnail cache as files in the library folder, several sizes, keyed by file identity
- [ ] Generate only for local files; keep after eviction
- [ ] Placeholder icon with cloud badge for files without a thumbnail
- [ ] Optional per-root "fetch once" setting (off by default) with batch approval
- [ ] SwiftUI app shell: library picker, root list, search bar, AppKit-backed thumbnail grid
- [ ] Open a file on user action (triggers download if needed, then generates the thumbnail)

## Step 4: Backup and restore (ADR 0005, 0012)
- [ ] Snapshots via SQLite online backup or `VACUUM INTO`; integrity check
- [ ] Schedule, plus before migrations and bulk operations
- [ ] Rotation of dailies and weeklies
- [ ] Periodic JSON export of tags and rules
- [ ] Restore (including migrating an older snapshot forward), tested
- [ ] Portable libraries store backups in the library folder; no extra warnings
- [ ] `miles-cli restore`

## Step 5: Job queue and tagging layers 1–2 (ADR 0003, 0010)
- [ ] `job` table; throttled, resumable background queue that pauses on battery or load
- [ ] Layer 1: file metadata tags (`type:`, `year:`, resolution, length)
- [ ] Layer 2: path and folder rules per root (`tag_rule`)
- [ ] System-managed namespaces
- [ ] Re-run a layer without touching user tags

## Step 6: Operations journal, undo, exact duplicates (ADR 0004, 0007)
- [ ] `operation` table; write before every action; undo from it
- [ ] Preview model for bulk operations
- [ ] Hashing pipeline: size, partial hash, full hash, cached, skips placeholders
- [ ] `dup_group`, `dup_member`; exact duplicate groups
- [ ] Resolution actions chosen by the user each time: Trash, APFS clone (same volume only), keep all
- [ ] Tag merge offered during resolution
- [ ] Unmanaged roots: only explicit user-initiated actions

## Step 7: Managed roots and image standardization (ADR 0004, 0006)
- [ ] Opt-in managed mode per root; move and rename with preview, journal, undo
- [ ] Standardization rules: max size, max long edge, quality floor, metadata policy
- [ ] JPEG and HEIC re-encode; skip RAW, animated, already-compliant files
- [ ] Per-volume holdback; 30-day default retention; early or immediate release to Trash
- [ ] `file_link` between original and derivative; tags carry over; excluded from duplicate reports
- [ ] Idempotent re-runs

## Step 8: AI (ADR 0003, 0007, 0010)
- [ ] Verify Foundation Models availability and API on macOS 27
- [ ] Provider protocol; Foundation Models, Vision and NaturalLanguage providers
- [ ] Layer 3 suggestions into the review queue; optional auto-accept threshold
- [ ] Review queue UI; rejected suggestions stay rejected; provider and model recorded
- [ ] `image_fingerprint`; perceptual-hash near-duplicate groups (suggestions only)
- [ ] Layer 4 (LLM/VLM), off by default per root and per file kind
- [ ] Natural-language query translation, showing the generated query first

## Step 9: Portable library polish (ADR 0012)
- [ ] Drive-absent handling and reconnect
- [ ] Stale lock takeover flow
- [ ] Schema version gating verified across app copies
- [ ] App copy stored on the drive; document how to use it

## Risks to check early
- **Scale:** synthetic million-file test for indexing and query speed.
- **Permissions:** Full Disk Access and file-event handling on a real home directory.
- **Foundation Models:** availability and API shape on macOS 27.
- **iCloud placeholders:** how evicted files report size and status in practice.
