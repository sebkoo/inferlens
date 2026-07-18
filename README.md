# Inferlens

Point an iPhone at something and it names what it sees, on-device, then writes down how
long that took. The same picture runs through two inference engines behind one interface,
and every run is logged — so the app that classifies images is also the harness that
measures which engine to ship.

[![Swift](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)](.swift-version)
[![iOS](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white)](docs/adr/0001-module-boundaries.md)
[![Xcode](https://img.shields.io/badge/Xcode-26-1575F9?logo=xcode&logoColor=white)](.xcode-version)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue)](LICENSE)
[![Progress](https://img.shields.io/badge/rungs-3%2F32-orange)](docs/ROADMAP.md)
[![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)

*These badges are pins, not scores. Swift 6.3, iOS 26, and Xcode 26 are toolchain
decisions recorded in [ADR-0001](docs/adr/0001-module-boundaries.md) and checkable in
[`.swift-version`](.swift-version) and [`.xcode-version`](.xcode-version) — they state
what the repo targets, not what it has measured. There is no CI or coverage badge, on
purpose: no test has run yet, so a green check would report a result that does not exist;
those arrive at rung 27 with the first passing test. The rungs badge is the one number
here that reports something measured — rung 3 of a 32-rung ladder.*

## Contents

[Start here](#start-here) · [What it does](#what-it-does) ·
[Where it stands](#where-it-stands) · [Tech stack](#tech-stack) ·
[What the job asks for](#what-the-job-asks-for) ·
[Core ML vs TensorFlow Lite](#core-ml-vs-tensorflow-lite-on-ios-which-is-actually-faster) ·
[The state machine](#the-state-machine) · [Limitations](#limitations) ·
[vs MLPerf Mobile](#vs-mlperf-mobile) · [Decisions](#decisions) ·
[How this was built](#how-this-was-built) · [License](#license)

## Start here

Two lists, so no one has to guess which half of the repo they are reading.

**Running on `main` today:**
- The decision record — four ADRs
  ([module boundaries](docs/adr/0001-module-boundaries.md),
  [LiteRT distribution](docs/adr/0002-litert-distribution.md),
  [benchmark scope](docs/adr/0003-benchmark-comparison-scope.md),
  [commit hygiene](docs/adr/0004-commit-hygiene.md)), the
  [prior-art research](docs/research/PRIOR_ART.md), and a
  [32-rung plan](docs/ROADMAP.md).
- The toolchain — version pins, a formatter and linter config, and a
  [Makefile](Makefile) harness shape.
- Commit hygiene — a committed [`commit-msg` hook](.githooks/commit-msg) and a CI lint
  that rejects AI attribution trailers ([ADR-0004](docs/adr/0004-commit-hygiene.md)).
- The module skeleton — an SPM workspace of six empty packages plus a thin app
  placeholder, compiling green under Swift 6 strict concurrency (rung 02); the targets
  do nothing yet.

**Design-stage (decided, written down, not built)** — each item names its rung in
[the roadmap](docs/ROADMAP.md):
- The inference contract and its conformance suite (rungs 03–04)
- Core ML and TensorFlow Lite engines behind that one contract (rungs 06, 09–11)
- The append-only SQL ledger and the NoSQL metadata store (rungs 14–15)
- The fallback chain, the actor-isolated engine, and the SwiftUI state machine (rungs 17–19)
- The signal-capture, export, and on-device benchmark harness (rungs 21–22, 28)

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
Contract        [----------]  rungs 03–04
Engines         [----------]  rungs 06, 09–11
Store & flags   [----------]  rungs 14–16
UI & loop       [----------]  rungs 17–22
Benchmark       [----------]  rungs 28, 32
```

The riskiest assumption is that Google's `TensorFlowLiteC` XCFramework ships an
`ios-arm64_x86_64-simulator` slice and links under Swift 6.3 strict concurrency — the
whole SPM-`binaryTarget` approach rests on it. Rung 09 reads the XCFramework's
`Info.plist` and asserts that slice **before** any engine code exists (rung 11), so if the
assumption is wrong the ladder goes red at the distribution step rather than deep inside
an engine. See [ADR-0002](docs/adr/0002-litert-distribution.md).

## Tech stack

A non-developer should be able to read the whole stack and its state here. `Status` is
`live`, `pinned`, or the rung where it lands.

| Layer | Choice | Version / pin | Status | Why this one |
|---|---|---|---|---|
| Language | Swift | 6.3 | pinned | strict concurrency is the subject, not a checkbox |
| UI | SwiftUI | iOS 26 SDK | pinned | views over an explicit state enum, no engine knowledge |
| Min OS | iOS | 26 | pinned | no install base, so device coverage is [deliberately not a factor](docs/adr/0001-module-boundaries.md) |
| Build | Xcode | 26 | pinned | highest stable toolchain; the betas would cost green CI |
| Packaging | Swift Package Manager | — | rung 02 | six local packages plus one vendored binaryTarget |
| Engine A | Core ML | MobileNetV2 FP16 | rung 06 | Apple's on-device runtime, at its native FP16 |
| Engine B | TensorFlow Lite | C API, 2.17.0 xcframework | rung 09 | [no first-party SPM package](docs/adr/0002-litert-distribution.md), so vendored by checksum |
| SQL | SQLite | append-only ledger + migrations | rung 14 | the run ledger is an append-only log, like a Postgres event table |
| NoSQL | document / KV store | model metadata + flag cache | rung 15 | schema-free model metadata and a cached flag document |
| Concurrency | actors, async/await | strict-concurrency=complete | rung 11 | one [`@unchecked Sendable`](docs/adr/0001-module-boundaries.md) at the C handle, CI-linted |
| Instrumentation | OSSignposter | — | rung 07 | signpost spans around load / preprocess / infer |
| Flags | FeatureFlagProvider | local JSON provider | rung 16 | the seam a remote-config system drops into later |
| CI | GitHub Actions | commit-hygiene live | rung 27 | the trailer lint runs today; build and test land with the code |
| License | Apache-2.0 | — | live | the [patent grant](LICENSE) matters for ML |

## What the job asks for

Capability, where it lives, and the rung that builds it. Almost every row is planned —
stated plainly, not softened.

| The job asks for | Where it lives | Rung |
|---|---|---|
| Swift | every module | rung 02+ |
| SwiftUI | InferlensUI | rung 19 |
| Swift Package Manager | workspace, 6 local packages, 1 binaryTarget | rung 02 |
| TensorFlow Lite, on-device | InferlensLiteRT (vendored xcframework, C API) | rungs 09–11 |
| Core ML | InferlensCoreML | rung 06 |
| SQL | InferlensStore — append-only ledger + migrations | rung 14 |
| NoSQL | InferlensStore — document / KV store | rung 15 |
| async/await, concurrency, background tasks | actor-isolated engine, cancel-on-input-change | rungs 11, 18 |
| AI UX: loading / retry / fallback / non-determinism | InferenceState enum + fallback chain as a value | rungs 17, 19 |
| latency & memory optimization | LatencyRecorder (p50/p95, warm-up discard), OSSignposter | rungs 07–08, 28 |
| feature flags / remote config | FeatureFlagProvider + local JSON provider | rung 16 |
| capturing user signals for AI evaluation | thumbs signal → ledger → NDJSON export | rungs 21–22 |
| production reliability, issues caught early | contract tests, CI, commit-hygiene lint, strict concurrency | rungs 04, 12, 27 |

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

Filled by `make bench` at rung 28. The two models are matched only where matching is
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

## Decisions

- [ADR-0001 — module boundaries](docs/adr/0001-module-boundaries.md)
- [ADR-0002 — LiteRT distribution](docs/adr/0002-litert-distribution.md)
- [ADR-0003 — benchmark comparison scope](docs/adr/0003-benchmark-comparison-scope.md)
- [ADR-0004 — commit hygiene](docs/adr/0004-commit-hygiene.md)
- [Prior-art research](docs/research/PRIOR_ART.md) ·
  [Model provenance](docs/research/MODEL_PROVENANCE.md)
- [The 32-rung roadmap](docs/ROADMAP.md)

## How this was built

Built with an AI agent, with the method kept in the repo rather than in a trailer. The
invariants and forbidden patterns are in [CLAUDE.md](CLAUDE.md) today; a reusable prompt
per rung lands under `docs/prompts/` at rung 30; and the history carries no `Co-Authored-By`
lines — a committed [hook](.githooks/commit-msg) and a CI lint keep them out
([ADR-0004](docs/adr/0004-commit-hygiene.md)). The disclosure is the method, not a
disclaimer.

## License

[Apache-2.0](LICENSE). The patent grant matters for machine-learning code.
