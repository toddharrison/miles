# Security and safety invariants

Miles reads and sometimes changes a user's personal files, so the main risk is data loss or exposure. Review changes against these. They restate rules from the ADRs in [decisions/](decisions/).

## Data safety
- No code path deletes a user file directly. Removal is a move to the Trash (ADR 0001).
- Every file-changing code path goes through the operations journal (ADR 0004). Review any new write, move, rename, trash, clone or re-encode for a journal entry and an undo path.
- An unmanaged root is never changed except by an explicit user action (ADR 0007).
- Resolution of duplicates and standardization batches are previewed, and nothing runs without approval (ADR 0006, 0007).
- Holdback originals are not deleted before release or expiry, and release means Trash, not erase (ADR 0006).
- App-owned libraries (`.photoslibrary` and similar) are excluded from indexing and operations (ADR 0001, 0004).

## Privacy
- No file content, file name or metadata leaves the device. No cloud AI provider (ADR 0003).
- Any new provider must run on-device, or it must not be added without a new ADR.
- Logs must not contain file contents. Paths should be kept out of any exported diagnostics by default.

## Integrity
- Database migrations are tested forward from every released schema, and a backup is taken first (ADR 0005, 0012).
- Restore is tested, including restoring an older snapshot (ADR 0005).
- The lock file prevents two openers on one library (ADR 0012).
- Library locations in iCloud or synced folders, or on network filesystems, are refused (ADR 0002, 0012).

## Local access
- The app is non-sandboxed and needs Full Disk Access (ADR 0013, README). Treat that access as sensitive: read only the roots the user added, and never index outside them.
- Do not follow symlinks out of a root without the user's choice.
- Query parsing is a real grammar compiled to parameterized SQL, never string-built SQL (ADR 0009).
