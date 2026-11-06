# Miles

Native macOS booru-style file manager (tags, search, duplicates), Swift/SwiftUI, SQLite via GRDB, local on-device AI. Single user, macOS 27+.

## Read first
1. [README.md](README.md): overview and the decisions table
2. [docs/PLAN.md](docs/PLAN.md): the checklist and current status. Work from here.
3. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): invariants every change must satisfy
4. [docs/decisions/](docs/decisions/): ADRs 0001–0014, the authority on any decision
5. [docs/DATA-MODEL.md](docs/DATA-MODEL.md) and [docs/SECURITY.md](docs/SECURITY.md) as needed

## Rules
- User files are precious. Never delete directly (Trash only), never skip the operation journal, never touch `.photoslibrary` or other app-owned libraries, never download iCloud files while indexing or thumbnailing.
- Do not relitigate accepted ADRs. To change a decision, write a new ADR that supersedes or amends the old one and update the old one's status line. Do not rewrite an accepted ADR's decision.
- Keep README (decisions table), DATA-MODEL.md and PLAN.md in sync in the same commit as the change they describe.
- `MilesCore` must not import SwiftUI or AppKit. All AI goes through the provider protocol and stays on-device.
- Test first where practical. Tests use Swift Testing against temporary directory trees and a fake filesystem for iCloud and drive cases.
- Tick a PLAN.md box only when the task is done and its tests pass.
- Design discussion is done. Implementation starts at PLAN.md Step 0. If something there is unclear or contradicts an ADR, stop and ask rather than guessing.

## Build, test, run
Layout: root `Package.swift` (modules `MilesCore`, `MilesAI`, executable `miles-cli`, tests in `Tests/`), and `Miles.xcodeproj` with the `MilesApp` target in `MilesApp/` depending on the package. The project uses synchronized folders, so new files in `MilesApp/` need no project edits.

- Build the package: `swift build`
- Test the package (Swift Testing): `swift test`; one suite: `swift test --filter LibraryTests`
- CLI: `swift run miles-cli <command>`: `version`, `library create|list|forget`, `root add|remove|exclude|list`, `scan`, `list`, `query`, `tag add|remove|show|list|alias|unalias|imply|unimply`, `thumbs generate|path|fetch|clear`, `root fetch-once`, `search save|list|run|delete`, `rule add|list|remove`, `jobs status|run|enqueue|retry|clear-failed|failed|rerun`, `backup now|list`, `restore list|<snapshot|latest> [--apply]` (see `miles-cli help`). `library create` registers the library in the app's preferences (`app.miles.Miles`), so use `library forget` after trying it
- Million-file scale test: `MILES_SCALE_TESTS=1 swift test --filter ScaleTests/millionFiles`
- Build the app: `xcodebuild -project Miles.xcodeproj -scheme MilesApp -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- Tests use `FakeFileSystem` (`Tests/MilesCoreTests/Support`; `SyntheticFileSystem` for scale) for volumes, iCloud placeholders and moves, and real temp directories (`TempDir`) where SQLite needs a real file. Hold the `LibraryLock` or `Library` you acquire: dropping it releases the lock.

## Workflow notes
- The user usually asks to "commit and continue". Commit docs and code together with a clear message, not part-way through an unverified step.
- Small, reversible steps. Prefer preview and dry-run behavior for anything that touches files.
