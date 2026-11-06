# Data model

Conceptual model for the Miles database (SQLite via GRDB, [ADR 0002](decisions/0002-database-sqlite-grdb.md)). This describes entities and rules, not the final schema. Column names and types are settled during implementation and changed only through migrations.

One database belongs to one **library** ([ADR 0012](decisions/0012-libraries-and-portable-mode.md)). Nothing here crosses libraries in v1. The database also records its schema version, and the library folder holds a lock file, the thumbnail cache ([ADR 0011](decisions/0011-thumbnails.md)) and backups.

## Entities

### Locations
- **root**: a directory Miles knows about. Holds path (volume plus relative path for external volumes) and bookmark, mode (`managed` or `unmanaged`, [ADR 0001](decisions/0001-storage-model.md)), exclusions, and an optional image standardization rule ([ADR 0006](decisions/0006-image-standardization.md)).
- **file**: one row per file. Holds root, relative path, volume and file ID, size, modified time, kind, iCloud status, partial hash, full hash (nullable until computed), first seen, last seen, and missing-since.

### Tags ([ADR 0008](decisions/0008-tag-model.md))
- **namespace**: tag namespaces, with one default namespace for flat tags.
- **tag**: a namespaced name, unique per namespace.
- **tag_alias**: maps an alternate name to a canonical tag.
- **tag_implication**: a tag implies another tag.
- **file_tag**: file, tag, source (`user`, `rule`, `ai`), confidence, status (`accepted`, `suggested`, `rejected`), provider and model, created time.
- **tag_rule**: a path or metadata pattern, scoped to a root, mapped to a tag ([ADR 0003](decisions/0003-ai-provider-abstraction.md)).

### Duplicates ([ADR 0007](decisions/0007-duplicate-detection-and-resolution.md))
- **image_fingerprint**: file, perceptual hash, algorithm version.
- **dup_group**: kind (`exact` or `near`) and review status.
- **dup_member**: group, file, similarity.
- **file_link**: original file, derived file, kind (`resize`). Linked files are never reported as duplicates of each other.

### Operations ([ADR 0004](decisions/0004-managed-root-operations.md))
- **operation**: batch, kind (`move`, `rename`, `trash`, `resize`, `clone`), file, from and to path, holdback path, original hash, state, created time, undone time, released time.

### Work
- **job**: kind, file, state, attempts, provider and model, error.

### Search
- **FTS5 index** over file name, path and tags. Document text is not indexed in v1.

## Rules

- **Tags attach to `file`, not to a path.** Moves and renames update the file row, so tags survive. A moved file is re-matched by volume and file ID first, then by content hash.
- **Tags are per file.** Exact duplicates do not share tags automatically. Duplicate resolution offers to merge tags so no copy's tags are lost silently.
- **User tags win.** AI and rule tags never overwrite or remove a `user` tag.
- **Rejected suggestions are kept.** A `rejected` AI tag is not suggested again for that file. Provider and model are stored so suggestions can be re-run when models change.
- **Missing files are marked, not deleted.** A file that disappears gets a missing-since date and is removed only after a grace period, since it may be on an unmounted drive or an evicted iCloud file.
- **`operation` is the only way Miles changes files.** Every move, rename, trash, resize and clone writes an operation row before it runs, and undo reads from it.
- **Hashes live on `file`.** Perceptual fingerprints are separate because they are versioned and optional.
- **Backups** copy this database and a JSON export of tags and rules ([ADR 0005](decisions/0005-backup-of-miles-data.md)).

## Deferred
- Document text extraction and full-text content search.
- Embeddings and semantic search.
- UI for tag aliases and implications (the schema supports them from the start).
