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

## Status

Design is complete (ADRs 0001–0015). Step 0 of [docs/PLAN.md](docs/PLAN.md) is done: Xcode project and Swift package skeleton, library create and open with a lock and schema gating, a library registry, and root overlap checks. Step 1 is done too: `miles-cli` can add roots, scan them and list files, with moved files re-matched, missing files marked, iCloud placeholders indexed by metadata only, and file-change events plus periodic reconciliation. Step 2 is done as well: namespaced tags with aliases and implications, manual tagging, the ADR 0009 query language compiled to SQL over an FTS5 index, saved searches, and `miles-cli query`. Step 3 is done too: a thumbnail cache in the library folder that never downloads iCloud files, an optional per-root fetch-once setting with batch approval, and the SwiftUI app shell with an AppKit thumbnail grid. Step 4 is done as well: verified snapshots of Miles' own data (daily, before migrations and before dropping a root) with rotation, a JSON export of tags, and a tested restore that migrates older snapshots forward (`miles-cli backup` and `restore`). Step 5 is done too: a durable, throttled job queue that pauses on battery or load, layer 1 metadata tags and layer 2 per-root path rules that re-run without touching user tags (`miles-cli rule` and `jobs`). Step 6 is done as well: an operation journal written before every file change, undo from it, a preview model for bulk actions, staged hashing (size, partial, full) on the job queue, exact duplicate groups, and resolution by Trash, APFS clone or keep-all, chosen by the user each time, with optional tag merge (`miles-cli dup` and `ops`). Step 7 is done too: opt-in managed roots with previewed, journaled, undoable move and rename, per-root image standardization rules (JPEG and HEIC re-encoded to a size, long-edge and quality-floor rule) with originals kept in a per-volume holdback for 30 days by default and released to the Trash early or immediately at the user's choice, and links between an original and its derivative (`miles-cli root manage|standardize|holdback`, `standardize`, `mv`, `rename`, `holdback`). Step 8 is done too: an AI provider protocol with Vision, NaturalLanguage and Apple Foundation Models providers, layer 3 and 4 suggestions into a review queue (accept, reject, auto-accept threshold, rejected stays rejected, layer 4 off by default per root and kind), perceptual-hash near-duplicate groups as suggestions, and plain-language search that shows the generated query first (`miles-cli ai`, `review`, `ask`, `root ai`, and a review sheet and Ask button in the app). The next step is Step 9 (portable library polish). There are no open design questions.
