# 0011. Thumbnails and iCloud files

- Status: accepted
- Date: 2026-11-06

## Context

The library is browsed as a gallery, and many files may live in iCloud Drive as evicted placeholders. Browsing must not force downloads (ADR 0001). Thumbnails are derived data and can be rebuilt.

## Decision

- Miles keeps a **local thumbnail cache** per library, in several sizes, keyed by file identity.
- Thumbnails are stored as **files** in the library folder, not as database blobs.
- **Miles never downloads a file just to make a thumbnail by default.** Thumbnails are generated when the file is already local, for example at index time, or when the user opens a file and it downloads.
- A thumbnail is **kept after the file is evicted**, so browsing iCloud folders shows thumbnails without fetching anything.
- A file with no thumbnail shows a placeholder icon with a cloud badge. Opening it downloads it on the user's action, then a thumbnail is generated.
- **Optional setting, off by default, per root:** "fetch once to build a thumbnail, then let it evict". Large batches require the user's approval before starting, because they use bandwidth and disk.
- The cache is rebuildable and **excluded from backups** (ADR 0005).

## Consequences

- Browsing remote files is fast and offline-friendly for anything already thumbnailed.
- Files never seen locally have only a placeholder until the user opens them or enables the optional setting.
- The cache can be deleted at any time without data loss, at the cost of regeneration time.
- The optional setting can trigger large downloads, hence the per-root control and batch approval.
