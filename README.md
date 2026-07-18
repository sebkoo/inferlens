# Inferlens

Point an iPhone at something and it names what it sees, on-device, then writes down how
long that took. The same picture runs through two inference engines behind one interface,
and every run is logged — so the app that classifies images is also the harness that
measures which engine to ship.

[![Swift](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)](.swift-version)
[![iOS](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white)](docs/adr/0001-module-boundaries.md)
[![Xcode](https://img.shields.io/badge/Xcode-26-1575F9?logo=xcode&logoColor=white)](.xcode-version)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue)](LICENSE)
[![Progress](https://img.shields.io/badge/rungs-5%2F37-orange)](docs/ROADMAP.md)
[![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)

*These badges are pins, not scores. Swift 6.3, iOS 26, and Xcode 26 are toolchain
decisions recorded in [ADR-0001](docs/adr/0001-module-boundaries.md) and checkable in
[`.swift-version`](.swift-version) and [`.xcode-version`](.xcode-version) — they state
what the repo targets, not what it has measured. There is no CI or coverage badge, on
purpose: no test has run yet, so a green check would report a result that does not exist;
those arrive when CI runs its first passing test. The rungs badge is the one number
here that reports something measured — how many rungs have landed.*

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
  [step-by-step plan](docs/ROADMAP.md).
- The toolchain — version pins, a formatter and linter config, and a
  [Makefile](Makefile) harness shape.
- Commit hygiene — a committed [`commit-msg` hook](.githooks/commit-msg) and a CI lint
  that rejects AI attribution trailers ([ADR-0004](docs/adr/0004-commit-hygiene.md)).
- The module skeleton — an SPM workspace of six empty packages plus a thin app
  placeholder, compiling green under Swift 6 strict concurrency; the targets
  do nothing yet.

**Design-stage (decided, written down, not built)** — each links to
[the roadmap](docs/ROADMAP.md):
- The inference contract (done) and its conformance suite (planned)
- Core ML and TensorFlow Lite engines behind that one contract
- The append-only SQL ledger and the NoSQL metadata store
- The fallback chain, the actor-isolated engine, and the SwiftUI state machine
- The signal-capture, export, and on-device benchmark harness

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
Contract        [##########]  done — InferenceEngine + Sendable value types
Engines         [----------]  Core ML and TensorFlow Lite behind one contract
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
| Engine A | Core ML | MobileNetV2 FP16 | planned | Apple's on-device runtime, at its native FP16 |
| Engine B | TensorFlow Lite | C API, 2.17.0 xcframework | planned | [no first-party SPM package](docs/adr/0002-litert-distribution.md), so vendored by checksum |
| SQL | SQLite | append-only ledger + migrations | planned | the run ledger is an append-only log, like a Postgres event table |
| NoSQL | document / KV store | model metadata + flag cache | planned | schema-free model metadata and a cached flag document |
| Concurrency | actors, async/await | strict-concurrency=complete | planned | one [`@unchecked Sendable`](docs/adr/0001-module-boundaries.md) at the C handle, CI-linted |
| Instrumentation | OSSignposter | — | planned | signpost spans around load / preprocess / infer |
| Flags | FeatureFlagProvider | local JSON provider | planned | the seam a remote-config system drops into later |
| CI | GitHub Actions | commit-hygiene live | planned | the trailer lint runs today; build and test land with the code |
| License | Apache-2.0 | — | live | the [patent grant](LICENSE) matters for ML |

## What the job asks for

Capability and where it lives. Almost every row is planned —
stated plainly, not softened.

| The job asks for | Where it lives |
|---|---|
| Swift | every module |
| SwiftUI | InferlensUI |
| Swift Package Manager | workspace, 6 local packages, 1 binaryTarget |
| TensorFlow Lite, on-device | InferlensLiteRT (vendored xcframework, C API) |
| Core ML | InferlensCoreML |
| SQL | InferlensStore — append-only ledger + migrations |
| NoSQL | InferlensStore — document / KV store |
| async/await, concurrency, background tasks | actor-isolated engine, cancel-on-input-change |
| AI UX: loading / retry / fallback / non-determinism | InferenceState enum + fallback chain as a value |
| latency & memory optimization | LatencyRecorder (p50/p95, warm-up discard), OSSignposter |
| feature flags / remote config | FeatureFlagProvider + local JSON provider |
| capturing user signals for AI evaluation | thumbs signal → ledger → NDJSON export |
| production reliability, issues caught early | contract tests, CI, commit-hygiene lint, strict concurrency |

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
- [The roadmap](docs/ROADMAP.md)

## How this was built

Built with an AI agent, with the method kept in the repo rather than in a trailer. The
invariants and forbidden patterns are in [CLAUDE.md](CLAUDE.md) today; reusable prompts
land under `docs/prompts/`; and the history carries no `Co-Authored-By`
lines — a committed [hook](.githooks/commit-msg) and a CI lint keep them out
([ADR-0004](docs/adr/0004-commit-hygiene.md)). The disclosure is the method, not a
disclaimer.

## License

[Apache-2.0](LICENSE). The patent grant matters for machine-learning code.
