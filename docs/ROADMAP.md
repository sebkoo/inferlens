# Inferlens roadmap

An atomic commit ladder. Every rung is a Conventional Commit, independently reviewable,
and **green** (builds + tests pass, clean under Swift 6.3 `-strict-concurrency=complete`).
A rung that would touch two concerns is split. Rung 00 is the bootstrap; rungs 01–36 are
the build ladder.

Progress is not tracked in this file — **git tags are**: `git tag -l 'rung-*'` is the
authoritative record of what landed (one tag per landing commit), and the README badge is
derived from it (`make readme-sync`). This file is the plan; git is the progress. Land a rung
with `make land RUNG=NN` so the tag is declared, not remembered.

Design of record: [ADR-0001](adr/0001-module-boundaries.md) (module boundaries),
[ADR-0002](adr/0002-litert-distribution.md) (LiteRT distribution),
[ADR-0003](adr/0003-benchmark-comparison-scope.md) (benchmark scope),
[ADR-0004](adr/0004-commit-hygiene.md) (commit hygiene),
[ADR-0005](adr/0005-litert-engine-concurrency.md) (LiteRT engine concurrency),
[ADR-0006](adr/0006-run-ledger-storage.md) (run ledger storage).
Ground truth: [PRIOR_ART.md](research/PRIOR_ART.md),
[MODEL_PROVENANCE.md](research/MODEL_PROVENANCE.md).

## The thesis every rung serves

The product loop and the developer's evaluation loop are the **same loop**:
`run inference → append to ledger → capture signal (thumbs) → export → offline eval →
choose next model/backend → run inference`. A wrapper app calls an API; this app closes
a loop. Every decision is defensible by pointing at that sentence.

## Build model (explicit: bootstrap precedes build)

The SPM `binaryTarget` mechanism is xcframework-only, so the two benchmark models are
fetched by script, not by SPM. `swift build` **alone** does not yield a working app, and the
macOS host build fails on iOS-era stdlib (`Duration`) besides — verify on iOS:

```
make bootstrap && xcodebuild build -destination 'generic/platform=iOS Simulator'
```

CI (the CI rung) runs `make bootstrap` before the iOS test build. The README states it in one line.

## The ladder (rungs 00–36)

