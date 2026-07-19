# ADR-0001: Module boundaries

- Status: Accepted — 2026-07-17 (amended 2026-07-18: module set 6 → 7, added InferlensBench at rung 12)
- Deciders: maintainer
- Relates to: the module-implementation ladder; JD must-haves (protocol-oriented design, Core ML,
  TensorFlow Lite, SQL + NoSQL, feature flags, SwiftUI, Swift 6 concurrency).

## Context

The MVP is one screen: pick or capture an image → classify on-device → show top-3
labels with confidence, the active backend, and latency p50/p95 → thumbs up/down →
append everything to a local ledger. That one screen must exercise every JD line.
Modules exist to make each JD clause legible and independently testable. A module that
maps to no JD clause is cut.

## Decision — modules and dependency direction

Local SPM packages; the app target is thin (composition only).

- **InferlensCore** — protocols + value types only (`InferenceEngine`, `ModelDescriptor`,
  `LatencySample`, `InferenceOutcome`). Zero dependencies. The contract.
- **InferlensCoreML** — Core ML implementation of the contract.
- **InferlensLiteRT** — LiteRT implementation of the same contract (vendored
  `binaryTarget`; see ADR-0002).
- **InferlensStore** — SQL append-only run ledger + versioned migrations; NoSQL
  document/KV store for model metadata + flag cache.
- **InferlensFlags** — `FeatureFlagProvider` + local JSON provider; `EntitlementProvider`
  seam.
- **InferlensUI** — SwiftUI views + the `InferenceState` machine; no engine knowledge.
- **InferlensBench** — benchmark aggregation: `LatencyRecorder` turns a session's
  `LatencySample`s into the p50/p95 Cold/Warm summary the README table reports. It is
  computation OVER Core's timing value types, not a type or the contract, so it lives above
  Core rather than in it (Core stays zero-dependency, value-types-only); the aggregation is
  agent-written, maintainer-decided per CLAUDE.md invariant 1 (third correction). Added at rung 12
  — the module set grew 6 → 7.

**Dependency direction (one way):** `app → {UI, Store, Flags, CoreML, LiteRT, Bench} → Core`.
Core depends on nothing. Engines never depend on each other. UI depends on Core's value
types and the engine *protocol*, never a concrete engine. A CI dependency-lint fails any
arrow that points back toward an engine or into Core.

## JD-clause map (a module mapping to nothing is cut)

| Module | JD clause it answers |
|---|---|
| InferlensCore | protocol-oriented design; testable contracts |
| InferlensCoreML | Core ML; on-device inference |
| InferlensLiteRT | TensorFlow Lite; SPM binary integration (ADR-0002) |
| InferlensStore | SQL (append-only ledger + migrations) **and** NoSQL (doc/KV) |
| InferlensFlags | feature-flag / remote-config seam; entitlement seam |
| InferlensUI | SwiftUI; explicit state machine |
| InferlensBench | latency optimization; the p50/p95 benchmark that fills the README table |
| app target | composition; Swift 6 strict concurrency; actor isolation |

## The equivalence argument (an interviewer will ask)

Server AI UX is `connecting → streaming → retry-on-transient → fallback-to-cheaper-model
→ degraded/error`. The on-device analogue is one-to-one:

- cold start / model load = connecting & first-token latency → `loadingModel`
- discarded warm-up runs → `warming`
- thermal throttle forcing a lower backend → `success(degraded: true)`
- OOM / transient load failure → `failed(retryable: true)`
- the `LiteRT → Core ML → remote` fallback chain **is** "fall back to a cheaper model"

UI states are an explicit enum, never booleans, and degradation is always visible in the
UI — never silent. This is the on-device analogue of streaming/retry/fallback AI-UX.

## Deployment target

iOS 26 / Xcode 26 / Swift 6.3 (decided 2026-07-17). Device coverage is **deliberately
excluded** — this repo has no install base; a reviewer reads the code, nobody installs
it from the App Store. The highest **stable** floor is chosen because green CI is
load-bearing and Swift 6 strict concurrency + StoreKit 2 are fully mature at 6.3; the
iOS 27 / Xcode 27 / Swift 6.4 WWDC-2026 betas buy nothing for reading clarity and cost
green CI. An interviewer should see a chosen constraint, not an accepted default.

## Invariants (forbidden-pattern list; mirrored in CLAUDE.md)

- **Timing code — agent-written, human-decided, human-reviewed.** The measurement path (the
  per-engine brackets and the `LatencyRecorder` aggregation) is agent-written and human-reviewed;
  the biasable choices are maintainer-decided and documented at the code, and none may change
  without a recorded ratification (CLAUDE.md invariant 1, third correction). The recorder discards
  nothing — the cold run is reported, not dropped.
- **The fallback chain is a value**, not an `if`-ladder.
- **UI states are an enum:** `idle | loadingModel | warming | inferring |
  success(degraded:) | failed(retryable:)`.
- **At most one `@unchecked Sendable`** in the whole codebase — reserved for the LiteRT
  C-handle boundary, and only if a design requires it. It is a ceiling, not a quota: the
  shipped on-actor `LiteRTEngine` requires **zero** (the actor serializes every synchronous C
  call; `TfLiteInterpreter*` is a non-Sendable, non-thread-safe handle — ADR-0005). A second
  `@unchecked Sendable`, or one away from that boundary, fails the CI lint that enforces **at
  most one**. **Named risk:** correctness depends on the actor being the sole owner/serializer
  of the interpreter.

## Consequences

- Six small packages + a thin app: more `Package.swift` boilerplate, but each JD clause
  is independently testable and the dependency graph is a diagram, not a claim.
- Cross-engine work (the fallback chain, cross-model agreement measurement) lives *above*
  the engines — in the composition layer — never inside an engine.

## A constraint the timing contract imposes

`LatencySample` splits a run into `load` / `preprocess` / `infer`, each measured separately,
because the benchmark exists to show where the time goes. That split requires each engine to
**own its preprocessing**, so that a boundary between `preprocess` and `infer` exists to time.

Consequence for the Core ML engine: Core ML's `VNCoreMLRequest` fuses resize/crop/normalize
into the prediction, leaving no boundary to measure — so **the Core ML engine must drive
`MLModel` directly, not
Vision.** If that proves wrong and preprocessing cannot be separated, `preprocess` collapses
into `infer` and the README's Cold/Warm table loses a column. Written as a constraint now
rather than discovered during Core ML implementation.

## Alternatives rejected

- **One app target, no packages** — fails to make boundaries legible; the JD map would be
  aspirational rather than enforced by the compiler.
- **Engines aware of each other (for fallback)** — rejected; fallback is a value composed
  above the engines, so degradation is observable and testable without engine coupling.
