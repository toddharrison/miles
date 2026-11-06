# 0008. Tag model

- Status: accepted
- Date: 2026-11-06

## Context

Search is booru-style, so tags are the core of the product. Tags come from the user, from rules, and from AI (ADR 0003). The model has to support aliases and implications, keep tags attached to files across moves, and not lose tags when duplicates are resolved.

## Decision

- Tags are namespaced (`namespace:value`). A tag without a namespace goes in a default namespace.
- Tags attach to the file record, not to its path (ADR 0001), and are **per file**: exact duplicates do not share tags automatically.
- Duplicate resolution offers to **merge tags** onto the kept copy, so no copy's tags are lost silently (ADR 0007).
- **Tag aliases and implications are in the schema from the start.** Their management UI is deferred. Queries resolve aliases to canonical tags and expand implications.
- Each file-tag records source (`user`, `rule`, `ai`), confidence, status (`accepted`, `suggested`, `rejected`), and the provider and model for AI tags.
- User tags always win. AI and rule tags never overwrite or remove them. A rejected suggestion is not suggested again for that file.
- v1 search indexes file name, path and tags. Document text indexing and semantic search are deferred.

## Consequences

- Aliases and implications make queries more complex (expansion at query time), and the schema pays for this before the UI uses it. Accepted, because retrofitting later would force a migration of every tag.
- Per-file tags mean duplicates can drift apart in tags until merged. Accepted in exchange for never losing tags silently.
- Rejected suggestions and provider/model fields add storage but allow re-running AI as models improve.
