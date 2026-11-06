# Data model

Conceptual model for the Miles database (SQLite via GRDB, [ADR 0002](decisions/0002-database-sqlite-grdb.md)). This describes entities and rules, not the final schema. Column names and types are settled during implementation and changed only through migrations.

One database belongs to one **library** ([ADR 0012](decisions/0012-libraries-and-portable-mode.md)). Nothing here crosses libraries in v1. The database also records its schema version, and the library folder holds a lock file, the thumbnail cache ([ADR 0011](decisions/0011-thumbnails.md)) and backups.

## Entities

### Library
- **library_meta**: key and value rows: `schema_version` (an older app refuses a higher value, ADR 0012), `library_id`, `created_at`. GRDB's own `grdb_migrations` table tracks applied migrations, and an unknown migration there is also refused.

### Locations
- **root**: a directory Miles knows about. Holds volume ID plus path relative to the volume's mount point (always, not only for external volumes; the boot volume mounts at `/`) and bookmark, mode (`managed` or `unmanaged`, [ADR 0001](decisions/0001-storage-model.md)), exclusions (a JSON array of lowercase patterns: a bare name matches any folder or file of that name, a path with `/` matches that path relative to the root; app-owned library packages are always excluded on top), an optional image standardization rule ([ADR 0006](decisions/0006-image-standardization.md)), and `fetchOnce` (off by default: download evicted images once to build thumbnails, [ADR 0011](decisions/0011-thumbnails.md)).
- **file**: one row per file. Holds root, relative path, volume and file ID, size, modified time, kind (`image`, `video`, `audio`, `document`, `text`, `archive`, `other`, from the extension), iCloud status (`local` or `dataless`), partial hash, full hash (nullable until computed), first seen, last seen, and missing-since.

### Tags ([ADR 0008](decisions/0008-tag-model.md))
- **namespace**: tag namespaces, with one default namespace (`general`) for flat tags. `isSystem` marks a namespace the automated layers write to (`kind`, `year`, `resolution`, `length`, and any a rule names); it is a label only, and the user may still add tags in it ([ADR 0014](decisions/0014-layer-1-tag-namespaces.md)). A namespace named like a query filter key is refused ([ADR 0009](decisions/0009-query-syntax.md)); so is a flat tag named `tagged`, which is a query keyword.
- **tag**: a namespaced name, unique per namespace. Names are lowercased, inner whitespace becomes `_`, and `( ) " * ~ :` are not allowed in them.
- **tag_alias**: maps an alternate name (unique per namespace) to a canonical tag. A name that is already a real tag cannot become an alias. Adding a tag by an alias name applies the canonical tag.
- **tag_implication**: a tag implies another tag. Searches follow implications transitively; cycles are harmless.
- **file_tag**: one row per file and tag: source (`user`, `rule`, `ai`), confidence, status (`accepted`, `suggested`, `rejected`), provider and model, created time, and `layer` (the tagging layer that made a `rule` or `ai` row; null for user rows). Only `accepted` rows match a tag search. A user adding a tag turns any existing row for it into an accepted user row. A user removing a user tag deletes the row; removing a rule or AI tag marks it `rejected`.
- **tag_rule**: a folder pattern, scoped to a root, mapped to a tag template ([ADR 0010](decisions/0010-tagging-sources.md), layer 2). Metadata-pattern rules are not built. Each rule change bumps `root.ruleRevision`.
- **file_layer_run**: per file and layer, the layer's version, the file's size, modified time and path, and whether content was readable, when the layer last ran. Any difference makes the layer due again.

### Duplicates ([ADR 0007](decisions/0007-duplicate-detection-and-resolution.md))
- **image_fingerprint**: file, perceptual hash, algorithm version.
- **dup_group**: kind (`exact` or `near`) and review status.
- **dup_member**: group, file, similarity.
- **file_link**: original file, derived file, kind (`resize`). Linked files are never reported as duplicates of each other.

### Operations ([ADR 0004](decisions/0004-managed-root-operations.md))
- **operation**: batch, kind (`move`, `rename`, `trash`, `resize`, `clone`), file, from and to path, holdback path, original hash, state, created time, undone time, released time.

### Thumbnails ([ADR 0011](decisions/0011-thumbnails.md))
- **thumbnail**: one row per file whose thumbnails exist on disk, with the file size and modified time they were made from, and the generated time. The images are files in `thumbnails/<pixels>/` in the library folder (128, 256 and 512), named by `file.id`. The rows and files are derived data, rebuildable and excluded from backups.

### Work
- **job**: kind, file, state (`queued`, `running`, `failed`), attempts, provider and model, error, not-before time. At most one queued or running job per kind and file. A finished job is deleted.

### Search
- **file_fts**: FTS5 table over file name, path and accepted tags, with `file.id` as rowid, kept in step by triggers on `file` and `file_tag`. A quoted string in a query matches the name and path columns (the last word as a prefix); the tags column is indexed for later use. Document text is not indexed in v1.
- **saved_search**: name and query string. Saved searches store the text, so they follow later alias and implication changes.

## Rules

