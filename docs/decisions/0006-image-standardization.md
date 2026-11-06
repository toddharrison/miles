# 0006. Image standardization in managed roots

- Status: accepted
- Date: 2026-11-06
- Amends: [0004](0004-managed-root-operations.md) (the rule that Miles never rewrites file contents)

## Context

ADR 0004 allows moving and renaming in managed roots and forbids rewriting contents. The user wants managed roots to be able to standardize images, for example a maximum file size of 5 MB, which requires a lossy rewrite. Photos libraries and other app-owned libraries stay excluded (ADR 0001, 0004).

Options considered:

1. **Replace in place, keep the original in a holdback.** Undo works and the root actually becomes standardized.
2. **Write a derivative beside the original.** Safest, but standardizes nothing and saves no space.
3. **Move originals to an archive root.** Safest for originals, but needs extra setup.

## Decision

Option 1. Image standardization is an allowed operation in managed roots, under these rules.

**Scope**
- Images only. Video and other media are out of scope and would need a new decision.
- Opt-in per managed root, driven by an explicit rule. Nothing runs on a root that has not enabled it.
- Applies only to formats Miles can re-encode safely, starting with JPEG and HEIC. RAW, animated images and files already within the rule are skipped. Changing format (for example PNG to JPEG) is a separate, explicit rule option.

**Rule constraints (combinable)**
- Maximum file size.
- Maximum long-edge dimension.
- A quality floor, below which Miles will not go.
- Metadata policy: preserve orientation, EXIF and color profile by default, with an option to strip location data.
- Any combination of these may be set. If a file cannot meet the rule without breaking the quality floor, it is skipped and reported, never degraded further.

**Safety**
- Every run is previewed first: per file, old size, new size and resulting dimensions or quality. Nothing is applied without approval.
- The original is moved to a Miles holdback area, not deleted. Holdback retention defaults to **30 days** and is configurable. After retention the original goes to the Trash (ADR 0001, never deleted directly).
- The user may **release originals early**, per file, per batch, or as a default for a root (including immediately after a run). Early release sends the original to the Trash, same as expiry. Miles' undo for that operation ends at release, and the Trash is the last recovery point. Releasing is always a user choice and the preview says so when it is the configured default.
- The operation is written to the operation journal and can be undone until the holdback expires (ADR 0004).
- Re-running is idempotent.

**Identity**
- The derivative has a new content hash. Miles records a link between the original and the derivative so tags carry over and the original is not treated as a duplicate of its own resize.

## Consequences

- Image quality loss is real and permanent once the holdback expires. This is accepted and is why previews, quality floors and the holdback exist.
- The holdback uses extra disk space temporarily and is outside the backup scope of ADR 0005. It is short-lived and not backed up.
- The journal must store enough to restore the original (holdback location and original hash).
- Duplicate detection must understand original/derivative links.
- Encoding choices (algorithm for meeting size and dimension constraints together, quality steps) are implementation details to settle when building, within the rules above.
