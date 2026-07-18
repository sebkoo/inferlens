# Inferlens roadmap

An atomic commit ladder. Every rung is a Conventional Commit, independently reviewable,
and **green** (builds + tests pass, clean under Swift 6.3 `-strict-concurrency=complete`).
A rung that would touch two concerns is split. Rung 00 is the only rung committed so far.

Design of record: [ADR-0001](adr/0001-module-boundaries.md) (module boundaries),
[ADR-0002](adr/0002-litert-distribution.md) (LiteRT distribution),
[ADR-0003](adr/0003-benchmark-comparison-scope.md) (benchmark scope).
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

CI (rung 26) runs `make bootstrap` before `swift test`. The README states this in one line.

## The ladder (32 rungs)

```
00 chore(repo): bootstrap toolchain, license, agent context          <- committed (Phase 3)
01 build(spm): Package.swift workspace + empty local module targets + thin app placeholder
02 feat(core): inference contract protocols (InferenceEngine, ModelDescriptor,
               LatencySample, InferenceOutcome) — zero dependencies
03 test(core): contract conformance suite every engine must pass (engine-agnostic)
04 chore(models): pin Apple MobileNetV2 (FP16 .mlmodel, native) + Google MobileNetV2
               (FP32 .tflite, default) by source URL + checksum in MODEL_PROVENANCE.md;
               make bootstrap fetches them (verify Google .tflite URL here)
05 feat(coreml): CoreMLEngine over the fetched FP16 .mlmodel, conforms to the contract
06 perf(coreml): OSSignposter spans around load / preprocess / infer
07 feat(bench): LatencyRecorder — p50/p95, warm-up discard (HAND-WRITTEN, hand-reviewed;
               discard policy documented; never agent-generated)
08 build(litert): produce & publish the vendored TensorFlowLiteC.xcframework release —
               extract from the dl.google.com archive; read Info.plist AvailableLibraries
               and ASSERT ios-arm64_x86_64-simulator FIRST; re-zip; tag GitHub release
09 build(litert): declare binaryTarget(url:checksum:) + simulator link smoke test
10 feat(litert): LiteRTEngine over the C API — actor-isolated, ONE @unchecked Sendable
               boundary (required to compile under strict concurrency); uses FP32 .tflite
11 ci(litert): document the Sendable boundary + CI lint enforcing exactly-one
               @unchecked-Sendable + a strict-concurrency data-race test
12 feat(bench): measure & PUBLISH cross-model top-1 agreement on a FROZEN golden set
               (different weights → disagreement is data, not a gate; ADR-0003)
13 feat(store): SQLite append-only run ledger + versioned migrations (SQL)
14 feat(store): document/KV store for model metadata + flag cache (NoSQL)
15 feat(flags): FeatureFlagProvider protocol + local JSON provider
16 feat(engine): fallback chain LiteRT -> CoreML -> remote stub as a VALUE (not if-else)
17 refactor(engine): engine actor; cancel in-flight Tasks when input changes
18 feat(ui): InferenceState enum + SwiftUI state-machine views, no engine knowledge
19 feat(ui): pick/capture image -> classify -> top-3 + confidence + backend + p50/p95
20 feat(ui): thumbs up/down signal -> append to ledger
21 feat(store): ledger export (NDJSON) for offline eval
22 feat(thermal): map ProcessInfo.thermalState + model-load failure + OOM to named states
23 feat(flags): EntitlementProvider seam + AlwaysEntitled stub; paywall flag OFF
24 feat(app): thin app target composes the modules — the one MVP screen
25 test(store): migration + append-only invariant tests
26 build(ci): GitHub Actions — make bootstrap, then build, swiftformat --lint, swiftlint,
               swift test; commit-hygiene trailer lint already active from commit #1
               (ADR-0004). LiteRT device-only contingency documented in ADR-0002 if the
               sim slice is ever absent
27 perf(bench): make bench on-device harness emits JSON (device, iOS, thermal, run count,
               warm-up policy)
28 docs(method): BENCHMARK_METHOD.md (ecosystem comparison; native precision per side —
               Apple FP16 vs Google FP32 — reported prominently; different weights;
               warm-up policy; run counts; thermal state) + LIMITATIONS.md
29 docs(loop): EVAL_LOOP.md (product loop == eval loop) + docs/prompts/ (one per rung)
30 docs(monetization): MONETIZATION.md (Pro surface as a plan; revisit-trademark line)
               + docs/ASO.md
31 docs(readme): full README (scoped headline, latency table, fallback diagram, GIF,
               MLPerf line, SEO H2s) + publish docs/ via GitHub Pages
```