```
00 chore(repo): bootstrap toolchain, license, agent context
01 docs(readme): project overview — what it is, where it stands, what is decided
02 build(spm): Package.swift workspace + empty local module targets + thin app placeholder
03 feat(core): inference contract protocols (InferenceEngine, ModelDescriptor,
               LatencySample, InferenceOutcome) — zero dependencies
04 build(make): derive the README badge from rung tags; cite docs by stable component
               name, not rung number (numbers live only in this file); drop hand-typed
               progress state
05 test(core): StubEngine — a deterministic in-memory engine, no model, no framework
06 test(core): assertConformsToContract — the engine-agnostic conformance suite, run
               against the stub (never names or imports a concrete engine)
07 test(core): broken stub variants prove the suite catches what it claims
               (unsorted classifications, confidence > 1, lazy-load in classify)
08 build(make): wire `make test` to xcodebuild on the iOS simulator — it has been exit-0
               since commit #1; this is where it stops lying
09 chore(models): pin Apple MobileNetV2 (FP16 .mlmodel, native) + Google MobileNetV2
               (FP32 .tflite, default) by source URL + checksum in MODEL_PROVENANCE.md;
               make bootstrap fetches them (verify Google .tflite URL here)
10 feat(coreml): CoreMLEngine over the fetched FP16 .mlmodel, conforms to the contract
11 perf(coreml): OSSignposter spans around load / preprocess / infer
12 feat(bench): LatencyRecorder — p50/p95 over cold/warm (agent-written, maintainer-decided;
               nearest-rank + no-discard policy ratified and documented at the code)
13 build(litert): produce & publish the vendored TensorFlowLiteC.xcframework release —
               extract from the dl.google.com archive; read Info.plist AvailableLibraries
               and ASSERT ios-arm64_x86_64-simulator FIRST; re-zip; tag GitHub release
14 build(litert): declare binaryTarget(url:checksum:) + simulator link smoke test
15 feat(litert): LiteRTEngine over the C API — actor-isolated, ONE @unchecked Sendable
               boundary (required to compile under strict concurrency); uses FP32 .tflite
16 ci(litert): document the Sendable boundary + CI lint enforcing AT MOST ONE
               @unchecked-Sendable (the on-actor rung-15 engine ships ZERO; ADR-0005)
               + a strict-concurrency data-race test
17 feat(bench): measure & PUBLISH cross-model top-1 agreement on a FROZEN golden set
               (different weights → disagreement is data, not a gate; ADR-0003)
18 feat(store): SQLite append-only run ledger + versioned migrations (SQL)
19 feat(store): document/KV store for model metadata + flag cache (NoSQL)
20 feat(flags): FeatureFlagProvider protocol + local JSON provider
21 feat(engine): fallback chain LiteRT -> CoreML -> remote stub as a VALUE (not if-else)
22 refactor(engine): engine actor; cancel in-flight Tasks when input changes
23 feat(ui): InferenceState enum + SwiftUI state-machine views, no engine knowledge
24 feat(ui): pick/capture image -> classify -> top-3 + confidence + backend + p50/p95
25 feat(ui): thumbs up/down signal -> append to ledger
26 feat(store): ledger export (NDJSON) for offline eval
27 feat(thermal): map ProcessInfo.thermalState + model-load failure + OOM to named states
28 feat(flags): EntitlementProvider seam + AlwaysEntitled stub; paywall flag OFF
29 feat(app): thin app target composes the modules — the one MVP screen
30 test(store): migration + append-only invariant tests
31 build(ci): GitHub Actions — make bootstrap, then swiftformat --lint, swiftlint, and
               build+test on the iOS simulator via
               `xcodebuild -destination 'generic/platform=iOS Simulator'` — never
               `swift build`/`swift test` on the host (the host build was green only for as
               long as it was meaningless — empty targets; iOS-era stdlib such as `Duration`
               breaks it, discovered at rung 03). Commit-hygiene trailer lint from commit #1
               (ADR-0004). Derived-vs-declared lints, each failing loud where a hand-typed
               value would rot silent: (a) no hand-typed rung number anywhere outside this
               file; (b) every component reference in docs resolves — the Core ML engine,
               the LiteRT vendoring step, InferlensCoreML — to a real target or ROADMAP
               rung; (c) the `rungs N/D` badge equals the derived pair, `rung-*` tags on
               ORIGIN over the ladder's rung count in this file, so an unpushed tag makes N
               lag and fails here (the core.hooksPath trap again); (d) every `rung-*` tag
               names a real ladder rung in this file (no orphan tags). LiteRT device-only
               contingency documented in ADR-0002 if the sim slice is ever absent
32 perf(bench): make bench on-device harness emits JSON (device, iOS, thermal, run count,
               warm-up policy)
33 docs(method): BENCHMARK_METHOD.md (ecosystem comparison; native precision per side —
               Apple FP16 vs Google FP32 — reported prominently; different weights;
               warm-up policy; run counts; thermal state) + LIMITATIONS.md
34 docs(loop): EVAL_LOOP.md (product loop == eval loop) + docs/prompts/ (one per rung)
35 docs(monetization): MONETIZATION.md (Pro surface as a plan; revisit-trademark line)
               + docs/ASO.md
36 docs(readme): COMPLETE the README — fill the latency table with real runs, add the
               20s GIF, publish docs/ via GitHub Pages (the README itself lands at rung 01)
```

**Split rule honored:** the conformance work splits into stub / suite / proofs / wiring
(05–08); SQL vs NoSQL (18/19); produce-artifact vs wire-binaryTarget (13/14);
engine-lands-isolated vs enforce-the-boundary (15/16); state-enum vs screen-wiring
(23/24); signal vs export (25/26); CI vs on-device bench (31/32); each doc cluster its own
rung. The README is created at rung 01 and completed at rung 36 — not created twice.

## Phase map (groups the ladder into the six README phases; make readme-sync reads it)

`make readme-sync` reads the lines below plus the `rung-*` tags to regenerate the README rung-status
block — edit the grouping HERE, never in the README. Every rung 00–36 belongs to exactly one phase, and
readme-sync fails loud if this map and the ladder ever disagree.

