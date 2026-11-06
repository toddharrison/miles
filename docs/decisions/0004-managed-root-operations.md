# 0004. Operations allowed in managed roots, and coexistence with other apps

- Status: accepted, amended by [0006](0006-image-standardization.md) (image re-encoding is now allowed in managed roots under its rules)
- Date: 2026-11-06

## Context

ADR 0001 splits roots into unmanaged (read-only) and managed (Miles may reorganize). The user wants managed roots to treat all file types the same, images included, so files there can be moved and renamed. The constraint is that other native Mac apps, Photos above all, must not break.

## Decision

- In a **managed** root, Miles may move and rename any file type, including images and video, but only through explicit user actions or user-approved suggestions.
- Miles never rewrites the contents of a file. Operations are move, rename, create folders, and send to Trash. (Assumption: confirm if in-place edits such as metadata writing are ever wanted. They are out of scope today.)
- Managed status is **opt-in per root** and never applied to a root implicitly or to a parent of one.
- Roots may not include or sit inside a `.photoslibrary` package (ADR 0001). Other app-owned library packages and bundles (for example Music/Apple TV media libraries, app data folders) are excluded the same way by default.
- Every move, rename, and trash is written to an **operation journal** before it runs, and every operation can be undone. This applies to duplicate resolution too.
- Operations are previewed (a list of old path to new path) before bulk runs.
- **Unmanaged** roots are unchanged: read-only.

## Consequences

- Other apps that reference files by path can still lose track of a file Miles moves in a managed root. This is accepted. It is why managed roots are opt-in, previewed, and undoable, and why app-owned libraries are excluded.
- The journal and undo are required infrastructure and must exist before any managed-root feature ships.
- Bulk operations need preview UI, which adds work.
- Duplicate resolution (trash, replace with an APFS clone) goes through the same journal.
