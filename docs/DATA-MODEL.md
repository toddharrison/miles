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
- **namespace**: tag namespaces, with one default namespace (`general`) for flat tags. A namespace named like a query filter key is refused ([ADR 0009](decisions/0009-query-syntax.md)); so is a flat tag named `tagged`, which is a query keyword.
- **tag**: a namespaced name, unique per namespace. Names are lowercased, inner whitespace becomes `_`, and `( ) " * ~ :` are not allowed in them.
- **tag_alias**: maps an alternate name (unique per namespace) to a canonical tag. A name that is already a real tag cannot become an alias. Adding a tag by an alias name applies the canonical tag.
- **tag_implication**: a tag implies another tag. Searches follow implications transitively; cycles are harmless.
- **file_tag**: one row per file and tag: source (`user`, `rule`, `ai`), confidence, status (`accepted`, `suggested`, `rejected`), provider and model, created time. Only `accepted` rows match a tag search. A user adding a tag turns any existing row for it into an accepted user row. A user removing a user tag deletes the row; removing a rule or AI tag marks it `rejected`.
- **tag_rule**: a path or metadata pattern, scoped to a root, mapped to a tag ([ADR 0003](decisions/0003-ai-provider-abstraction.md)).

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
- **job**: kind, file, state, attempts, provider and model, error.

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
- **Backups** copy this database and a JSON export of tags and rules ([ADR 0005](decisions/0005-backup-of-miles-data.md)).

## Deferred
- Document text extraction and full-text content search.
- Embeddings and semantic search.
- UI for tag aliases and implications (the schema supports them from the start).
