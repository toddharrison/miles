# 0001. Managed and unmanaged directories

- Status: accepted
- Date: 2026-11-06

## Context

Miles organizes a single user's personal files of any type (documents, writing, images, video, game files), possibly in iCloud Drive. The primary goal is organization without breaking other native Mac apps such as Photos, so most files must stay where they are. Some users or folders may still want Miles to own the layout.

Options considered:

1. **Managed only**: Miles copies or moves files into its own library. Simple identity and layout, but it breaks other apps' references and doubles disk use. Rejected as the only mode.
2. **Unmanaged only**: Miles indexes files in place. Safe, but offers no way to have Miles organize files.
3. **Both, chosen per directory**: the user decides per root directory.

## Decision

Each root directory Miles knows about is either **unmanaged** or **managed**, chosen by the user when it is added.

- **Unmanaged (default):** Miles only reads. It never moves, renames, or rewrites files or their metadata. Tags and everything else live in the Miles database.
- **Managed:** Miles may move and rename files within that root, only through explicit user actions or user-approved suggestions.
- File identity is path plus file ID/bookmark, with a lazily computed content hash, so external moves and renames can be re-matched without losing tags.
- Photos libraries (`.photoslibrary` packages) are never indexed or modified.
- Miles never deletes files directly. Removal goes to the Trash.

## Consequences

- Safe by default: adding a folder cannot change it.
- Every feature must state how it behaves in each mode, and any write path must check the mode.
- Files changed outside Miles require re-matching and rescanning (file system events plus periodic reconciliation).
- Tags are not visible to Finder or Spotlight (no write-back for now), so Miles is the only way to search by tag. Accepted for now.
- iCloud placeholder (dataless) files are indexed by metadata only, and indexing never forces a download.
