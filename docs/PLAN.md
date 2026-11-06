# Implementation plan

Order follows risk: nothing that changes files comes before the journal, undo and backup that make those changes safe. Structure and target are in [ADR 0013](decisions/0013-project-structure-and-deployment-target.md). Invariants every step must respect are in [ARCHITECTURE.md](ARCHITECTURE.md).

**How to use this file:** work top to bottom. Tick a box only when the task is done and its tests pass. When a task changes a decision, write or supersede an ADR first. Update the README, [DATA-MODEL.md](DATA-MODEL.md) and this file in the same commit as the code they describe.

**Status:** design complete (ADRs 0001–0014). Steps 0 to 9 done (skeleton and libraries; indexing of unmanaged roots; tags and search; thumbnails and grid; backup and restore; job queue and tagging layers 1–2; operations journal, undo and exact duplicates; managed roots and image standardization; AI layers, review queue, near-duplicates and plain-language search; portable library polish). Next: nothing scheduled; see Risks.

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
- `created:`, `sort:created` and `dup:near` parse but fail with a clear error: the `file` table has no creation date yet, and near-duplicate fingerprints came with Step 8 (`dup:near` now works). Add a creation-date column (scanner and `FileSystem` change, with a migration) when `created:` is wanted.
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
- [x] Opt-in managed mode per root; move and rename with preview, journal, undo
- [x] Standardization rules: max size, max long edge, quality floor, metadata policy
- [x] JPEG and HEIC re-encode; skip RAW, animated, already-compliant files
- [x] Per-volume holdback; 30-day default retention; early or immediate release to Trash
- [x] `file_link` between original and derivative; tags carry over; excluded from duplicate reports
- [x] Idempotent re-runs