<!-- phase-map:start -->
- Foundation: 00 01 02 03 04 05 06 07 08
- Supply chain: 09 13 14
- Engines: 10 11 15 16 21 22
- Measurement: 12 17 32 33 36
- Product loop: 18 19 20 23 24 25 26 27 28 29 30 34 35
- Hardening: 31
<!-- phase-map:end -->

## Harness backlog — the per-rung claims audit (recorded at rung 12)

Rung 12's real cost was not the `LatencyRecorder`; it was tracking one false claim ("the
aggregation is hand-written") across twelve sites. Three were invisible to a working-tree
`grep -r` and cost most of the passes:

- a claim inside a **commit message** (`git log`, not the tree)
- a **dead-sha reference** — alive locally via a backup branch, but 404 on origin once a
  rebase orphaned the sha it named
- stale text a **rebase resurrected** from an old commit *after* the sweep had already passed

So a per-rung **claims audit**, keyed on the rung's subject-claim, must sweep all three
surfaces — the working tree, `git log --format=%B`, and dead-sha references (short-sha strings
that a rebase can orphan) — not just `grep -r`. It lands as a lint with the CI rung; until
then it is a manual step in the landing checklist. This is a derived-vs-declared check like the
others (a claim is "declared" in the subject and must hold everywhere it is "restated").

## Correction of record — test-clean returned 1 for a build failure the contract assigns to 2

This section used to be a backlog item: the exit-1 and exit-2 paths were unexercised and should be
teeth-tested, because "an unexercised contract is a claim, not a guarantee." That was right, and the
claim was false. Exercising it found a real bug.

`37fbc1e`'s pushed body states the contract as "2 the harness could not run (no simulator, **or the
build never reached test execution**)". The script did not do that. It returned 1 on the
`** TEST FAILED **` marker alone — and under `xcodebuild test` a failed **build** emits that marker
too, because the action that failed is the test action whatever stopped it. So a compile error
returned 1, "tests ran and failed", for a run in which no test ever executed. The claim was wrong
when it was written.

Observed, not hypothesized: a compile error in `InferlensStore` during the run-ledger rung produced

```
Testing failed:
    Overlapping accesses to 'info.machine', ...
    Testing cancelled because the build failed.
** TEST FAILED **
The following build commands failed:
```

Note what is absent — no `** BUILD FAILED **` (the test action swallows it), and no `Executed N tests`
line at all. **The presence of an `Executed` line is the discriminator**, not the SUCCEEDED/FAILED
marker: it is the only thing in the log that says the runner reached test execution. Fixed in
`fix(scripts): test-clean returns 1 for a build failure the contract assigns to 2` — exit 1 now
requires the marker **and** an `Executed` line; everything else is 2, with the build-failure case
named in its own message.

`37fbc1e` is pushed and cannot be amended without rewriting shared history, so the correction lives
here — the same disposition as the rung 26 → 31 correction below.

### The contract, exercised — every path, old script vs fixed

Each path was forced by planting the exact condition it exists to report, both scripts run back to
back on the same tree:

| Path | Forced by | Old | Fixed |
|---|---|---|---|
| 0 — tests ran and passed | the tree as committed | 0 | **0** |
| 1 — tests ran and failed | an `XCTFail` planted in the store suite | 1 | **1** (no regression) |
| 2 — build never reached tests | a type error planted in `LedgerCodec.swift` | **1** ← the bug | **2** |
| 2 — no usable destination | the simulator parser forced to return no records | 2 | **2** |

Path 1 holding at 1 matters as much as path 2 moving to 2: a "fix" that collapsed every failure to 2
would satisfy the headline and destroy the contract. The point is that the two stay distinguishable.

Scope, honestly: the last row was forced by neutering the parser, not by removing the machine's
simulators, so it proves the branch refuses to fall through to a default destination — it does not
prove behaviour on a genuinely simulator-less machine (a CI runner will). Automating all four as a
standing check lands with the CI rung; until then they are a manual step in the landing checklist.

The general lesson is the one this repo keeps re-learning: a marker is not the same as the thing it
is read to mean. `** TEST FAILED **` was trusted to mean "tests failed" for the same reason a reused
DerivedData was trusted to mean "this tree passed" — nobody had made it lie on purpose yet.

