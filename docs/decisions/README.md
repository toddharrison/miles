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
