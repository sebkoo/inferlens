# ADR-0010: What the remote leg IS — a stub that always throws, in a chain that walks to load

- Status: Accepted — 2026-07-20
- Deciders: maintainer
- Relates to: [ADR-0009](0009-document-store-scope.md) (the decision standard this one is held
  to), [ADR-0005](0005-litert-engine-concurrency.md) (engine concurrency — the chain owns no
  handle), [ADR-0001](0001-module-boundaries.md) (module boundaries), CLAUDE.md invariant 1 (the
  ratified cold/warm boundary, applied here), invariant 3 (the chain is a value), invariant 4
  (every state case needs a producer), and the ladder's rung 21.

## Context

The ladder line reads "fallback chain LiteRT -> CoreML -> remote stub as a VALUE (not if-else)".
The chain's first two legs exist; what the third IS decides whether this rung ships a producer
for the degradation pipe the repo already built, or a module wearing a network hat. Decided
before any code, on the thesis — the ADR-0009 discipline: name what each option provides that
nothing else does, and record the option not taken as carefully as the one taken.

## Decision 1 — the remote leg is a stub that ALWAYS THROWS

- It never returns a canned outcome. A fabricated success would flow through the sink into the
  ledger and out the NDJSON export as fake eval data — the benchmark-fabrication ban applied to
  the eval corpus. The eval loop is the product loop; poisoning one poisons both.
- It throws `.backendUnavailable` — a named error from the shared `InferenceError` vocabulary a
  real remote would use, so a future swap is drop-in and the degradation-reason strings do not
  churn.
- It throws from `loadModel()` primarily. The contract requires `loadModel()` not to return until
  the engine can infer at steady-state speed; a stub that can never infer would lie through the
  type contract by loading successfully. `classify` also throws, as defense-in-depth if ever
  reached.
- The reach-condition, stated honestly: the remote leg is consulted only after BOTH on-device
  engines have failed. In the shipping app it is nearly unreachable. Recorded so nobody reads the
  chain as implying live remote traffic — there is none.
- The stub is a chain ENTRY, not a conforming engine. The conformance suite runs over the CHAIN,
  which passes via its real legs; it is never run over the stub alone. An engine whose load
  always throws cannot satisfy the suite and is not claimed to.

## Decision 2 — the chain walks to first success, and a step-down run is a COLD run

Both choices here decide what the ledger's `is_cold` and `load_ns` mean, which is the cold/warm
boundary's territory (CLAUDE.md invariant 1). Both are maintainer-ratified in this ADR and may
not drift without a recorded re-ratification. The comment at the chain's `classify` records the
ratification in these words.

- `loadModel()` tries legs in priority order and stops at the first that loads. Legs above the
  active one are excluded for the chain's loaded lifetime, each exclusion carrying a
  `.fellBack(from:to:)` hop that joins every subsequent outcome's reasons. Legs below stay
  unloaded and untouched.
- With a healthy primary, startup cost, resident memory, and cold `load_ns` are identical to the
  single-engine app — chain rows stay comparable to the rows already in the ledger.
- A per-call step-down loads the next leg on demand, inside `classify`. That on-demand load IS a
  load, so rung 12's ratified boundary already defines the case: cold is the first run after a
  load, total carrying the load cost. The step-down run is therefore recorded as the fallback
  backend's COLD run — `is_cold` set, `load_ns` = the emergency load, total carrying it, from/to
  named in the `fellBack` hop. No new column, no unrecorded load; eval segments naturally by
  backend + `is_cold`.
- The only unrecorded residue is the FAILED attempt's wasted time — the work a leg spent before
  it threw, which is genuinely unattributable to a row whose `backend` is the leg that answered.
  Disclosed here, with the hop reason on the row as its marker.
- The emergency-loaded leg stays loaded. A leg that failed a LOAD is excluded for the chain's
  lifetime; a leg that failed a CALL is retried on later calls while it remains loaded.
- Load-time hops and per-call hops share one vocabulary — which is also the shape a real remote's
  no-connectivity failure takes, so a future swap keeps its semantics.

