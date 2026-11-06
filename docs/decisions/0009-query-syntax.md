# 0009. Query syntax

- Status: accepted
- Date: 2026-11-06

## Context

Search is booru-style (README). The syntax shapes query compilation (ADR 0002), the FTS index, saved searches, and the UI. Tags support namespaces, aliases and implications (ADR 0008).

## Decision

**Core grammar**
- Terms are separated by spaces, and a space means AND.
- `-term` excludes. `a or b` means either. Parentheses group: `(a or b) c`.
- `tag` is a flat tag in the default namespace. `ns:value` is a namespaced tag.
- `*` is a wildcard in tag names (`ns:*`, `foo*`).
- A quoted string matches file name or path text.

**Filters** (`key:value`)
- `type:`, `ext:`
- `size:` with comparisons and ranges (`size:>5mb`, `size:1mb..10mb`)
- `date:` (modified date) and `created:`, with the same comparisons and ranges
- `root:`, `path:`
- `dup:exact`, `dup:near`
- `tagged:no` (or `-tagged`), for untagged files
- `source:` and `status:`, for working through AI suggestions and the review queue
- `missing:yes`
- `sort:` (for example `sort:size`, `sort:-date`, `sort:random`)

**Rules**
- Filter keys are reserved. A namespace cannot have the same name as a filter key, and Miles refuses to create one.
- Aliases resolve to canonical tags and implications expand at query time. A `~` prefix on a tag (for example `~cat`) matches that tag literally, with no expansion.
- A malformed query produces a clear error, never a guessed or loose text search.
- Saved searches store the query string, so they follow later alias and implication changes.
- Natural-language search is a translation layer using the local model (ADR 0003). It produces a query in this syntax, shows it to the user, then runs it. It never replaces the syntax.
- Content-based `similar:` search is deferred with semantic search.

## Consequences

- One grammar serves the search box, saved searches, and the natural-language feature.
- Reserving filter keys limits namespace names. Accepted for unambiguous parsing.
- The parser needs a real grammar with tests, not ad-hoc string handling.
- Adding a new filter later means reserving a new key, which could collide with an existing user namespace, so new keys need a migration check.
