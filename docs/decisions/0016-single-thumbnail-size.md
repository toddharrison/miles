# 0016. One thumbnail size

- Status: accepted
- Date: 2026-11-06
- Amends: [0011](0011-thumbnails.md) (thumbnails are kept "in several sizes")

## Context

Miles cached 128 and 256 pixel thumbnails (a 512 size was already dropped). The grid, the not-downloaded preview and the review queue all read the 256 size; nothing read the 128 size, and the CLI was the only way to reach it. It cost disk and render time for every image.

## Decision

Miles keeps one thumbnail size, 256 pixels on the longest edge. The 128 folder is removed from existing caches when a library opens, as the 512 one was. Thumbnails already made at 256 stay valid. Everything else in ADR 0011 stands.

## Consequences

- Less disk use and less work per thumbnail.
- A smaller grid cell would use the 256 image scaled down. A larger size can be added later with a new ADR if the grid cells grow.
