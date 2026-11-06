# Miles

Miles is a booru-style file management system for Mac, built as a native application. It helps a single user organize personal files (documents, writing, ideas, images, video, game files), find them by tag, and find and manage duplicates.

## Goals

- Organize a normal user's personal files; libraries may get large.
- Support any file type.
- Tag-based browsing and search in the style of a booru.
- Find and manage duplicate files.
- Coexist with other native Mac apps. Files mostly stay where they are, so Photos and similar apps are not broken.

## Decisions

| Area | Decision |
|---|---|
| Platform | Native macOS app, Swift. SwiftUI primarily, AppKit where needed (e.g. large thumbnail grids). |
| File types | Any file type. |
| Storage modes | Both, chosen per directory by the user: **managed** (Miles owns the layout) and **unmanaged** (indexed in place; Miles never acts on its own, only on explicit user actions such as duplicate resolution). Unmanaged/in-place is the primary expected use. |
| Tags | Namespaced tags (`namespace:value`); un-namespaced tags are flat and use a default namespace. |
| Tagging | Automated, with user override and user-specified tags. |
| Search | Booru-style query syntax: space is AND, `-` excludes, `or` and parentheses for OR, `key:value` filters, `~tag` for literal match. Filter keys are reserved. Natural-language search translates to this syntax and shows the query first. See ADR 0009. |
| Users | Single user, local. May index iCloud Drive directories. |
| Database | SQLite via GRDB, one database per library. Default library in `~/Library/Application Support`; portable libraries elsewhere (ADR 0012). Never in iCloud. |
| Sandboxing | Non-sandboxed, direct distribution (Full Disk Access). Revisit only if App Store becomes a goal. |
| Tag interoperability | Tags live in the Miles database only for now. No Finder tag / xattr write-back yet. |
| iCloud files | Evicted (dataless) files are indexed by metadata only; indexing never forces a download. Content hashing and auto-tagging wait until the file is local. |
| File identity | Path plus file ID/bookmark, with lazily computed content hash, so moves and renames keep tags. |
| Miles data sync | Out of scope for v1 (local only). |
| AI | Local/on-device only; nothing leaves the Mac. Behind a provider protocol. Default: Apple Foundation Models + Vision/NaturalLanguage. Optional backends: MLX, Ollama/llama.cpp. |
| AI tag provenance | Every tag records its source (`user`, `rule`, `ai`) and confidence. AI tags are suggestions in a review queue; user tags always win. |
| Background work | Throttled, resumable job queue for indexing, hashing and AI; skips iCloud placeholders. |
| v1 scope | Tags first. Semantic search (embeddings) is deferred past v1. |
| Target hardware | Development/primary target: Apple M5, 48 GB RAM, macOS 27.0.1. |
| Photos library | `.photoslibrary` packages are never indexed or modified. |
| Deletion | Miles never deletes files directly; removal goes to the Trash. |
| Managed-root operations | Any file type (images included) may be moved/renamed, only by explicit or user-approved action, previewed, journaled, and undoable. File contents are not rewritten except by image standardization (below). App-owned libraries (Photos etc.) are excluded. |
| Image standardization | Opt-in per managed root, images only (JPEG/HEIC first). Rules combine max file size, max long edge, and a quality floor; metadata preserved by default. Previewed, journaled, undoable. Originals held 30 days (configurable) before going to the Trash, or released to the Trash early/immediately at the user's choice. Video is out of scope for now. |
| Duplicates | Exact: size, then partial hash, then full hash. Near-duplicate image detection (perceptual hash) in v1, as suggestions only. The user chooses the resolution (Trash, APFS clone, or keep) every time; previewed, journaled, undoable. Unmanaged roots may be changed only by explicit user-initiated actions like this; Miles never acts on them on its own. |
| Backup | Automatic, Miles' own data only (database, tags/rules export, journal), local only, rotated, with tested restore. Miles does not back up user files. A portable library's backups live in its own folder on the drive; backing up the drive is the user's responsibility. |
| Tagging sources | Layered: file metadata and path rules auto-apply; Vision/NaturalLanguage and optional LLM/VLM go to the review queue (optional auto-accept threshold). LLM layer is off by default per root. No prohibition on face identification; not in v1. Layer 1 tags are `kind:`, `year:`, `resolution:`, `length:` (ADR 0014). Layer 3 is Vision and NaturalLanguage, layer 4 is Apple's on-device language model (never the cloud one), with a per-root auto-accept threshold (ADR 0015). See ADR 0010. |
| Thumbnails | Local cache of files in the library folder, kept after iCloud eviction, never downloading just for a thumbnail by default. Optional per-root "fetch once" setting (off by default, batch approval). Excluded from backups. See ADR 0011. |
| Libraries | Several independent libraries (v1: no cross-library features). Default library in Application Support; portable library in a chosen folder, e.g. an external drive, never in iCloud, local filesystem only. A root belongs to one library. Lock file, schema version gating, volume-relative paths. A macOS copy of the app may travel on the drive; v1 is macOS only. Image holdback is per volume. See ADR 0012. |
| Project structure | Xcode project with a local Swift package (`MilesCore`, `MilesAI`), the `MilesApp` target, and a `miles-cli` target. Minimum deployment target macOS 27. See ADR 0013. |
| Tag model | Tags are per file (not shared across duplicates; duplicate resolution offers tag merge). Aliases and implications are in the schema from the start; their UI is deferred. v1 search covers file name, path and tags; document text and semantic search are deferred. |