## Failure semantics — decided here, stated again at the type

A chain where every leg fails throws the LAST leg's error. Earlier errors are not preserved as
values: the hop reasons record THAT legs failed, never why. A failed walk produces no outcome and
no ledger row, so its per-call hops die with the throw — they never leak into a later success.
One consequence is named rather than implied: the last leg is the stub, so a total failure always
surfaces `.backendUnavailable` (retryable) even when the real blockers were permanent load
failures. That is the cost of the last-error rule, accepted because no result exists to carry
anything richer, and `InferenceError` carries no payload to smuggle a history into.

### The outcomes that were available and were not taken

**A real remote endpoint** (recorded at the ADR-0009 standard). What it alone would provide: an
API contract, timeout-shaped degradation reasons, and a no-network test discipline. What unblocks
it: a server the test suite can actually stand up — a local test server in the suite is provable;
a hardcoded third-party URL is not, and does not qualify. Not taken because the repo cannot prove
it today. The stub keeps the swap drop-in: same error vocabulary, same hop shape, same seam.

**Eager-load every leg** (Decision 2's first alternative). Every load cost lands inside the
`loadModel()` bracket and a step-down answers instantly from a warm leg. Rejected because every
launch would pay both engines' loads and hold both models resident for a leg that answers almost
never, and cold `load_ns` would stop being comparable to the single-engine rows already in the
ledger.

**Load-time fallback only** (the second alternative). No on-demand load can exist — but a
transient per-call failure would then fail the run beside a healthy adjacent leg. A chain that
cannot step down on a call error is a chain in name only.

**Streaming** — explicitly out, named in "does not decide" below.

## What this ADR does NOT decide, and does not read

- No server, no API shape, no URL. The remote leg's whole contract is one thrown error.
- No new UI state case and no new `DegradationReason` case. The existing vocabulary carries every
  hop; a state with no producer would repeat the `warming` mistake invariant 4 records.
- A streaming surface is not this rung's, and is not the chain's. Classification is one-shot; a
  `streamingPartial` case with a stub token producer would be the first dishonest state this repo
  ever shipped. If streaming is ever built it is its own rung with its own real producer and its
  own ADR — it is not smuggled into the chain.
- It does not re-open the conformance suite's invariants (stable backend across two runs, the
  steady-state ratio). The chain is tested against them as one more engine, unchanged.
- It does not change the on-screen session summary's scope (ADR-0008): the ledger row is the
  segmentable record; the screen's aggregate remains a session aggregate.

## Consequences

- A new module holding the chain and the stub, depending on `InferlensCore` only — the chain
  holds legs as `any InferenceEngine` and never names a concrete engine. ADR-0001's module
  diagram gains one name (the rung-12 "6 → 7" precedent, now 8); the app target remains the only
  place concrete engines are named.
- `InferenceOutcome` gains the one channel Decision 2 requires: an optional on-demand load
  duration, `nil` for every plain engine (the driver's own `loadModel()` bracket keeps composing
  cold/warm as today), set by the chain when a step-down paid a load inside the call. The driver
  gives it precedence when composing the `LatencySample`. It carries the sample's own unit — a
  `Duration`, like `LoadTiming.cold` — so the one existing conversion site in the store keeps
  owning the nanosecond encoding. No ledger column changes.
- The composition swap is one line at the app's engine line. The sink's hardcoded `model:`
  becomes a switch on `outcome.backend`, so a fallback run's ledger row names the model that
  actually answered — the row and the screen state the same fact.
- Invariant 4 gains producers today: a LiteRT load failure in the shipped app now surfaces as
  `success(degraded: [.fellBack(from: .liteRT, to: .coreML)])` instead of a dead end, and the
  all-legs-fail walk is a real producer for `failed(retryable:)`.
- The chain's `descriptor` is the preferred leg's (the protocol requirement is nonisolated and
  fixed at init); the ledger's model columns are chosen at composition from `outcome.backend`,
  never from the chain's descriptor.