## Harness backlog — a cross-document pointer check (recorded now)

claims-audit catches forbidden phrasings and dead shas, but not cross-document POINTERS: a `rung N`
that names no rung in this ladder, a `#anchor` that no heading generates, a repo file path that has
moved. Same breakage as a dead sha — a well-formed pointer to nothing — a different regex. Motivating
case: the CI build+test gate is rung 31 here, yet eleven prose sites (`.github/workflows/build.yml`,
`CLAUDE.md`, `README.md`) had drifted to "rung 26" — the ledger-export rung — and nothing caught it.
Add this check with the CI rung; until then it is a manual landing step, beside the no-simulator teeth
test above.

## Harness backlog — wire swiftformat/swiftlint, and a contract-preserving make test (recorded now)

`make lint` and `make test` are stubs that echo a TODO and exit 0 — they check nothing, so they are not
part of the green bar (CLAUDE.md's Process now names `bash scripts/test-clean.sh` as the real runner).
Wire `swiftformat --lint` and `swiftlint` into `make lint`, and repoint `make test` at a runner that
preserves test-clean's 0/1/2 exit-code contract — a naive `test: test-clean` would route the suite
through `make`, which collapses a recipe failure to a bare 2 and erases the fired-vs-could-not-run
distinction. Lands with the CI rung; until then the green bar rests on test-clean run as the script, plus
the standing commit-hygiene and claims-audit gates.

## Harness backlog — teeth-test commit-hygiene with a planted trailer (recorded now)

Three of the four standing gates — claims-audit, anchor-check, test-clean — are teeth-tested by planting
the failure each catches. commit-hygiene (the AI-attribution-trailer lint that runs on every push, plus the
committed commit-msg hook) is NOT: no test plants a trailer and confirms rejection, so the README harness
pillar says three are teeth-tested, not four. Add one — plant a commit message carrying an AI trailer,
confirm the hook and the CI lint reject it, then remove it, the same standard the other three met. Until
then the fourth gate is long-standing, not proven. Beside the no-simulator and cross-document-pointer items
above.

## Correction of record — the CI build+test gate is rung 31, not 26

This ladder is the index; prose is downstream of it. The CI build+test gate is **rung 31**
(`build(ci)` above); rung 26 is the ledger export. Repo prose had said "rung 26" for the CI gate in
eleven places, now corrected in the tracked tree by the `docs: correct the CI rung reference` commit
(the historical quote in `commit-hygiene.yml` is marked and deliberately left — it records the string
that actually broke). Two already-pushed commits — `4e12860` (claims-audit) and `37fbc1e`
(test-clean) — cite "rung 26" for the CI gate in their bodies and cannot be amended without
force-pushing shared history, which costs more than it buys; the correct number is recorded here
instead. From here, rung numbers are read from this ladder at the point of writing, never carried over
from conversation. Recorded like the invariant-1, invariant-2 and RAII corrections.

## Riskiest assumption (tested at rung 13, before any engine logic)

That Google's `TensorFlowLiteC.xcframework`, once re-zipped and pinned, contains an
`ios-arm64_x86_64-simulator` slice and links under Swift 6.3 strict concurrency. Rung 13's
first action reads `Info.plist` (`AvailableLibraries`) and asserts the slice; rung 14
proves it links on the simulator. If absent, the ladder goes red at 13 — before rung 15 —
and the ADR-0002 device-only CI contingency applies. See ADR-0002.

## Open inputs (approved deferrals — literals only, decisions made)

- Exact Google `.tflite` download URL — verified at rung 09. Precision (Google FP32
  default) is already decided (ADR-0003 / MODEL_PROVENANCE.md).
- Exact `TensorFlowLiteC` version pin, our release-asset URL, and its checksum — produced
  when rung 13 runs (a checksum cannot exist before the `.zip` does; ADR-0002).

## README

The project overview README lives at [README.md](../README.md) as of rung 01. It is not
duplicated here. Rung 36 completes it: the latency table filled with real runs, the GIF,
and GitHub Pages. The empty latency table and scoped headline are already on the page
today, marked empty because the measurements do not exist yet.
