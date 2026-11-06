# 0007. Duplicate detection and resolution

- Status: accepted, amended by [0015](0015-ai-layers-and-fingerprints.md) (difference hash, 6-bit threshold)
- Date: 2026-11-06
- Amends: [0001](0001-storage-model.md) (unmanaged roots are read-only except for explicit user-initiated actions)

## Context

Finding and managing duplicates is a core goal. Most of the user's files live in place (unmanaged roots), which ADR 0001 made strictly read-only, so duplicates there could be reported but never resolved. The user also wants to detect near-duplicate images, and wants to choose the resolution action every time.

## Decision

**Detection (exact)**, cheapest first, on the background queue (ADR 0003):
1. Size match. A unique size cannot be an exact duplicate.
2. Partial hash of the start, middle and end of the file.
3. Full content hash, computed lazily and cached. This is the same hash used for file identity (ADR 0001).

A file is reported as an exact duplicate only when its full hash matches. iCloud placeholders are skipped until local.

**Detection (near-duplicates)**
- Near-duplicate detection for **images is in v1**, using perceptual hashing to catch resizes and re-encodes. Other types (for example similar documents) may follow later.
- Near-duplicates are **suggestions only**, shown as groups with a similarity indication. They are never resolved automatically.
- An original and its resized derivative from ADR 0006 are linked and are never reported as duplicates of each other.

**Resolution**
- **The user chooses the action every time**, per group or per batch. Miles never picks an action by default and never resolves anything automatically.
- Available actions: move extras to the Trash, replace extras with an APFS clone (`clonefile`) of the kept copy (same volume only; both paths stay valid and space is reclaimed), or keep all and mark the group as reviewed.
- Miles may *suggest* which copy to keep (for example oldest, shortest path, most tags, preferred root). The user approves.
- Every resolution is previewed, journaled and undoable (ADR 0004). Nothing is deleted directly, only sent to the Trash (ADR 0001).
- Photos libraries and other app-owned libraries are excluded (ADR 0001, 0004).

**Unmanaged roots**
- Unmanaged roots remain read-only for Miles' own initiative. They may be changed only by an explicit, user-initiated, previewed, journaled action such as duplicate resolution. Miles never changes an unmanaged root in the background or on its own.

## Consequences

- Duplicate cleanup works where most of the user's files actually are.
- The word "unmanaged" now means "Miles never acts on its own", not "never writes". Any code path that changes an unmanaged root must be a user-initiated action that goes through the journal.
- Full hashing of large libraries is expensive. Staged hashing and caching keep it manageable but the first scan will take time.
- Perceptual hashing adds a table for image fingerprints and a similarity search. The threshold and algorithm are implementation details, to be settled when building.
- Cloning only reclaims space on the same APFS volume. The UI must say so before offering it.