Notes from Step 7:
- Migration v6 (schema version 6): `root.standardization` (JSON rule), `root.holdbackDays` (30), `root.releaseImmediately`; `operation.resultHash` and `operation.holdbackUntil`; `file_link`.
- Managed mode is `root manage <id> on|off`, per root only. Move and rename (`planMoves`, `planRename`, `applyMoves`) work only between managed roots on one volume, refuse paths that escape the root, hit an exclusion or an app-owned package, or whose destination exists, and check each file again before it moves. New folders stay if a move is undone. Case-only renames are refused (the destination "exists" on a case-insensitive volume).
- Standardization (`planStandardization`, `applyStandardization`) re-encodes in place: the previewed content hash is re-checked, the new file is written into the holdback, the original is renamed into the holdback, then the new file is renamed into place; a failure at either rename puts the original back. The quality ladder runs from 0.85 down to the floor and stops at the first fit. A file that cannot meet the rule above the floor, or would not get smaller, is skipped with the reason. Only JPEG and HEIC are re-encoded; a format change (PNG to JPEG) is not built, and the metadata policy is preserve by default with `--strip-location` dropping GPS data from files that are re-encoded. A file that already complies is never rewritten to strip location.
- The file row stays with the derivative (same id, so tags, thumbnails' keys and saved state carry over); `file_link` records the original's hash and size. Exact duplicate groups need equal hashes, which a derivative never has, so an original and its resize never group; `areLinked` is there for the Step 8 near-duplicate pass.
- The holdback is `<mount>/.miles-holdback/<library id>/<batch>/` on a drive, and `~/Library/Application Support/Miles/Holdback/<library id>/<batch>/` for the boot volume, always the file's own volume so no copy is needed. The scanner ignores `.miles-holdback`. Holdback is not backed up (ADR 0006).
- Release sends the original to the Trash and sets `releasedAt` (`holdbackPath` then holds the Trash location). `releaseExpiredHoldbacks` does this for originals past `holdbackUntil`, and the app runs it when a library opens. A root with `releaseImmediately` does it right after each run, and the preview says so. `undoBatch` skips released operations and says the Trash is the last recovery point.
- Undo of a resize sends the resized file to the Trash (never deleted) and only if it is still as Miles left it, then renames the original back and restores the row's hashes. Crash recovery settles pending and undoing moves and resizes from the disk.
- CLI: `root manage|standardize|holdback`, `standardize <root> [--apply]`, `mv`, `rename`, `holdback list|release|expire`. Real-disk check: a 12.7 MB JPEG made from a system HEIC was re-encoded to 1000 px and 140 KB, then undone (the resized copy went to the real Trash) and renamed and undone. The app only runs the expiry on open; the review UI for plans comes with Step 8's UI work.

## Step 8: AI (ADR 0003, 0007, 0010, 0015)
- [x] Verify Foundation Models availability and API on macOS 27
- [x] Provider protocol; Foundation Models, Vision and NaturalLanguage providers
- [x] Layer 3 suggestions into the review queue; optional auto-accept threshold
- [x] Review queue UI; rejected suggestions stay rejected; provider and model recorded
- [x] `image_fingerprint`; perceptual-hash near-duplicate groups (suggestions only)
- [x] Layer 4 (LLM/VLM), off by default per root and per file kind
- [x] Natural-language query translation, showing the generated query first

Notes from Step 8:
- ADR 0015 records the decisions. Migration v7 (schema version 7) adds `root.autoAcceptThreshold`, `root.layer4Kinds` and `image_fingerprint`.
- Foundation Models on macOS 27 (checked against the SDK and on this Mac, where `SystemLanguageModel.default` is available): the system model reports a `vision` capability and takes images as `Attachment(imageURL:)`, so ADR 0003's "text-only" no longer holds and layer 4 captions images directly. The same framework has `PrivateCloudComputeLanguageModel`, which is cloud-hosted: Miles never uses it. `@Generable` structured output works for tags and for queries. Unavailable states (`deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`) are reported by `ai status` and the layer or translation is skipped, not failed.
- `MilesAI` now depends on `MilesCore` (storage, queue and the review queue stay in `MilesCore`; the providers and the job handler are in `MilesAI`). `AIPipeline` is what the app and CLI use: it lists providers, picks the usable ones, and builds handlers and the per-layer version for `enqueueDueJobs(ai:)`. A layer with no usable provider gets no handler and no jobs.
- Real run on a temp library (a HEIC, its JPEG and a 400 px resize, and a text file): Vision gave `subject:` tags (confidence about 0.3 for these photos), NaturalLanguage gave `language:en`, `person:alice`, `place:paris`, `org:apple`, Foundation Models gave `color:`, `shape:`, `pattern:` tags for images, and the three pictures formed one near-duplicate group. Vision confidences are low for abstract pictures, so a high auto-accept threshold will accept little from layer 3.
- The model writes imperfect queries (it confuses `dup:exact` with `dup:near` now and then). The instructions carry the grammar, today's date and the user's vocabulary, one retry feeds the parse error back, and the query is shown first (CLI `ask` prints it before running and `--dry` stops there; the app shows it in an editable field).
- Near-duplicates: 64-bit difference hash, 6-bit threshold, banded buckets to avoid all-pairs comparison. Weak against crops and rotation. Worst case for very many distinct but similar hashes in one bucket is still quadratic in that bucket. Near groups cannot be resolved; `dup:near` finds their files.
- App: a review sheet (accept, reject, accept all at or above a confidence), an Ask sheet, and per-root menu items for layer 4 and the auto-accept threshold. The app is build-checked only; the logic is tested in `AITests` (fake providers, fake fingerprints, generated images for the real hash).
- CLI: `ai status`, `review list|accept|reject|accept-all`, `ask`, `root ai`, `jobs rerun ml|llm`; `scan`, `jobs enqueue` and `jobs run` include the AI layers; `dup scan` and `dup list` include near groups.
- Not in this step: OCR text is not stored or searched (only `content:text` is tagged), no embeddings or semantic search (deferred by ADR 0003), no UI for duplicate groups beyond `dup:near` search, no MLX or Ollama provider.

## Step 9: Portable library polish (ADR 0012)
- [x] Drive-absent handling and reconnect (`LibraryAvailability`, `Library.rootStatuses`; the app reopens the library when its drive mounts, closes it cleanly before its drive unmounts, and rescans roots that return; unmounted roots keep their files)
- [x] Stale lock takeover flow (same-Mac dead process reclaimed silently; other Mac or live process needs the user's confirmation in the app, `--take-over-lock` in the CLI; takeover never overrides the version gate)
- [x] Schema version gating verified across app copies (tests: newer schema refused with nothing touched even with takeover, availability reports it without taking the lock; older databases migrate after a pre-migration backup)
- [x] App copy stored on the drive; how to use it is in [PORTABLE.md](PORTABLE.md)

Notes from Step 9:
- The app copy itself is a manual copy of `Miles.app`; there is no installer or updater. Code signing and Gatekeeper behaviour of a copy opened from a drive on another Mac were not tested here.
- Registering an existing portable library on a second Mac has no UI yet (the registry is per Mac); see PORTABLE.md.

## Risks to check early
- **Scale:** synthetic million-file test for indexing and query speed.
- **Permissions:** Full Disk Access and file-event handling on a real home directory.
- **Foundation Models:** availability and API shape on macOS 27.
- **iCloud placeholders:** how evicted files report size and status in practice.