**Split rule honored:** SQL vs NoSQL (13/14); produce-artifact vs wire-binaryTarget
(08/09); engine-lands-isolated vs enforce-the-boundary (10/11); state-enum vs
screen-wiring (18/19); signal vs export (20/21); CI vs on-device bench (26/27); each doc
cluster its own rung. README lands at 31, not at 00.

## Riskiest assumption (tested at rung 08, before any engine logic)

That Google's `TensorFlowLiteC.xcframework`, once re-zipped and pinned, contains an
`ios-arm64_x86_64-simulator` slice and links under Swift 6.3 strict concurrency. Rung 08's
first action reads `Info.plist` (`AvailableLibraries`) and asserts the slice; rung 09
proves it links on the simulator. If absent, the ladder goes red at 08 — before rung 10 —
and the ADR-0002 device-only CI contingency applies. See ADR-0002.

## Open inputs (approved deferrals — literals only, decisions made)

- Exact Google `.tflite` download URL — verified at rung 04. Precision (Google FP32
  default) is already decided (ADR-0003 / MODEL_PROVENANCE.md).
- Exact `TensorFlowLiteC` version pin, our release-asset URL, and its checksum — produced
  when rung 08 runs (a checksum cannot exist before the `.zip` does; ADR-0002).

## README (full draft — reviewed here, committed at rung 31, NOT now)

```markdown
# Inferlens

On-device image classification that logs every run, so you can measure what each
ecosystem's MobileNetV2 costs on your own phone instead of trusting a vendor's number.

## Core ML vs TensorFlow Lite on iOS: which is actually faster?

That question is why this exists. Inferlens runs each ecosystem's shipped MobileNetV2 at
its native precision (Apple's Core ML model at FP16, Google's TFLite model at FP32)
through one protocol, records p50/p95 latency and memory per run to an append-only ledger,
and shows the active backend and whether the result was degraded. The numbers come from
that ledger.

## Limitations (read these first)
- An ecosystem comparison, not a controlled runtime isolation: the two MobileNetV2 models
  have different weights AND different native precision (Apple FP16 vs Google FP32), and
  Core ML execution precision depends on the compute unit (the ANE runs FP16). This is a
  property of each ecosystem, reported — not eliminated. See docs/BENCHMARK_METHOD.md.
- Single architecture (MobileNetV2), single task (image classification).
- Numbers are from the devices named in each row; your device will differ.
- The remote fallback is a stub; there is no server.
- No App Store build. This is a code and benchmark artifact.

## Build
    make bootstrap && swift build
`make bootstrap` fetches the pinned models (checksum-verified) and SPM resolves the LiteRT
xcframework. `swift build` alone will not produce a working app.

## The latency table (the point of the repo)
Filled by `make bench` at rung 27; every cell carries device + iOS version.

| Backend | Device / iOS | Cold p50 | Cold p95 | Warm p50 | Warm p95 | Peak mem |
|---------|--------------|----------|----------|----------|----------|----------|
| Core ML | (TBD)        | –        | –        | –        | –        | –        |
| LiteRT  | (TBD)        | –        | –        | –        | –        | –        |

Cross-model top-1 agreement on the frozen golden set: (N/50, published by rung 12).

## The state machine (not a feature list)
    idle -> loadingModel -> warming -> inferring -> success(degraded:)
                                          |                     ^
                                          v                     |
                                     failed(retryable:) --------+
Cold start, model load, thermal throttle, and OOM each map to a named state. Backend
fallback (LiteRT -> Core ML -> remote) is a value; degradation shows in the UI.
Implemented in InferlensUI/InferenceState.swift and InferlensCore.

## How it compares to MLPerf Mobile
MLPerf Mobile standardizes cross-backend benchmark scores. Inferlens closes the eval loop
around them: per-run ledger, a thumbs signal, and NDJSON export to offline eval, plus a
visible fallback chain. Measurement is the neighbour; the closed loop is the wedge.

## Why on-device
Privacy (the image never leaves the phone), offline, and zero marginal cost per inference.

Topics: coreml, tensorflow-lite, litert, on-device-ml, edge-ai, swiftui,
swift-concurrency, ios, benchmark, ml-inference
```

Badges are added at rung 31, and only once true — CI green, Apache-2.0, Swift 6.3,
iOS 26 — four maximum. No badge is committed before it is true.
