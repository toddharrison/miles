# Architecture

Short summary of the constraints every change must satisfy. The authority is the ADRs in [decisions/](decisions/). If this file and an ADR disagree, the ADR wins, so fix this file.

## Shape

Xcode project plus a local Swift package: `MilesCore` (logic, no SwiftUI or AppKit), `MilesAI` (providers), `MilesApp` (UI), `miles-cli`. One SQLite database (GRDB) per library. Entities are in [DATA-MODEL.md](DATA-MODEL.md), build order in [PLAN.md](PLAN.md).

## Invariants

**Files are precious (ADR 0001, 0004, 0006, 0007)**
- Unmanaged roots are changed only by explicit, user-initiated, previewed, journaled actions. Miles never acts on them in the background.
- Managed roots are opt-in. Move and rename only through user-approved actions. Image re-encoding only through standardization rules (ADR 0006).
- Miles never deletes files directly. Removal goes to the Trash.
- `.photoslibrary` packages and other app-owned libraries are never indexed or modified.
- Every change to a file is written to the `operation` journal before it runs, and is undoable until its holdback is released. A file is re-verified (local, unchanged, same content hash) just before Miles acts on it.
- Indexing and thumbnail generation never download an iCloud file.

**Data (ADR 0002, 0005, 0012)**
- The database is never in iCloud or any synced folder, and only on a local filesystem.
- Schema changes are GRDB migrations only. An older app refuses a newer database.
- One opener per library (lock file). A missing library location never produces a new empty library.
- Libraries are independent. A root belongs to exactly one library.
- Miles backs up only its own data.

**Tags (ADR 0008, 0010)**
- Tags attach to the file record, not the path, and are per file.
- User tags always win. Rejected suggestions stay rejected. Provider and model are recorded for AI tags.

**AI (ADR 0003, 0010)**
- Everything runs on-device behind the provider protocol. Nothing is sent to a cloud service.
- AI results are suggestions until accepted, unless the user set an auto-accept threshold.

**Search (ADR 0009)**
- One grammar serves the search box, saved searches and natural-language translation. Malformed queries error; they never fall back to loose text search.
