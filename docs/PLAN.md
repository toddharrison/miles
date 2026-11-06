# Implementation plan

Structure and target are in [ADR 0013](decisions/0013-project-structure-and-deployment-target.md). Invariants every step must respect are in [ARCHITECTURE.md](ARCHITECTURE.md). What Miles can do today is summarized in the [README](../README.md); the history of how each part was built is in git.

**How to use this file:** it lists only work that is not done. Work top to bottom. Tick a box only when the task is done and its tests pass, and remove it (with its notes) once it has landed and the README covers it. When a task changes a decision, write or supersede an ADR first. Update the README, [DATA-MODEL.md](DATA-MODEL.md) and this file in the same commit as the code they describe.

**Status:** design complete (ADRs 0001–0017). Steps 0 to 9 and section A are implemented and removed from this file. What remains is below, mostly app UI.

## Modules

| Module | Responsibility |
|---|---|
| `MilesCore` | Database and migrations (GRDB), library registry, lock and version gating, scanner and indexer, hashing, query parser to SQL, tag model and rules, duplicates, operations journal and undo, thumbnails, backup, job queue |
| `MilesAI` | Provider protocol and default providers (Foundation Models, Vision, NaturalLanguage). MLX and Ollama are later, separate providers. |
| `MilesApp` | SwiftUI app, AppKit for the thumbnail grid |
| `miles-cli` | Every capability without the UI |

## Remaining work

Reviewed against the code on 2026-11-06. The library (`MilesCore`, `MilesAI`) and `miles-cli` cover every capability in the README. The main gap is the app: `MilesApp` is about 900 lines and covers daily use (browse, search, tag, saved searches, file actions, progress) but not the operations in B and C, which are reachable only from the CLI. Work in the order below; each group is independently shippable. Add or amend an ADR first for anything that changes a decision.

### B. App: operations that change files
- [ ] Duplicates view: exact groups and `dup:near` suggestions, preview, choose Trash, clone or keep each time, optional tag merge
- [ ] Operations journal view with undo per batch, and the holdback list with early release
- [ ] Per-folder managed mode: mark a subfolder managed inside an unmanaged root (needs an ADR amending 0001 and 0004; `addRoot` refuses nested roots today). The folder tree and its view filter are done (ADR 0017)
- [ ] Managed roots: toggle managed mode, move and rename with preview, standardization rule editor and preview
- [ ] Preview sheet shared by all bulk actions (counts, skips with reasons, bytes saved) before apply

### C. App: setup and safety
- [ ] Backup: show last snapshot, back up now, restore from a list (restore needs the library closed)
- [ ] Rules and tag management: per-root folder rules, aliases, implications
- [ ] Per-root settings sheet gathering fetch-once, layer 4, auto-accept, exclusions, holdback days (today a context menu)
- [ ] Register an existing portable library on a second Mac (the registry is per Mac; see [PORTABLE.md](PORTABLE.md))
- [ ] AI availability shown in the app, with the reason when unavailable

### D. Core features not built
- [ ] `created:` and `sort:created`: creation-date column (scanner and `FileSystem` change, with a migration)
- [ ] Layer 2 rules that match file metadata, not only folders
- [ ] Video and PDF thumbnails through a Quick Look `ThumbnailRenderer`
- [ ] Image standardization format change (PNG to JPEG)
- [ ] Case-only renames (refused today on case-insensitive volumes)
- [ ] Moves between volumes (refused today)
- [ ] Stable duplicate group ids across a refresh
- [ ] Near-duplicate matching robust to crops and rotation; bounded worst case for large similar-hash buckets
- [ ] Decide whether undoing a duplicate resolution should also undo its tag merge (ADR if yes)

### E. Deferred past v1 (ADRs already say so)
- [ ] OCR and document text stored and searched
- [ ] Embeddings, semantic search and `similar:` (ADR 0003, 0009)
- [ ] MLX and Ollama providers behind the provider protocol
- [ ] Face identification (separate decision, ADR 0010)

### F. Verification and release
- [ ] UI-level checks for the app (grid, review sheet, Ask sheet, takeover and fetch prompts); today it is build- and launch-checked only
- [ ] Full Disk Access and file-event handling on a real home directory
- [ ] iCloud placeholders: how evicted files report size and status in practice (tests use the fake filesystem)
- [ ] Code signing, notarization and Gatekeeper behaviour of an app copy opened from a drive on another Mac
- [ ] Installer or updater for the app copy on the drive (a manual copy of `Miles.app` today)
- [ ] Million-file scale test re-run after any schema or query change

## Risks
- **Foundation Models:** the API and availability can change between macOS 27 point releases; `ai status` reports it, and layers skip rather than fail when it is unavailable.
- **Vision confidence:** layer 3 confidences are low for abstract images, so a high auto-accept threshold accepts little.
