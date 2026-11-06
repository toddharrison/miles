# Architecture Decision Records

One file per decision, named `NNNN-short-title.md`, numbered in order. ADRs are not edited to change a decision. Write a new ADR that supersedes the old one and update the old one's status.

## Template

```markdown
# NNNN. Title

- Status: proposed | accepted | superseded by NNNN
- Date: YYYY-MM-DD

## Context
What forces are at play: requirements, constraints, alternatives considered.

## Decision
The rule, stated so it can be applied.

## Consequences
What gets easier, what gets harder, and the costs we accept.
```

## Index

- [0001](0001-storage-model.md): Managed and unmanaged directories
- [0002](0002-database-sqlite-grdb.md): SQLite via GRDB
- [0003](0003-ai-provider-abstraction.md): Local AI behind a provider protocol
- [0004](0004-managed-root-operations.md): Operations allowed in managed roots, and coexistence with other apps
- [0005](0005-backup-of-miles-data.md): Automated backup of Miles' own data
- [0006](0006-image-standardization.md): Image standardization in managed roots
- [0007](0007-duplicate-detection-and-resolution.md): Duplicate detection and resolution
- [0008](0008-tag-model.md): Tag model
- [0009](0009-query-syntax.md): Query syntax
- [0010](0010-tagging-sources.md): Automated tagging sources
- [0011](0011-thumbnails.md): Thumbnails and iCloud files
- [0012](0012-libraries-and-portable-mode.md): Libraries and portable mode
- [0013](0013-project-structure-and-deployment-target.md): Project structure and deployment target
- [0014](0014-layer-1-tag-namespaces.md): Layer 1 and 2 tag namespaces, and how the layers run
- [0015](0015-ai-layers-and-fingerprints.md): AI layers, near-duplicate fingerprints and natural-language search
- [0016](0016-single-thumbnail-size.md): One thumbnail size (256)
- [0017](0017-folder-view-filter.md): Folder tree and folder view filter
