# 0015. AI layers, near-duplicate fingerprints and natural-language search

- Status: accepted
- Date: 2026-11-06
- Amends: [0003](0003-ai-provider-abstraction.md) (the system model accepts images), [0007](0007-duplicate-detection-and-resolution.md) (algorithm and threshold), [0010](0010-tagging-sources.md) (layer numbers, namespaces, thresholds)

## Context

Step 8 builds the layers ADR 0010 left open. Checking the macOS 27 SDK and the machine showed two things ADR 0003 did not know: Apple's on-device language model reports a `vision` capability and takes images as prompt attachments, and the same framework also exposes `PrivateCloudComputeLanguageModel`, which is not on-device. ADR 0007 left the near-duplicate algorithm and threshold to implementation.

## Decision

**Providers.** `MilesAI` defines `TagProvider` (layer 3 or 4; says which file kinds it handles and whether it can run now) and `QueryTranslationProvider`. A provider only suggests; Miles stores. The default providers are:
- `VisionProvider` (layer 3, images): `ClassifyImageRequest` gives `subject:` tags above 0.25 confidence (at most 8); text recognition gives `content:text` when an image holds readable writing.
- `NaturalLanguageProvider` (layer 3, plain-text files): `language:` from the dominant language, and `person:`, `place:`, `org:` from `NLTagger`. Entities have no confidence, so they get a fixed 0.6.
- `FoundationModelsProvider` (layer 4, images and text; also query translation): `SystemLanguageModel` only. Text goes to the content-tagging model, images go to the general model as attachments when it reports the `vision` capability. The model's self-reported confidence is capped at 0.8, because it is not calibrated and must not clear a high auto-accept threshold.
- **`PrivateCloudComputeLanguageModel` is never used.** It is cloud-hosted, and ADR 0003 allows no cloud AI. Any provider other than `SystemLanguageModel` needs its own ADR first.

**Layers.** Layer 3 is `systemML` (job `tag-system-ml`), layer 4 is `llm` (job `tag-llm`). Both write `ai` rows with status `suggested`, the layer number, confidence, provider and model. Layer 3 runs for local images and plain-text files in every root. Layer 4 runs only for the file kinds a root has switched on (`root.layer4Kinds`, empty by default), and the handler re-checks that setting when it runs.
- A tag the file already has in any state is left alone: user and rule tags win, accepted tags stay, rejected tags stay rejected.
- A re-run replaces the layer's own unjudged suggestions with the new result. Accepted AI tags are never removed by a re-run.
- Tags the tag grammar refuses (a reserved namespace, a colon in a value) are dropped, not rewritten.
- A layer is due again when the file's size or time changes, or when the providers' version changes. The version is a hash of each usable provider's id, model and revision, so a new model or a new revision re-runs the layer, and a layer with no usable provider is never queued.
- The optional auto-accept threshold is per root (`root.autoAcceptThreshold`, off by default). A suggestion at or above it is stored as accepted, still with source `ai`.
- Layers 3 and 4 skip placeholders and read only files that are local and unchanged since they were indexed.

**Review queue.** Pending suggestions, most confident first. Accept makes the tag accepted (searchable) and keeps its provenance. Reject marks it `rejected` for that file permanently. Accepting everything above a confidence is a bulk action.

**Near-duplicates.** `image_fingerprint` holds a 64-bit difference hash (9x8 grey, algorithm 1) per local image, with the file version it came from. Two images are near-duplicates when their hashes differ in at most 6 bits; groups are the connected components, so a chain of small edits stays together. The grouping uses banded buckets so it does not compare every pair. Groups are suggestions only: they are shown and can be marked reviewed, and Miles refuses to resolve them (only exact groups can be). Left out: a file and its own resize (`file_link`), hard links of one file (counted once), and sets whose members all have the same full hash (those are exact duplicates).

**Natural-language search.** The model is given the query grammar, today's date and the user's namespaces and most-used tags, and writes a query. Miles parses and compiles it with the real parser, retries once with the error, and otherwise reports failure. The query is always shown to the user before it runs, and the user can edit it. A translated query is not a saved search or a different query language: it is ADR 0009 text.

## Consequences

- No download or setup is needed for layer 3 or for translation on a Mac that has Apple Intelligence. When the system model is unavailable, layer 4 and translation say so and are not queued; layers 1 to 3 are unaffected.
- A 64-bit difference hash is cheap and stable under resizing and re-encoding but weak against crops, rotation and heavy edits. Those pairs are missed rather than wrongly grouped. A stronger fingerprint (for example Vision feature prints) can replace it by bumping the algorithm number.
- The distance threshold is a constant. Very uniform images (blank pages, solid colours) hash alike and group together; the groups are only suggestions, so the cost is review time.
- Small models write imperfect queries. Showing the query first is what makes that tolerable.
- Layer 4 results cost compute and attention, which is why it is opt-in per root and kind.