- **Tags attach to `file`, not to a path.** Moves and renames update the file row, so tags survive. A moved file is re-matched by volume and file ID first, then by content hash.
- **Tags are per file.** Exact duplicates do not share tags automatically. Duplicate resolution offers to merge tags so no copy's tags are lost silently.
- **User tags win.** AI and rule tags never overwrite or remove a `user` tag.
- **Rejected suggestions are kept.** A `rejected` AI tag is not suggested again for that file. Provider and model are stored so suggestions can be re-run when models change.
- **Missing files are marked, not deleted.** A file that disappears gets a missing-since date and is removed only after a grace period (30 days by default), since it may be on an unmounted drive or an evicted iCloud file. A root whose drive is unmounted or whose folder is gone is reported unavailable and nothing in it is marked. Files under a directory the scanner could not read (or that is an iCloud placeholder) are left as they were.
- **Scanning reads metadata only.** Symbolic links, `.DS_Store` and AppleDouble files are not indexed, and other volumes mounted inside a root are not entered. A file whose size, modified time or file ID changed has its hashes cleared. A file seen at its old path again is no longer missing. A new path is matched to an unseen row whose old path is gone by volume and file ID, then by full hash (only when exactly one such row has that hash); the row keeps its identity, so tags survive.
- **`operation` is the only way Miles changes files.** Every move, rename, trash, resize and clone writes an operation row before it runs, and undo reads from it.
- **Hashes live on `file`.** Perceptual fingerprints are separate because they are versioned and optional.
- **Query semantics** ([ADR 0009](decisions/0009-query-syntax.md)): missing files are hidden unless the query has a `missing:` filter. `source:` and `status:` terms ANDed together describe the same `file_tag` row. `size:` units are decimal (1 kb = 1000 bytes). A `date:` value of `2024`, `2024-05` or `2024-05-31` covers that whole period in the local time zone. `created:` and `dup:near` are not available yet (no creation date or fingerprints indexed).
- **Thumbnails** are made only for local files, after a live metadata check, and never by downloading. A thumbnail outlives the file's eviction. It is regenerated when the file's size or modified time differs from the recorded ones. Placeholders show a kind icon with a cloud badge. A download happens only when the user opens a file, or in an approved fetch-once batch (over 25 files or 250 MB needs approval).
- **Backups** copy this database and a JSON export of tags and rules ([ADR 0005](decisions/0005-backup-of-miles-data.md)). They live in `backups/` in the library folder (so a portable library carries them on its drive), as `snapshot-<UTC time>-v<schema>-<kind>.sqlite`, with a `.json` export of the same name for scheduled and manual snapshots.
  - Snapshots use `VACUUM INTO` into a `.partial` file, then `PRAGMA integrity_check`; only a verified copy gets its final name. A failure is reported (the app shows it) and nothing is left behind.
  - Kinds: `scheduled` (when the newest is over 24 hours old, checked when the library opens), `manual`, `pre-migration` (taken when opening a library with pending migrations; if it fails, nothing is migrated), `pre-bulk` (before dropping a root that has file records, and before later bulk operations; one is reused for 10 minutes), `pre-restore`.
  - Rotation: of the scheduled snapshots, the newest of each of the last 7 days and of the last 4 weeks that have one; the newest 5 of each safety kind; manual snapshots are never rotated.
  - The export (format version 1) holds namespaces, tags, aliases, implications, saved searches, `file_tag` rows identified by root volume, root path and file path (never row ids), and `tag_rule` rows.
  - **Restore** needs the library closed. The snapshot is verified, copied beside the database, migrated forward, verified again, then swapped in. A snapshot of a newer schema or of another library is refused. The database it replaces is kept as a `pre-restore` snapshot, or as a raw `damaged-<time>.sqlite` copy when it is unreadable. The thumbnail cache is cleared (files are named by `file.id`, which a rollback can reuse) and rebuilds on the next run. Run a scan afterwards, since the index may differ from the disk.

- **Jobs** ([ADR 0003](decisions/0003-ai-provider-abstraction.md)) run one at a time, with a short pause between them, and the queue claims nothing while the Mac is on battery, in Low Power Mode, hot or busy. State lives in the table: a job left `running` by a quit goes back in line when the queue starts, a failed attempt retries after a growing delay, and after 3 attempts the job stays `failed` until the user retries or clears it. Deleting a file row deletes its jobs.
- **Tagging layers** ([ADR 0010](decisions/0010-tagging-sources.md), [ADR 0014](decisions/0014-layer-1-tag-namespaces.md)). Layer 1 (`kind:`, `year:` from the modified time, `resolution:` and `length:` from content) and layer 2 (path rules) write `rule` rows with status `accepted`. A layer run makes its own accepted rows match the wanted set and touches nothing else: user rows, other layers' rows and rejected rows stay, and a rejected tag is not applied again. Content is read only for local files after a live metadata check; a placeholder gets the index-derived tags only and is run again once local. Files are queued after a scan, or when a rule changes, if their last run is missing or differs (stale); `rerunLayer` forces it.
  - A path rule's pattern matches the start of a file's folder path relative to its root, case-insensitively: `*` inside a segment is captured, `**` as a segment matches any number of folders, and the tag template inserts captures with `{1}`, `{2}`. A capture that makes no valid tag name is skipped. Root-level files have no folders, so no rule matches them.
- **Export** also carries `isSystem` and each `file_tag` row's `layer`.

## Deferred
- Document text extraction and full-text content search.
- Embeddings and semantic search.
- UI for tag aliases and implications (the schema supports them from the start).
