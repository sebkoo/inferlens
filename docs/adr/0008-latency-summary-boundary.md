# ADR-0008: Where the latency summary crosses the UI boundary

- Status: Accepted — 2026-07-20 (rung 24, the screen)
- Deciders: maintainer
- Relates to: [ADR-0001](0001-module-boundaries.md) (module boundaries, dependency direction),
  [ADR-0003](0003-benchmark-comparison-scope.md) (what a latency number may claim),
  CLAUDE.md invariants 1 (timing code), 4 (UI states), and 7 (every number carries its device + iOS).

## Context

Rung 24 puts p50/p95 on screen. Nothing about that is obvious, because the number and the
screen live on opposite sides of a boundary the repo enforces:

- p50/p95 are produced by [`LatencyRecorder`](../../Sources/InferlensBench/LatencyRecorder.swift)
  in **InferlensBench**.
- **InferlensUI** depends on **InferlensCore** and nothing else — one line in
  [`Package.swift`](../../Package.swift), and a CI dependency-lint at rung 31 that fails any
  arrow pointing sideways.

So `InferlensUI` cannot name `LatencySummary` while it lives in Bench, and cannot be allowed to
compute one itself: invariant 1 makes the percentile definition, the cold/warm boundary and the
warm-up policy **maintainer-ratified choices with exactly one implementation**. A second
percentile in the view layer would not be a duplication of code, it would be a second definition
of the benchmark — the failure this repo's whole measurement path is arranged to prevent.

Three shapes were considered. Naming them is the decision; the code is the consequence.

## Decision

**Lift the summary VALUE TYPES — `Percentiles`, `TimingBreakdown`, `LatencySummary` — into
InferlensCore. The computation, and every ratified biasable choice, stays in InferlensBench.**

`InferlensUI` names the Core type. It never computes one: the screen's driver takes a summarizing
**function** supplied by whoever composes it —

```swift
public init(engine: any InferenceEngine, summarize: (@Sendable ([LatencySample]) -> LatencySummary?)? = nil)
```

— which the app target (rung 29) satisfies with `{ try? LatencyRecorder().summarize($0) }`, one
line, no adapter and no mapping. Dependency inversion at the same seam the engine already uses:
UI holds the protocol and the value types, never the implementation.

Invariant 7 rides along. A latency figure with no device and no OS is not a number this repo
permits, so the screen does not accept a bare summary — it accepts a
[`LatencyReadout`](../../Sources/InferlensUI/LatencyReadout.swift), which is the Core
`LatencySummary` **plus** the device and OS labels that produced it. The two cannot be separated
by a caller who forgets, because they are one value. `DeviceIdentity` itself stays in
InferlensStore and is passed as text: it needs `ProcessInfo` and `uname`, and Core has no imports
at all — dragging Foundation into the zero-dependency root to save a string field would be a much
larger change than the one it prevents.

### What this decision does NOT decide, and does not read

Written out because a decision that states only what it covers reads as covering more than it
does — the same rule the gates follow.

- It does **not** touch a biasable choice. The percentile definition (a), the cold/warm boundary
  (b) and the warm-up policy (c) stay exactly where they were ratified: in comments at the code in
  `LatencyRecorder.swift`. The types moved; not one line of arithmetic did.
- It does **not** make the boundary compiler-enforced. The moved types need `public` memberwise
  initializers to be constructible from Bench, so `InferlensUI` *could* fabricate a
  `LatencySummary` out of thin air. Nothing stops it but review — the same footing as the on-actor
  discipline in [ADR-0005](0005-litert-engine-concurrency.md), and recorded here rather than
  implied.
- It does **not** say where model-load time is measured. That is timing code, it is new at rung 24,
  and it is called out in the rung's commit for ratification rather than settled here.
- It says nothing about the *content* of a number. Whether a figure may be quoted at all is
  ADR-0003 and invariant 7; this ADR is only about which module may hold it.

## Alternatives rejected

**The app composition hands the view an already-computed value.** This is what CLAUDE.md's "the app
target is thin: composition only" reads like at first, and it is the shape actually adopted — but
only *after* the types moved. On its own it does not work, because the view has to **name** the
type of what it is handed. Without the move, "hand it a value" forces InferlensUI to declare its
own parallel struct with the same two fields, and the composition to write a field-by-field
mapping. That gives two definitions of "p95" — a Bench one and a UI one — with an adapter in the
app target that no test target can reach, because a test that imported both would be the only place
the two ever met. Rejected for the duplication, not for the composition; the composition survives
as the closure above.

**The view takes formatted strings only.** Cheapest, and wrong in the direction this repo cares
about. Formatting is a rendering decision, and rendering decisions live in the UI module — that is
already settled by `DegradationReason.displayText`, which sits in InferlensUI precisely so Core
carries nothing a designer would want to change. Pushing `"12.4 ms"` up into the app target moves
rendering into the thin composition layer and leaves it untestable at the same time: a string is
the one thing a test cannot check the meaning of. It also destroys the readout's structure —
cold/warm, p50/p95 and the sample count would arrive as prose, so the view could not decide that a
p95 over three runs is worth marking as thin evidence.

**Leave the types in Bench and let InferlensUI depend on it.** Rejected on sight. It is the arrow
ADR-0001 forbids, and it would put an aggregation module in the dependency closure of every view.

## Consequences

- One definition of p50/p95 in the repo. The number on the screen, the number the README's
  Cold/Warm table will hold, and the number `make bench` will emit at rung 32 are the same type —
  they cannot drift, because there is nothing to drift from.
- InferlensCore grows a section no engine method mentions. That is not new: `LatencySample` and
  `LoadTiming` are already there, are named by no protocol requirement, and exist for the benchmark
  path alone. Core is the vocabulary a run is described in, not only the engine's obligations, and
  the summary of a set of `LatencySample`s belongs beside the samples. The criterion is the one
  `LatencyRecorder`'s own header states: a recorder is *computation over* those types, not a type —
  so the computation stayed and the types moved.
- The three types gain `Equatable` alongside `Sendable`. A widening, no behaviour change: it is
  what lets a test assert an exact readout rather than picking it apart field by field.
- `InferlensBench`'s public API is unchanged. `summarize` returns the same names; consumers now
  reach them through `import InferlensCore`, which every consumer of `LatencySample` already had.