Decisions are recorded as ADRs in [docs/decisions/](docs/decisions/). The conceptual data model is in [docs/DATA-MODEL.md](docs/DATA-MODEL.md), the build checklist in [docs/PLAN.md](docs/PLAN.md), the invariants in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/SECURITY.md](docs/SECURITY.md), and guidance for working in the repo in [CLAUDE.md](CLAUDE.md).

## Capabilities

What works today (CLI `miles-cli` covers all of it; the SwiftUI app covers browsing, search, tagging, saved searches, review and ask):

- **Libraries.** Several independent libraries, each with its own SQLite database. A portable library can live on an external drive: it is reported (never recreated) while the drive is unplugged, reopens when it mounts, takes over a stale lock only on confirmation, and refuses a newer schema version. See [docs/PORTABLE.md](docs/PORTABLE.md).
- **Indexing.** Roots are indexed in place. Moved and renamed files keep their identity, missing files are marked and removed after a grace period, file-change events plus periodic reconciliation keep the index current, and exclusions apply per root. iCloud placeholders are indexed by metadata only and never downloaded. Tested at a million files.
- **Tags and search.** Namespaced tags with aliases and implications, manual tagging, saved searches, and the booru-style query language over an FTS5 index of names, paths and tags. Plain-language questions are translated to that syntax and the query is shown first.
- **Automatic tagging.** File metadata tags (`kind:`, `year:`, `resolution:`, `length:`) and per-root folder rules apply automatically and re-run without touching user tags. Vision, NaturalLanguage and Apple's on-device language model suggest tags into a review queue (accept, reject, accept all, optional auto-accept threshold; rejected stays rejected). The language model layer is off by default per root and file kind. Everything stays on the Mac.
- **Thumbnails.** A cache in the library folder, made only when a grid cell comes into view (nothing in advance, and scrolling past a cell cancels its request), that survives iCloud eviction and never downloads a file just for a thumbnail, with an optional per-root fetch-once setting behind batch approval.
- **Duplicates.** Exact groups (size, partial hash, full hash) and near-duplicate image groups (perceptual hash, suggestions only). Resolution is chosen each time (Trash, APFS clone or keep all), previewed, journaled and undoable, with optional tag merge.
- **Managed roots.** Opt-in per root: previewed, journaled, undoable move and rename, and image standardization (max size, long edge and quality floor for JPEG and HEIC) that keeps originals in a per-volume holdback for 30 days by default before the Trash.
- **Safety.** Files are only ever sent to the Trash, every change is journaled first and can be undone, and crashes are recovered from the journal.
- **Background work.** A throttled, resumable job queue (hashing, tagging, AI) that pauses on battery or load.
- **Backup and restore.** Verified, rotated snapshots of Miles' own data (daily, before migrations and bulk operations) and a JSON export of tags and rules; restore migrates older snapshots forward. User files are not backed up.

The app is the thinnest layer: it browses with multi-selection and keyboard navigation, searches (parser errors inline, search history, tag browser, saved searches in the sidebar), shows and edits tags by hand in an inspector, opens, reveals and previews files (images shown and video played in the inspector, Quick Look; neither downloads from iCloud unless you ask), shows background tagging, AI and hashing progress with pause and resume, scans, reviews AI suggestions and asks plain-language questions, but duplicates, the journal and undo, managed-root operations, backup and restore, and rules and aliases are CLI-only for now. Also not built: video and PDF thumbnails, document text and semantic search, MLX and Ollama providers. The full list is in [docs/PLAN.md](docs/PLAN.md).

## Status

Design is complete (ADRs 0001–0015) and every step of the original plan is implemented. [docs/PLAN.md](docs/PLAN.md) now lists only known gaps and deferred work. There are no open design questions.
