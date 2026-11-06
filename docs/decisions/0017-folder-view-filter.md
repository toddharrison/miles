# 0017. Folder tree and folder view filter

- Status: accepted
- Date: 2026-11-06

## Context

A root can hold many subfolders, and the sidebar showed only the root. The user wants to see the subfolders, and to choose which of them the grid shows. Per-folder managed mode is a separate wish and is not decided here: ADR 0004 makes managed status per root, and `addRoot` refuses a root nested in another.

## Decision

- The sidebar shows each root's folders as a tree, built from the index (folders that hold or have below them a present file), never from the disk.
- Every folder, root included, has a checkbox. Unchecking a folder hides the files directly in it from the grid **and from search**. Checking shows them. A parent's checkbox is checked, unchecked or mixed from the folders below it, and clicking it sets the whole subtree.
- Everything is checked by default, and a folder that appears later is checked.
- The filter is **view only**: it never changes indexing, scanning, tagging, hashing, duplicate detection, thumbnails or any file. It is not an exclusion (`root.exclusions` stops indexing; this does not).
- The filter is remembered per library, as a `folderFilter` row in `library_meta` (the set of unchecked folders), so the view is as the user left it. A missing or unreadable value shows everything.
- The status bar shows "N of M folders" with a Show All button while any folder is unchecked.
- Folder paths are matched by equality, not `LIKE`, so names with `%` or `_` are safe.

## Consequences

- No schema migration: `library_meta` already holds key and value rows.
- Searches and counts take a `FolderFilter`; the empty default keeps CLI and other callers unchanged.
- Saved searches store query text only, so they apply to whatever folders are checked when they run.
- A subfolder hidden by an unchecked parent that gains a new child folder will show that child. Accepted for now.
- Per-folder managed mode needs its own ADR amending 0001 and 0004.
