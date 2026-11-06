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
| Storage modes | Both, chosen per directory by the user: **managed** (Miles owns the layout) and **unmanaged** (indexed in place, files never moved). Unmanaged/in-place is the primary expected use. |
| Tags | Namespaced tags (`namespace:value`); un-namespaced tags are flat and use a default namespace. |
| Tagging | Automated, with user override and user-specified tags. |
| Search | Booru-style query syntax. |
| Users | Single user, local. May index iCloud Drive directories. |
| Database | SQLite via GRDB. Stored in `~/Library/Application Support`, never in iCloud. |
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
| Backup | Automatic, Miles' own data only (database, tags/rules export, journal), local only, rotated, with tested restore. Miles does not back up user files. |

Decisions are recorded as ADRs in [docs/decisions/](docs/decisions/).

## Open questions

- **Automated tagging sources:** exact mix of Vision, NaturalLanguage, path-derived rules, file metadata, and optional VLM captions.
- **Duplicates:** detection pipeline and resolution actions (trash, APFS clone, etc.).
- **Query syntax:** exact operators (`-tag`, `OR`, `type:`, `size:`, etc.).
