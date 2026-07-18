# Inferlens roadmap

An atomic commit ladder. Every rung is a Conventional Commit, independently reviewable,
and **green** (builds + tests pass, clean under Swift 6.3 `-strict-concurrency=complete`).
A rung that would touch two concerns is split. Rung 00 is the bootstrap; rungs 01–32 are
the build ladder. Rungs 00 and 01 are committed.

Design of record: [ADR-0001](adr/0001-module-boundaries.md) (module boundaries),
[ADR-0002](adr/0002-litert-distribution.md) (LiteRT distribution),
[ADR-0003](adr/0003-benchmark-comparison-scope.md) (benchmark scope),
[ADR-0004](adr/0004-commit-hygiene.md) (commit hygiene).
Ground truth: [PRIOR_ART.md](research/PRIOR_ART.md),
[MODEL_PROVENANCE.md](research/MODEL_PROVENANCE.md).

## The thesis every rung serves

The product loop and the developer's evaluation loop are the **same loop**:
`run inference → append to ledger → capture signal (thumbs) → export → offline eval →
choose next model/backend → run inference`. A wrapper app calls an API; this app closes
a loop. Every decision is defensible by pointing at that sentence.

## Build model (explicit: bootstrap precedes build)

The SPM `binaryTarget` mechanism is xcframework-only, so the two benchmark models are
fetched by script, not by SPM. `swift build` **alone** does not yield a working app:

```
make bootstrap && swift build      # bootstrap fetches the pinned models + verifies checksums;
                                   # SPM resolves the TensorFlowLiteC xcframework binaryTarget
```

CI (rung 27) runs `make bootstrap` before `swift test`. The README states this in one line.

## The ladder (rungs 00–32)

```
00 chore(repo): bootstrap toolchain, license, agent context          <- committed (db1056c)
01 docs(readme): project overview — what it is, where it stands, what is decided  <- committed
02 build(spm): Package.swift workspace + empty local module targets + thin app placeholder
03 feat(core): inference contract protocols (InferenceEngine, ModelDescriptor,
               LatencySample, InferenceOutcome) — zero dependencies
04 test(core): contract conformance suite every engine must pass (engine-agnostic)
05 chore(models): pin Apple MobileNetV2 (FP16 .mlmodel, native) + Google MobileNetV2
               (FP32 .tflite, default) by source URL + checksum in MODEL_PROVENANCE.md;
               make bootstrap fetches them (verify Google .tflite URL here)
06 feat(coreml): CoreMLEngine over the fetched FP16 .mlmodel, conforms to the contract
07 perf(coreml): OSSignposter spans around load / preprocess / infer
08 feat(bench): LatencyRecorder — p50/p95, warm-up discard (HAND-WRITTEN, hand-reviewed;
               discard policy documented; never agent-generated)
09 build(litert): produce & publish the vendored TensorFlowLiteC.xcframework release —
               extract from the dl.google.com archive; read Info.plist AvailableLibraries
               and ASSERT ios-arm64_x86_64-simulator FIRST; re-zip; tag GitHub release
10 build(litert): declare binaryTarget(url:checksum:) + simulator link smoke test
11 feat(litert): LiteRTEngine over the C API — actor-isolated, ONE @unchecked Sendable
               boundary (required to compile under strict concurrency); uses FP32 .tflite
12 ci(litert): document the Sendable boundary + CI lint enforcing exactly-one
               @unchecked-Sendable + a strict-concurrency data-race test
13 feat(bench): measure & PUBLISH cross-model top-1 agreement on a FROZEN golden set
               (different weights → disagreement is data, not a gate; ADR-0003)
14 feat(store): SQLite append-only run ledger + versioned migrations (SQL)
15 feat(store): document/KV store for model metadata + flag cache (NoSQL)
16 feat(flags): FeatureFlagProvider protocol + local JSON provider
17 feat(engine): fallback chain LiteRT -> CoreML -> remote stub as a VALUE (not if-else)
18 refactor(engine): engine actor; cancel in-flight Tasks when input changes
19 feat(ui): InferenceState enum + SwiftUI state-machine views, no engine knowledge
20 feat(ui): pick/capture image -> classify -> top-3 + confidence + backend + p50/p95
21 feat(ui): thumbs up/down signal -> append to ledger
22 feat(store): ledger export (NDJSON) for offline eval
23 feat(thermal): map ProcessInfo.thermalState + model-load failure + OOM to named states
24 feat(flags): EntitlementProvider seam + AlwaysEntitled stub; paywall flag OFF
25 feat(app): thin app target composes the modules — the one MVP screen
26 test(store): migration + append-only invariant tests
27 build(ci): GitHub Actions — make bootstrap, then build, swiftformat --lint, swiftlint,
               swift test; commit-hygiene trailer lint already active from commit #1
               (ADR-0004); a doc-reference lint — every `rung NN` citation under docs/,
               README.md, and CLAUDE.md must resolve to an existing ROADMAP rung with a
               matching title, else CI fails (a decision-layer file citing a rung is the
               same one-way-dependency rule this repo lints for in modules, in prose).
               LiteRT device-only contingency documented in ADR-0002 if the sim slice is
               ever absent
28 perf(bench): make bench on-device harness emits JSON (device, iOS, thermal, run count,
               warm-up policy)
29 docs(method): BENCHMARK_METHOD.md (ecosystem comparison; native precision per side —
               Apple FP16 vs Google FP32 — reported prominently; different weights;
               warm-up policy; run counts; thermal state) + LIMITATIONS.md
30 docs(loop): EVAL_LOOP.md (product loop == eval loop) + docs/prompts/ (one per rung)
31 docs(monetization): MONETIZATION.md (Pro surface as a plan; revisit-trademark line)
               + docs/ASO.md
32 docs(readme): COMPLETE the README — fill the latency table with real runs, add the
               20s GIF, publish docs/ via GitHub Pages (the README itself lands at rung 01)
```

**Split rule honored:** SQL vs NoSQL (14/15); produce-artifact vs wire-binaryTarget
(09/10); engine-lands-isolated vs enforce-the-boundary (11/12); state-enum vs
screen-wiring (19/20); signal vs export (21/22); CI vs on-device bench (27/28); each doc
cluster its own rung. The README is created at rung 01 and completed at rung 32 — not
created twice.

## Riskiest assumption (tested at rung 09, before any engine logic)

That Google's `TensorFlowLiteC.xcframework`, once re-zipped and pinned, contains an
`ios-arm64_x86_64-simulator` slice and links under Swift 6.3 strict concurrency. Rung 09's
first action reads `Info.plist` (`AvailableLibraries`) and asserts the slice; rung 10
proves it links on the simulator. If absent, the ladder goes red at 09 — before rung 11 —
and the ADR-0002 device-only CI contingency applies. See ADR-0002.

## Open inputs (approved deferrals — literals only, decisions made)

- Exact Google `.tflite` download URL — verified at rung 05. Precision (Google FP32
  default) is already decided (ADR-0003 / MODEL_PROVENANCE.md).
- Exact `TensorFlowLiteC` version pin, our release-asset URL, and its checksum — produced
  when rung 09 runs (a checksum cannot exist before the `.zip` does; ADR-0002).

## README

The project overview README lives at [README.md](../README.md) as of rung 01. It is not
duplicated here. Rung 32 completes it: the latency table filled with real runs, the GIF,
and GitHub Pages. The empty latency table and scoped headline are already on the page
today, marked empty because the measurements do not exist yet.
