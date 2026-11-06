# 0002. SQLite via GRDB

- Status: accepted
- Date: 2026-11-06

## Context

Miles stores files, directories, tags (namespaced), tag provenance, hashes, and job state, and runs booru-style queries (required tags, excluded tags, OR, filters) over a library that may be large. It needs full-text search and reliable migrations, and it must work with SwiftUI.

Options considered:

1. **SQLite via GRDB**: mature, FTS5, strong migrations, observation for SwiftUI, and tag-set queries map directly to SQL. Costs a third-party dependency.
2. **SwiftData / Core Data**: Apple-native, but weak for complex set queries, no FTS, and SwiftData migrations are young.
3. **Raw SQLite3**: no dependency, but we would rebuild what GRDB provides.

## Decision

Use SQLite through GRDB as Miles' only persistent store.

- The database lives in `~/Library/Application Support`, never in iCloud or any synced folder.
- Schema changes use GRDB migrations only.
- Booru queries compile to SQL against a tag join table. Text search uses FTS5.
- The model keeps room for per-tag source (`user`, `rule`, `ai`) and confidence.

## Consequences

- Accepted: a third-party dependency (kept thin; raw SQLite is the fallback if GRDB becomes a problem).
- Query performance is in our hands. We need to index the join tables deliberately.
- Syncing Miles' own data across Macs is out of scope for v1 and would be a new decision.
- Embeddings for semantic search (deferred) can be added later as another table.
