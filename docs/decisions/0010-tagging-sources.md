# 0010. Automated tagging sources

- Status: accepted, amended by [0014](0014-layer-1-tag-namespaces.md) (layer 1 uses `kind:` rather than `type:`, which ADR 0009 reserves) and [0015](0015-ai-layers-and-fingerprints.md) (how layers 3 and 4 run)
- Date: 2026-11-06

## Context

Tagging is automated with user override (README). ADR 0003 defines the provider abstraction and tag provenance, and ADR 0008 the tag model. This ADR fixes which sources exist and how their results are treated.

## Decision

Sources are layered, cheapest and most reliable first.

| Layer | Source | Examples | Source label | Default treatment |
|---|---|---|---|---|
| 1 | File metadata | type, extension, year, resolution, video length | `rule` | Auto-applied (accepted) |
| 2 | Path and folder rules (user-defined, per root) | `Games/Skyrim` gives `game:skyrim` | `rule` | Auto-applied (accepted) |
| 3 | Vision and NaturalLanguage | image classification, OCR text, language, entities | `ai` | Review queue (suggested) |
| 4 | LLM/VLM (optional providers) | summaries, topic tags, image captions | `ai` | Review queue (suggested) |

- Layers 3 and 4 results are suggestions. The user may set a confidence threshold above which suggestions are auto-accepted.
- **Layer 4 is off by default for every root** and enabled per root, and per file kind within a root (for example writing on, game files off).
- Layers 3 and 4 run only for files that are local (not iCloud placeholders) and run on the background queue (ADR 0003).
- Automatically derived tags use system-managed namespaces such as `type:`, `year:` and `game:`. The user may still add their own tags in any namespace.
- Changing rules or models can re-run a layer. User tags are never touched, and rejected suggestions stay rejected (ADR 0008).
- No rule prohibits face identification. It is not part of v1. If it is added later it is a separate decision.

## Consequences

- Deterministic tags are immediate and trustworthy. Model-derived tags need review, which costs user attention, offset by the threshold setting.
- Per-root and per-kind control of the LLM layer limits wasted compute on file types that gain little (such as game files).
- Re-running layers requires keeping provider and model on each suggestion (already in the data model).
