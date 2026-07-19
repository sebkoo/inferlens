<div align="center">

# Inferlens

**Measure on-device inference on your own iPhone — not a vendor's published number.**

An iPhone app that names what it sees without sending the photo anywhere, runs the same
picture through two engines, and logs how long each took — so the app that classifies
images is also the harness that measures which engine to ship.

[![Swift](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)](.swift-version)
[![iOS](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white)](docs/adr/0001-module-boundaries.md)
[![Xcode](https://img.shields.io/badge/Xcode-26-1575F9?logo=xcode&logoColor=white)](.xcode-version)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue)](LICENSE)
[![Progress](https://img.shields.io/badge/rungs-12%2F37-orange)](docs/ROADMAP.md)
[![commit-hygiene](https://github.com/sebkoo/inferlens/actions/workflows/commit-hygiene.yml/badge.svg)](https://github.com/sebkoo/inferlens/actions/workflows/commit-hygiene.yml)
[![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)

</div>

*Most of these badges are pins, not scores. Swift 6.3, iOS 26, and Xcode 26 are toolchain
decisions recorded in [ADR-0001](docs/adr/0001-module-boundaries.md) and checkable in
[`.swift-version`](.swift-version) and [`.xcode-version`](.xcode-version) — they state
what the repo targets, not what it has measured. Two report something measured: the rungs
badge (how many rungs have landed) and the commit-hygiene badge — a scoped workflow badge that
links to [its workflow](.github/workflows/commit-hygiene.yml) and reports exactly that the
AI-trailer lint passes on every push, so a reader can click through and check what it covers.
There is still no generic CI or coverage badge: build and test do not run in CI until rung 26,
so a `CI | passing` badge would imply coverage that does not exist.*

## Contents

[Start here](#start-here) · [What it does](#what-it-does) ·
[Where it stands](#where-it-stands) · [Tech stack](#tech-stack) ·
[What the job asks for](#what-the-job-asks-for) ·
[Core ML vs TensorFlow Lite](#core-ml-vs-tensorflow-lite-on-ios-which-is-actually-faster) ·
[The state machine](#the-state-machine) · [Limitations](#limitations) ·
[vs MLPerf Mobile](#vs-mlperf-mobile) · [FAQ](#faq) · [Decisions](#decisions) ·
[How this was built](#how-this-was-built) · [License](#license)

## Start here

Two lists, so no one has to guess which half of the repo they are reading.

**Running on `main` today:**
- The inference contract and its conformance suite —
  [`InferenceEngine`](Sources/InferlensCore/InferenceEngine.swift) plus
  [`assertConformsToContract`](Sources/InferlensConformance/AssertConformsToContract.swift), an
  engine-agnostic suite proven to have teeth: it passes a conforming
  [`StubEngine`](Sources/InferlensConformance/StubEngine.swift) and deliberately
  [fails a broken one](Tests/InferlensConformanceTests/ConformanceSuiteTests.swift).
- The first real engine —
  [`CoreMLEngine`](Sources/InferlensCoreML/CoreMLEngine.swift), an actor over Apple's FP16
  MobileNetV2 that drives `MLModel` directly so preprocess and infer time apart. It passes that same
  suite against the real model on the simulator
  ([the conformance test](Tests/InferlensCoreMLTests/CoreMLEngineConformanceTests.swift)) — shape
  validated; Neural Engine warm-up and real latency are device-only (see [Limitations](#limitations)).
- The second real engine —
  [`LiteRTEngine`](Sources/InferlensLiteRT/LiteRTEngine.swift), an actor over Google's FP32
  MobileNetV2 through the vendored `TensorFlowLiteC` C API — on-actor, RAII cleanup, and **zero**
  `@unchecked Sendable` ([ADR-0005](docs/adr/0005-litert-engine-concurrency.md)). It passes the same
  conformance suite on the simulator
  ([the conformance test](Tests/InferlensLiteRTTests/LiteRTEngineConformanceTests.swift)); real
  latency is the device-only rung-32 bench.
- The model pipeline — a checksum-pinned MobileNetV2 fetched by
  [`make bootstrap`](scripts/fetch-models.sh), never committed
  ([ADR-0002](docs/adr/0002-litert-distribution.md),
  [provenance](docs/research/MODEL_PROVENANCE.md)).
- The decision record — four ADRs
  ([module boundaries](docs/adr/0001-module-boundaries.md),
  [LiteRT distribution](docs/adr/0002-litert-distribution.md),
  [benchmark scope](docs/adr/0003-benchmark-comparison-scope.md),
  [commit hygiene](docs/adr/0004-commit-hygiene.md)), the
  [prior-art research](docs/research/PRIOR_ART.md), and a
  [step-by-step plan](docs/ROADMAP.md).
- The toolchain and commit hygiene — version pins, a [Makefile](Makefile) harness, and a committed
  [`commit-msg` hook](.githooks/commit-msg) that rejects AI-attribution trailers
  ([ADR-0004](docs/adr/0004-commit-hygiene.md)).
- The module skeleton — an SPM workspace of six local packages plus a thin app placeholder, green
  under Swift 6 strict concurrency; `InferlensCore`, `InferlensCoreML`, `InferlensLiteRT`, and the
  conformance module now carry code, while the store, flags, and UI packages are still skeletons.

**Design-stage (decided, written down, not built)** — each links to
[the roadmap](docs/ROADMAP.md):
- The append-only SQL ledger and the NoSQL metadata store
- The `LatencyRecorder` (p50/p95, warm-up discard) and OSSignposter spans around load / preprocess / infer
- The fallback chain, cancel-on-input-change, and the SwiftUI state machine
- Signal capture, NDJSON export, and the on-device benchmark harness

## What it does

Point the phone at something. It names what it sees — the top three guesses with
confidence — without sending the image anywhere. It runs the same picture through two
engines, Apple's Core ML and Google's TensorFlow Lite, and shows which one answered and
how many milliseconds it took. If the answer is wrong, a thumbs-down records that, and the
correction is written to a local ledger next to the run.

That ledger is the point. Each run stores the input, the engine, the latency, and your
signal, then exports for offline evaluation — which says what to ship next, which changes
what the next run does:

```
run → ledger → signal → export → evaluate → pick a better engine → run
```

A wrapper app calls an API. This one closes a loop.

## Where it stands

```
Decisions       [##########]  done — 4 ADRs + prior art + roadmap
Foundation      [##########]  done — toolchain, license, hooks, CI skeleton
Contract        [##########]  done — InferenceEngine + conformance suite, teeth-tested
Engines         [########--]  Core ML + TensorFlow Lite both conformance-tested on the sim; device latency unproven until the on-device bench (rung 32)
Store & flags   [----------]  append-only SQL ledger + NoSQL metadata
UI & loop       [----------]  fallback chain, actor engine, SwiftUI states
Benchmark       [----------]  on-device harness + the latency table
```

The riskiest assumption is that Google's `TensorFlowLiteC` XCFramework ships an
`ios-arm64_x86_64-simulator` slice and links under Swift 6.3 strict concurrency — the
whole SPM-`binaryTarget` approach rests on it. The LiteRT vendoring step reads the XCFramework's
`Info.plist` and asserts that slice **before** any engine code exists (`InferlensLiteRT`), so if the
assumption is wrong the ladder goes red at the distribution step rather than deep inside
an engine. See [ADR-0002](docs/adr/0002-litert-distribution.md).

## Tech stack

A non-developer should be able to read the whole stack and its state here. `Status` is
`live`, `pinned`, `done`, or `planned`.

| Layer | Choice | Version / pin | Status | Why this one |
|---|---|---|---|---|
| Language | Swift | 6.3 | pinned | strict concurrency is the subject, not a checkbox |
| UI | SwiftUI | iOS 26 SDK | pinned | views over an explicit state enum, no engine knowledge |
| Min OS | iOS | 26 | pinned | no install base, so device coverage is [deliberately not a factor](docs/adr/0001-module-boundaries.md) |
| Build | Xcode | 26 | pinned | highest stable toolchain; the betas would cost green CI |
| Packaging | Swift Package Manager | — | done | six local module packages |
| Engine A | Core ML | MobileNetV2 FP16 | live | Apple's on-device runtime, at its native FP16 |
| Engine B | TensorFlow Lite | C API, 2.17.0 xcframework | live | Google's runtime at native FP32; [vendored by checksum](docs/adr/0002-litert-distribution.md), no first-party SPM package |
| SQL | SQLite | append-only ledger + migrations | planned | the run ledger is an append-only log, like a Postgres event table |
| NoSQL | document / KV store | model metadata + flag cache | planned | schema-free model metadata and a cached flag document |
| Concurrency | actors, async/await | strict-concurrency=complete | live | both engines are actors; LiteRT's C handle stays on-actor at [zero `@unchecked Sendable`](docs/adr/0005-litert-engine-concurrency.md) |
| Instrumentation | OSSignposter | — | planned | signpost spans around load / preprocess / infer |
| Flags | FeatureFlagProvider | local JSON provider | planned | the seam a remote-config system drops into later |
| CI | GitHub Actions | commit-hygiene (trailer lint) | live | trailer lint runs on push from `fix(ci)` forward; build + test deferred to rung 26 |
| License | Apache-2.0 | — | live | the [patent grant](LICENSE) matters for ML |

## What the job asks for

Capability and where it lives. Almost every row is planned —
stated plainly, not softened.

| The job asks for | Where it lives | Evidence |
|---|---|---|
| Swift | every module | live |
| SwiftUI | InferlensUI | planned |
| Swift Package Manager | workspace, 6 local packages, 1 binaryTarget | [Package.swift](Package.swift) |
| TensorFlow Lite, on-device | InferlensLiteRT (vendored xcframework, C API) | [conformance test passes](Tests/InferlensLiteRTTests/LiteRTEngineConformanceTests.swift) on the sim; device latency is the rung-32 bench |
| Core ML | InferlensCoreML | [conformance test passes](Tests/InferlensCoreMLTests/CoreMLEngineConformanceTests.swift) |
| SQL | InferlensStore — append-only ledger + migrations | planned |
| NoSQL | InferlensStore — document / KV store | planned |
| async/await, concurrency, background tasks | actor-isolated engine, cancel-on-input-change | [CoreMLEngine actor](Sources/InferlensCoreML/CoreMLEngine.swift), partial |
| AI UX: loading / retry / fallback / non-determinism | InferenceState enum + fallback chain as a value | planned · [ADR-0001](docs/adr/0001-module-boundaries.md) |
| latency & memory optimization | LatencyRecorder (p50/p95, warm-up discard), OSSignposter | planned |
| feature flags / remote config | FeatureFlagProvider + local JSON provider | planned |
| capturing user signals for AI evaluation | thumbs signal → ledger → NDJSON export | planned |
| production reliability, issues caught early | contract tests, CI, commit-hygiene lint, strict concurrency | [conformance suite](Sources/InferlensConformance/AssertConformsToContract.swift) live |

This table is the contract. The commits are the receipt.

## Core ML vs TensorFlow Lite on iOS: which is actually faster?

This is the question the repo exists to answer, and the table is empty because the answer
does not exist yet. It will hold measured runs and nothing else — every row will name the
device and iOS version that produced it, and no number will appear here that a phone did
not report.

| Engine | Device / iOS | Cold p50 | Cold p95 | Warm p50 | Warm p95 | Peak mem |
|---|---|---|---|---|---|---|
| Core ML | — | — | — | — | — | — |
| TensorFlow Lite | — | — | — | — | — | — |

Filled by `make bench` on-device. The two models are matched only where matching is
honest — see [Limitations](#limitations) and
[ADR-0003](docs/adr/0003-benchmark-comparison-scope.md).

## The state machine

```
idle → loadingModel → warming → inferring → success(degraded:)
                                    │                     ▲
                                    ▼                     │
                               failed(retryable:) ────────┘
```

Cold start, model load, thermal throttle, and OOM each map to a named state, and backend
fallback (TensorFlow Lite → Core ML → remote) is a value, so degradation is visible rather
than silent. This is the on-device analogue of a server AI UX — connecting, streaming,
retry, fall back to a cheaper model — where model load is first-token latency, thermal
throttle is the degraded state, and the fallback chain is the cheaper-model path
([ADR-0001](docs/adr/0001-module-boundaries.md)).

## Limitations

Read these before the plan.

- **An ecosystem comparison, not a controlled runtime benchmark.** The two MobileNetV2
  models have different weights and different native precision — Apple's is FP16, Google's
  is FP32 — and Core ML may execute at FP16 on the Neural Engine regardless. The precision
  gap is a property of each ecosystem, reported rather than hidden
  ([ADR-0003](docs/adr/0003-benchmark-comparison-scope.md)).
- **The `infer` spans are comparable, not perfectly symmetric.** Both engines draw the
  preprocess/infer boundary the same way at the API level (data marshalling in `preprocess`, the
  compute call alone in `infer`), but the APIs expose different internal marshalling: LiteRT's input
  copy is explicit and counted as `preprocess`, while Core ML's `prediction()` includes input
  conversion and output wrapping inside the call — so Core ML's `infer` is inherently a little more
  inclusive. Disclosed, not removed ([ADR-0003](docs/adr/0003-benchmark-comparison-scope.md)).
- One architecture (MobileNetV2), one task (image classification).
- The remote fallback is a stub; there is no server.
- No App Store build — this is a code and benchmark artifact, not a shipping app.
- No numbers yet. When they arrive, each will name its device and iOS version.

## vs MLPerf Mobile

[MLPerf Mobile](https://github.com/mlcommons/mobile_app_open) standardizes cross-backend
benchmark scores across devices, and it is the closest neighbour to this work. Inferlens
does something adjacent, not larger: it closes an evaluation loop around the numbers — a
per-run ledger, a thumbs signal, NDJSON export to offline eval — and makes the fallback
between engines a visible state. Measurement is the neighbour. The closed loop is the point.

## FAQ

**Is this an App Store app?** No — it is a code and benchmark artifact. A reviewer reads the source;
nobody installs it, so device coverage is deliberately
[out of scope](docs/adr/0001-module-boundaries.md).

**Why build both Core ML and TensorFlow Lite?** The question the repo exists to answer is which is
faster on iOS, and a comparison needs both sides, each at its ecosystem's native precision. The
fallback chain (TensorFlow Lite → Core ML → remote) needs both too. Why these two vendor artifacts and
not a fake-controlled FP32/FP32 pair is
[ADR-0003](docs/adr/0003-benchmark-comparison-scope.md).

**Can I run it without the model?** No. [`make bootstrap`](scripts/fetch-models.sh) fetches the
checksum-pinned MobileNetV2 into `Vendor/Models/` (git-ignored); a plain `swift build` alone does not
yield a working engine ([provenance](docs/research/MODEL_PROVENANCE.md)).

**What does "Inferlens" mean?** Inference plus lens — a lens you point at your own device to measure
its on-device inference, rather than trusting a vendor's published number.

**How was it built?** Agent-directed, with the method kept in the repo, not in a commit trailer — see
[How this was built](#how-this-was-built).

## Decisions

- [ADR-0001 — module boundaries](docs/adr/0001-module-boundaries.md)
- [ADR-0002 — LiteRT distribution](docs/adr/0002-litert-distribution.md)
- [ADR-0003 — benchmark comparison scope](docs/adr/0003-benchmark-comparison-scope.md)
- [ADR-0004 — commit hygiene](docs/adr/0004-commit-hygiene.md)
- [ADR-0005 — LiteRT engine concurrency](docs/adr/0005-litert-engine-concurrency.md)
- [Prior-art research](docs/research/PRIOR_ART.md) ·
  [Model provenance](docs/research/MODEL_PROVENANCE.md)
- [The roadmap](docs/ROADMAP.md)

## How this was built

Built with an AI agent, with the method kept in the repo rather than in a commit trailer. Four
pillars, each with a plain verdict — `working`, `partial`, or `design-stage` — and the artifact that
proves it. Where a claim outran its evidence, the weaker truth is written here.

**Context engineering — working.** [CLAUDE.md](CLAUDE.md), the four [ADRs](docs/adr), and the
[roadmap](docs/ROADMAP.md) make a session resumable by reading the repo instead of re-explaining it. A
fresh session opened at rung 12 quoted [CLAUDE.md](CLAUDE.md) invariant 1 verbatim and it changed what
got built: the human hand-writes the biasable part of the measurement — the percentile aggregation, the
cold/warm split, the warm-up discard — while the mechanical per-engine clock brackets are agent-written
and human-reviewed (invariant 1, relaxed and recorded at rung 15).

**Prompt engineering — working.** The driving prompt is now a committed artifact from rung 15 forward —
[`docs/prompts/rung-15-litert-engine.md`](docs/prompts/rung-15-litert-engine.md) is the first, and it
records both the instruction and where reality falsified it (the "one `@unchecked Sendable`" the prompt
assumed became zero; an `isolated deinit` crashed and became RAII — [ADR-0005](docs/adr/0005-litert-engine-concurrency.md)).
Earlier rungs' prompts lived in session handoffs and are **not** reconstructed: a backfilled prompt
would not be the one that ran, and inventing it would be the fabrication this repo bans.

**Harness engineering — partial.** The standing, committed gates are teeth-tested: the checksum gate
refuses a mismatched pin — [`fetch-models.sh`](scripts/fetch-models.sh) on a model's sha256 and
[`vendor-litert.sh`](scripts/vendor-litert.sh) on the LiteRT archive's, with the `binaryTarget` checksum
covering the extracted xcframework (fail-closed at each); the conformance suite
[fails a deliberately broken engine](Tests/InferlensConformanceTests/ConformanceSuiteTests.swift)
(`testSuiteFailsOnUnsortedClassifications`) and bad model bytes
[fail to load cleanly](Tests/InferlensLiteRTTests/LiteRTEngineConformanceTests.swift)
(`testLoadFailsCleanlyOnBadModelBytes`); and [`make land` / `make readme-sync`](Makefile) plus the
[commit-msg hook](.githooks/commit-msg) keep the ladder and its trailers honest. Two rung-15 checks were
run **once, by hand, and are not in CI** — the `LiteRTEngine` survived a 5× run-tests-until-failure loop
and an AddressSanitizer pass; one-off verifications, not standing gates. The gate that should be
standing is not: CI runs the commit-hygiene lint only, and build + test wait for rung 26 — so nothing
automated compiles or runs the suite on a push. That gap is the self-correction below.

**Loop engineering — split.** The developer loop — prompt → context → harness → review-at-a-gate →
land — is live and visible in the commit history. The product eval loop — run → ledger → signal →
export → evaluate — is design-stage: [Store](Sources/InferlensStore/InferlensStore.swift),
[UI](Sources/InferlensUI/InferlensUI.swift), and [Flags](Sources/InferlensFlags/InferlensFlags.swift)
are three-line skeletons and no eval-loop doc exists yet. The loop the top of this README describes is
the plan, not the built state; the first screen to wire run → state → signal end to end is a planned
rung ([roadmap](docs/ROADMAP.md), 23–25).

**The self-correction.** The harness caught a lot and missed one for weeks. The CI workflow committed
at rung 00 had a YAML syntax error — an unquoted colon in a `TODO` echo — that made GitHub reject the
whole file: zero jobs ran on all 15 pushes, commit-hygiene included, while the README implied it was
already live. The harness never surfaced it; a human reading the Actions tab did. Fixed in
[`fix(ci)` 17ec057](https://github.com/sebkoo/inferlens/commit/17ec057) — the repo's
[first green CI run](https://github.com/sebkoo/inferlens/actions/runs/29658770457) — a validated
commit-hygiene workflow that runs on every push, with build and test deferred to rung 26. Recorded
here because a method that only reports its wins is not one you can trust.

The disclosure is the method, not a per-commit disclaimer
([ADR-0004](docs/adr/0004-commit-hygiene.md)).

## License

[Apache-2.0](LICENSE). The patent grant matters for machine-learning code.
