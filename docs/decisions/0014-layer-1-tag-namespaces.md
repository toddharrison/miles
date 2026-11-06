# 0014. Layer 1 and 2 tag namespaces, and how the layers run

- Status: accepted
- Date: 2026-11-06

## Context

ADR 0010 names `type:` as a system-managed namespace for layer 1 (file metadata). ADR 0009 reserves `type` and `ext` as query filter keys, and Miles refuses a namespace with a filter key's name, so `type:image` would be read as the filter and could never be a tag. Step 5 also needs decisions on how automated layers are tracked and re-run.

## Decision

- Layer 1 writes tags in these system namespaces: `kind:` (the file kind: `kind:image`, `kind:video`, ...; nothing for `other`), `year:` (modified year), `resolution:` (`sd`, `hd`, `fhd`, `uhd` by longest edge: under 1280, 1280, 1920, 3840 pixels and up; images and video) and `length:` (`short` under 1 minute, `medium` under 10, `long` under 1 hour, `feature` beyond; video and audio). The `type:` and `ext:` filters remain the way to search by kind and extension. This amends the namespace names in ADR 0010; the layering, treatment and rules of ADR 0010 are unchanged.
- Layer 2 tags use whatever namespace the rule's tag names. A rule's tag is a template: `{1}`, `{2}` ... insert what the pattern's wildcards matched.
- A namespace used by layer 1 or by a rule is marked system-managed. This only labels it (the UI can show it differently). The user may still add tags in it.
- Each `file_tag` row made by a layer records that layer (`layer` column). Re-running a layer replaces only that layer's accepted `rule` rows. User tags, rows of other layers and rejected rows are never touched, and a tag the user rejected is not applied again.
- Layer work is a per-file `job`. Which files need a layer run is recorded in `file_layer_run`, with the file's size, modified time and path and the layer's version when it ran, so a changed, moved or newly local file, or a changed rule set, is picked up again.
- Layer 1 reads content (image dimensions, media duration) only for local files after a live metadata check. For an iCloud placeholder it writes only the tags that need no content, and the run is marked incomplete so it repeats when the file is local.

## Consequences

- Queries use `kind:image` where they would have used a `type:` tag, and the existing `type:image` filter keeps working.
- Rule re-runs and metadata changes cost one cheap job per file, and are resumable.
