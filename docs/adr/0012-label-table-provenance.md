# ADR-0012: Where the truth of index → label lives, and how it reaches the app

- Status: Accepted — 2026-07-21
- Deciders: maintainer
- Relates to: [ADR-0002](0002-litert-distribution.md) (the pinning pattern),
  [ADR-0003](0003-benchmark-comparison-scope.md) (cross-model agreement is measured, never asserted),
  [ADR-0009](0009-document-store-scope.md) (which named this table as the one real candidate and
  assigned it elsewhere — corrected in Decision 4 below), CLAUDE.md invariants 6 and 8, and the
  thesis: a thumbs press is evidence only if the person could judge what they confirmed.

## Context

The screen showed `class 973`.

An ImageNet index is not something a user can judge. The product loop's third clause is *capture
signal (thumbs)*, and a signal captured against an unjudgeable answer does not measure correctness —
it measures how plausible the app FELT. That is the gap this ADR closes, and it is a gap in the
thesis, not in the UI.

The gap was one-sided and that shaped the decision. `CoreMLEngine` has always returned words: a Core
ML classifier carries its own label strings, and the engine reads them from `classLabelProbs`. The
raw `.tflite` carries none at all, so `LiteRTEngine` named classes by position. The composed chain
leads with LiteRT, so the app showed indices — and would have shown words the moment it fell back to
Core ML. The vocabulary on screen depended on which engine answered, which is precisely the kind of
thing invariant 3 exists to stop.

## Decision 1 — the truth is the Apple `.mlmodel`'s OWN embedded label vector

The table is derived from `MobileNetV2FP16.mlmodel`, which embeds a 1001-entry class-label vector.
It is already checksum-pinned (MODEL_PROVENANCE.md), so this adds no upstream that can rot, no second
artifact to trust, and no new URL.

**The alternative that was refused, and why it is the dangerous one.** A "canonical ImageNet list"
from the web is the obvious move and it is a trap: published lists are almost always **1000** entries
with no background class, while both models here emit **1001** (index 0 is TF-slim's background).
Mapping a 1001-wide output through a 1000-entry list shifts every label by one. Nothing about that
failure announces itself — every lookup succeeds, every word is confidently wrong, and the thumbs
signal it feeds is worse than the indices it replaced. **A wrong word under a thumbs button is worse
than an index**: an index is merely unreadable; a wrong word is a false claim the user has no way to
check.

Google's side offers nothing to use instead. Its pinned archive was re-fetched and listed at this
rung: seven members — three checkpoint files, `eval.pbtxt`, `frozen.pb`, `info.txt`, and the
`.tflite`. **No labels file.** The `.tflite` itself contains no label strings.

## Decision 2 — the ordering is PROVED, not assumed

The table comes from Apple's model; the indices it is used on come from Google's. The two are
independently trained artifacts (ADR-0003), so a shared output ordering is a fact about how both were
derived from TF-slim's 1001-class arrangement — plausible, load-bearing, and therefore not something
to assume. Three independent things establish it, and all three are in the suite:

| Evidence | What it establishes | What it cannot |
|---|---|---|
| Count: table length equals the model's own output dimension, read from the interpreter | catches the 1000-vs-1001 off-by-one | any other shift — a wrong table of the right length passes |
| Spot-checks against upstream TensorFlow's published `label_image` output: 8 index/label pairs spanning 458–907, all agreeing | ordering, from a source on **Google's** side and independent of Apple's model | it is a sample, not the whole table |
| The fixture: upstream's own reference photograph, run through the real engine with the real table | ordering end to end, with ground truth being **what the picture is** | nothing about how well the model classifies |

The fixture is the one that matters most, because its ground truth is not another model's opinion. It
is a US Navy portrait of Grace Hopper in uniform; the engine answers `military uniform` at index 653
with 0.821 confidence, and the runners-up (`suit`, `mortarboard`, `bearskin, busby, shako`) are
coherent for that photograph in a way a shifted table would not be.

**What was deliberately NOT done: assert that the two engines agree.** Running one image through both
and demanding the same answer would be the strongest-looking test here and it is forbidden — ADR-0003
makes cross-model agreement a measured, published result, never an equality assertion. Each engine is
instead checked against the same table file separately, which is the claim actually being made: one
table, both engines.

## Decision 3 — the table is DERIVED at `make bootstrap` and the derived file is pinned too

`scripts/extract-labels.py` parses the label vector out of the already-verified `.mlmodel`;
`make bootstrap` verifies the **derived** file's sha256 and stages it beside the models. It is
git-ignored like every other fetched artifact (invariant 6) and arrives on the model path
(invariant 8).

Pinning the derived output matters as much as pinning the download. Without it the derivation would
be the one unpinned link in an otherwise fail-closed chain: a changed model or a changed extractor
would silently produce a different table. Both failure paths are exercised — a wrong `--expect-count`
and a non-classifier input each exit 1 with their own message.

**The alternative not taken: committing the table as a ~22 KB text file.** It is defensible —
diff-reviewable, no network step, and invariant 6 targets large binaries, which this is not. It was
refused because a committed copy can drift from the model it describes with nothing forcing agreement,
and the failure mode of drift here is the same confidently-wrong word Decision 1 is about. Deriving
makes drift impossible rather than merely detectable.

## Decision 4 — this rung owns the label table; ADR-0009's assignment is corrected

[ADR-0009](0009-document-store-scope.md) named the ImageNet label table as "the one candidate that is
real" for a document store, then declined it on the grounds that the reconciliation belonged to the
cross-model agreement rung. That was right to decline and wrong about the destination — the same
shape as the rung-37 ownership correction, and recorded the same way rather than silently reworded.

The table is not a document-store subject: nothing about it is a document, a cache, or a per-model
record. It is a value derived from a pinned artifact, and it belongs on the model path with the
bytes it comes from. Nor is it the agreement rung's: that rung MEASURES where two models disagree,
and it needs a shared vocabulary to express a disagreement in. This rung supplies the vocabulary; the
agreement rung uses it. Assigning the table there would have made the agreement rung's first task
building something its own subject presupposes.

## What this ADR does NOT decide

- **The index is not persisted.** The ledger stores `label` and `confidence` and gains no column, so a
  `Classification` read back from a row has no index. The export is byte-identical with and without an
  index on the value type, and there is a test that says so. Adding a column is a schema migration
  whose caller does not exist yet; recorded as a finding against the agreement rung, which is the
  first thing that would want index-keyed comparison.
- **The Core ML engine's lost class is not fixed.** Surfaced here, recorded, not repaired — see the
  finding in ROADMAP. `classLabelProbs` is keyed by label, `"crane"` names two output positions, so
  that engine returns 1000 classifications rather than 1001. The fix changes how the engine talks to
  Core ML and is not a labelling change.
- **Nothing about display beyond the two rules it needed.** The screen draws the first synonym of a
  label and the index beside it; the ledger keeps the full string. That the two are not
  character-identical is stated at the code rather than decided here.

## Consequences

- The thumbs signal becomes evidence about correctness rather than about plausibility — the loop's
  human surface, which is the whole reason this rung exists.
- The vocabulary on screen no longer depends on which engine answered. A fallback changes the backend
  line and not a single word.
- A missing or ill-fitting table degrades to `class N` — exactly the app's previous behaviour —
  rather than to a blank, a placeholder, or a guess. That is the explicit fallback, and it is tested
  both ways.
- One more thing must be true for the app to be right, and it is now checked in three independent
  ways rather than believed.
