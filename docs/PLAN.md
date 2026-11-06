# Implementation plan

Order follows risk: nothing that changes files comes before the journal, undo and backup that make those changes safe. Structure and target are in [ADR 0013](decisions/0013-project-structure-and-deployment-target.md). Invariants every step must respect are in [ARCHITECTURE.md](ARCHITECTURE.md).

**How to use this file:** work top to bottom. Tick a box only when the task is done and its tests pass. When a task changes a decision, write or supersede an ADR first. Update the README, [DATA-MODEL.md](DATA-MODEL.md) and this file in the same commit as the code they describe.

**Status:** design complete (ADRs 0001–0014). Steps 0 to 6 done (skeleton and libraries; indexing of unmanaged roots; tags and search; thumbnails and grid; backup and restore; job queue and tagging layers 1–2; operations journal, undo and exact duplicates). Next: Step 7.

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
- [x] Million-file synthetic scale test (`MILES_SCALE_TESTS=1 swift test --filter ScaleTests/millionFiles`; about 43 s first scan and 8 s rescan in a debug build, with the search index maintained. A 50,000-file variant runs in every `swift test`)

## Step 2: Tags and search (ADR 0008, 0009)
- [x] Migrations: `namespace`, `tag`, `tag_alias`, `tag_implication`, `file_tag`
- [x] Default namespace for flat tags; reserved filter keys refused as namespaces
- [x] Manual tag add and remove (`user` source)
- [x] Query grammar and parser with tests: AND, `-`, `or`, parentheses, wildcards, quoted text, filters, `~` literal
- [x] Compile queries to SQL; alias resolution and implication expansion
- [x] FTS5 over name, path and tags
- [x] Clear parse errors, no loose-text fallback
- [x] Saved searches stored as query strings
- [x] `miles-cli query`

Notes from Step 2:
- `created:`, `sort:created` and `dup:near` parse but fail with a clear error: the `file` table has no creation date yet, and fingerprints arrive with Step 8. Add a creation-date column (scanner and `FileSystem` change, with a migration) when `created:` is wanted.
- `dup:exact` works from `file.fullHash`, so it finds files only once the Step 6 hashing pipeline has filled hashes (it ignores hard links and size 0 no better than the groups do: use `miles-cli dup list` for the real groups).
- A bare `tagged` is the filter (`-tagged` finds untagged files), so a flat tag named `tagged` is refused.
- Million-file scale test after the FTS triggers: about 43 s first scan and 8 s rescan (debug build).

## Step 3: Thumbnails and grid (ADR 0011)
- [x] Thumbnail cache as files in the library folder, several sizes, keyed by file identity
- [x] Generate only for local files; keep after eviction
- [x] Placeholder icon with cloud badge for files without a thumbnail
- [x] Optional per-root "fetch once" setting (off by default) with batch approval
- [x] SwiftUI app shell: library picker, root list, search bar, AppKit-backed thumbnail grid
- [x] Open a file on user action (triggers download if needed, then generates the thumbnail)

Notes from Step 3:
- Cache layout: `thumbnails/<128|256|512>/<fileID/1000>/<fileID>.jpg` in the library folder, keyed by `file.id` so moves and renames keep the thumbnail. A `thumbnail` table records the file size and modified time each set came from, so an edited file is regenerated. Migration v3 (schema version 3) also adds `root.fetchOnce`.
- `ThumbnailService` never downloads: it checks live metadata before reading content. Downloads happen only in `prepareToOpen` and `fetchOnce`, through the new `FileSystem.download(at:)`. Fetch once needs the root setting, and a batch over 25 files or 250 MB needs approval (`approvedCount`). Miles does not evict the file again; macOS does that.
- Only images get thumbnails (ImageIO). Video and PDF need a Quick Look renderer behind the `ThumbnailRenderer` protocol: a later addition.
- The app is build- and launch-checked only. The SwiftUI shell and the AppKit grid have no automated tests; the logic they call is tested in `ThumbnailTests`.
- CLI: `thumbs generate|path|fetch|clear` and `root fetch-once <id> on|off`.

## Step 4: Backup and restore (ADR 0005, 0012)
- [x] Snapshots via SQLite online backup or `VACUUM INTO`; integrity check
- [x] Schedule, plus before migrations and bulk operations
- [x] Rotation of dailies and weeklies
- [x] Periodic JSON export of tags and rules
- [x] Restore (including migrating an older snapshot forward), tested
- [x] Portable libraries store backups in the library folder; no extra warnings
- [x] `miles-cli restore`

## Step 5: Job queue and tagging layers 1–2 (ADR 0003, 0010, 0014)
- [x] `job` table; throttled, resumable background queue that pauses on battery or load
- [x] Layer 1: file metadata tags (`kind:`, `year:`, `resolution:`, `length:`; ADR 0014 renamed `type:` because ADR 0009 reserves it)
- [x] Layer 2: path and folder rules per root (`tag_rule`)
- [x] System-managed namespaces
- [x] Re-run a layer without touching user tags
- The app starts the queue when a library opens and queues due work after each scan. CLI: `rule add|list|remove`, `jobs status|run|enqueue|retry|clear-failed|failed|rerun`; `scan` queues due jobs. The queue wiring in the app is build-checked only; the logic is tested in `JobQueueTests` and `TaggingLayerTests`.
- Not in this step: metadata-pattern rules (a rule matches folders only), UI for rules and for the review queue (Step 8).

## Step 6: Operations journal, undo, exact duplicates (ADR 0004, 0007)
- [x] `operation` table; write before every action; undo from it
- [x] Preview model for bulk operations
- [x] Hashing pipeline: size, partial hash, full hash, cached, skips placeholders
- [x] `dup_group`, `dup_member`; exact duplicate groups
- [x] Resolution actions chosen by the user each time: Trash, APFS clone (same volume only), keep all
- [x] Tag merge offered during resolution
- [x] Unmanaged roots: only explicit user-initiated actions

Notes from Step 6:
- Migration v5 (schema version 5) adds `operation`, `dup_group`, `dup_member`. `image_fingerprint` and `file_link` wait for Steps 8 and 7.
- `FileSystem` gained `move` (never replaces), `trash` (returns where the item went) and `clone` (`clonefile`). These and the journal are the only way Miles changes a user's file. Only `applyResolution` and `undoBatch` reach them, and `applyResolution` takes a `ResolutionPlan` that only `planResolution` can make, so there is no way to act without a preview.
- Hashing is staged over two job kinds: `hash-partial` (files that share a size, never size 0, hard links not counted as peers) and `hash-full` (files whose partial hash matches). Whichever file finishes its partial hash last queues the full hashes. `scan` and the app queue them through `enqueueDueJobs`.
- A clone is journaled as two operations, `trash` of the extra and `clone` onto its path. If the clone fails the trash is undone at once. Undoing a clone sends the clone to the Trash (Miles never deletes) and only if it is still unmodified; undoing a trash never replaces a file that has appeared at the old path.
- Before it touches a file, apply re-checks it: local, at its path, indexed size and time, and a fresh full hash equal to the recorded one. A bulk apply (more than one file) takes a `pre-bulk` snapshot first.
- Undoing a resolution does not undo a tag merge (it only added tags). Group ids are not stable across a refresh that drops and recreates a group.
- Not in this step: UI for duplicates and the journal (Step 8 adds the review UI work; the app only runs `recoverInterruptedOperations` and queues hashing), move and rename operations, holdback and retention (Step 7).
- CLI: `dup scan|list|show|resolve`, `ops list|undo`. Real-disk check: trash and clone with undo run against temp files on APFS, restoring the original inodes. The app is build-checked only.

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
