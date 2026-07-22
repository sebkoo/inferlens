# ADR-0014: Cancellation is a contract clause, a transition, and no ledger row

- Status: Accepted — 2026-07-22
- Deciders: maintainer
- Relates to: [ADR-0005](0005-litert-engine-concurrency.md) (the engines are actors whose C calls are
  synchronous and on-actor — the fact that makes cancellation cooperative rather than pre-emptive),
  [ADR-0010](0010-remote-leg-scope.md) (the chain's walk, and the precedent for disclosing work that
  no row can carry), [ADR-0013](0013-remote-leg-realization.md) (the remote leg, whose `URLSession`
  is the one place cancellation is more than a checkpoint, and Decision 4's disclosed
  indistinguishability this ADR partly repairs), [ADR-0006](0006-run-ledger-storage.md) (the ledger
  schema this rung does not migrate), [ADR-0008](0008-latency-summary-boundary.md) (the seam a
  cancelled run must not reach), CLAUDE.md invariant 1 (the ratified brackets, which decide where a
  checkpoint may sit), invariant 3 (the chain is a value), invariant 4 (a state case needs a producer
  AND a consumer), and the ladder's rung 22.

## Context

Ladder line 22 reads, verbatim:

> `22 refactor(engine): engine actor; cancel in-flight Tasks when input changes`

Its first clause was already satisfied when this rung began: `CoreMLEngine` (rung 10), `LiteRTEngine`
(rung 15), `FallbackEngine` (rung 21) and `RemoteEngine` (rung 39) are all `actor`s. What remained is
the second clause, and the reason it lands out of numeric order is technical rather than a
preference: **cancel-on-input-change needs an input-change site, and that site is a driver.** There
was no driver until rung 24 built `ClassificationModel` and rung 29 composed it. The code said so at
the time and named this rung by name:

> Deliberately not cancellable and deliberately not re-entrant: cancelling a superseded run when the
> input changes is its own ladder rung (`refactor(engine)`), and the state machine already holds the
> seam it will plug into (`inferring + classifyBegan -> inferring`). Doing it here would land two
> concerns in one commit.
> — `ClassificationModel.run(_:)`, at rung 24

The seam that comment points at is `InferenceState.applying(_:)`'s `(.inferring, .classifyBegan) ->
.inferring`, written at rung 23 *"so that landing that rung does not have to reopen the table"*. It
did not have to. Three things did have to be decided first, and they are recorded in the order they
were asked.

## Decision 1 — a cancelled run writes NO ledger row

**A cancelled attempt is not a run.** The ledger records runs that answered; a run that was
superseded before it produced an outcome produces no row, no `LatencySample`, and no signal target.

This is the shape the driver already had, made explicit rather than a new rule: `record(_:)` is
reached only on the success path, so a run that throws has never written a row. Cancellation joins
"failed to decode" and "the engine threw" as a third way for a run not to reach it.

No schema version, no new `kind`, no new column, no export-format change.

**The cost, named rather than left to be discovered.** Compute a cancelled run spent vanishes from
the record completely — the preprocessing it did, the load it may have paid, and, when the chain was
walking, whatever a leg burned before the checkpoint stopped the walk. Nothing in the ledger will
ever say that time was spent. That is the same disclosed residue ADR-0010 already carries for a
failed leg's wasted work, extended to a second cause, not a new hole.

One consequence runs the other way and is worth stating because it is the benefit, not an accident:
**p50/p95 stay clean by construction.** A cancelled run never reaches `record(_:)`, so it never
becomes a `LatencySample`, so the recorder never sees it. There is no filtering step anywhere and no
new discard policy — invariant 1's ratified (c) ("the recorder discards nothing") is untouched,
because the recorder is never handed the sample in the first place.

**The option not taken:** a cancelled-run row behind a new `kind`, so the spent compute is visible.
Refused on three counts. It is not what the ledger means by a run — the thesis's loop is *run
inference → append to ledger → capture signal*, and a row nobody can thumb is a row outside the loop.
It costs a schema migration and a `run_degradations` CHECK-constraint change to admit a reason case
that is not a degradation. And it hands every offline-eval reader a row class it must filter on every
read, which is a permanent tax paid for a number no decision depends on.

## Decision 2 — the contract gains a cooperative-cancellation clause, and `InferenceError.cancelled`

This is the rung's real content. A promise made on `InferenceEngine.classify` binds **all five
conformers at once** — `CoreMLEngine`, `LiteRTEngine`, `RemoteEngine`, `FallbackEngine` and
`StubEngine` — which is what makes this a rung rather than a patch to one view model.

**The shape was forced by a fact, not chosen.** `classify` is declared `async
throws(InferenceError)`. Typed throws means `try Task.checkCancellation()` cannot compile inside it:
`CancellationError` does not convert to `InferenceError`. So there were exactly three possibilities —
widen the typed throw (which would spend the contract property that "no native Core ML or LiteRT
error crosses the contract", the reason typed throws is there at all), add a case to
`InferenceError`, or make no promise. The clause is therefore inseparable from the new case; deciding
to promise cancellation *is* deciding to add `.cancelled`.

The clause, as written on the protocol:

- Cancellation is **cooperative and checked at stage boundaries**. It is not pre-emptive and cannot
  be: ADR-0005's whole design is that every C call is synchronous and on-actor, so an in-flight
  `TfLiteInterpreterInvoke` has no suspension point to be interrupted at. An engine promises to
  notice at a boundary, never to abandon a computation mid-flight.
- **Cancelled before compute → `throw .cancelled`**, and no outcome is returned.
- **A completed compute is never retroactively cancelled.** An engine that has produced a result
  returns it. Discarding it is the *caller's* decision (and the driver does discard it — Decision 3),
  because only the caller knows whether the result still matters.

`isRetryable` is `true` for `.cancelled`: the documented question is "could retrying this call
plausibly succeed", and for a call that nothing failed at, it plainly could. The UI never renders it
— the driver swallows `.cancelled` rather than transitioning (Decision 3) — but the taxonomy answer
must be true on its own terms, not shaped by its one consumer.

**The conformance suite asserts it structurally, never by timing.** Two checks, and the rung-31
lesson about what shared hardware can judge is the reason both are shaped the way they are:

- **A** — `classify` entered inside an already-cancelled task throws `.cancelled` and returns no
  outcome. Made deterministic by spinning on `Task.yield()` until cancellation is observed *before*
  the engine is called, so there is no race between `Task.cancel()` and the task starting.
- **B** — cancellation is not sticky: after a cancelled attempt, a later uncancelled `classify` on
  the **same engine instance** returns a conforming outcome.

Neither reads a clock, a duration, or a wall-time bound. Both produce the same verdict on a pinned
local simulator and on a shared, virtualized CI runner.

**What these checks do NOT read**, stated because every check in this repo owes that sentence. They
cannot prove an engine refrains from abandoning a compute that has already finished — pinning that
would require cancelling a task at one exact instant, which is a timing race and would be the
`steadyStateMaxRatio` mistake in a new costume. What B pins instead is the observable consequence: a
cancelled attempt leaves no state behind on the engine. The half of the clause that says a completed
compute still returns is enforced by construction rather than by assertion — no engine has a
checkpoint after its compute (Decision 3), so there is no site at which one could break it.

**A repair to ADR-0013 Decision 4, worth naming.** That decision disclosed that a timeout, a refused
connection and a dropped socket are indistinguishable in the record, all arriving as
`.backendUnavailable`. Without `.cancelled`, a deliberately cancelled remote request would have
joined that bucket — a user's own action reported as a network fault. It no longer does. The other
three remain indistinguishable, exactly as disclosed; cancellation is simply no longer among them.

## Decision 3 — checkpoint placement, and the site that does not exist

Invariant 1 governs this decision entirely: the measurement brackets are ratified, checkpoints sit
**between** them and never inside, and an agent may not change what a bracket measures without a
recorded ratification.

Reading the three engines settles it, because in all of them the brackets are **adjacent**:

```
let clock = ContinuousClock()
let preprocessStart = clock.now
...preprocess...
let inferStart     = clock.now     <-- closes `preprocess` AND opens `infer`. No gap.
...compute...
let inferEnd       = clock.now
```

`inferStart` is a single clock read that both closes one phase and opens the next, so **there is no
"between preprocess and infer" that is outside a bracket.** Any check written there would be measured
as `preprocess` time. It would be small — one flag read — but "small enough not to matter" is exactly
the kind of judgement invariant 1 takes out of an agent's hands, and an agent quietly changing what a
ratified bracket reports is the failure the invariant exists to prevent. So the site was not used,
and it is recorded here as refused rather than left unmentioned.

That leaves, per engine, **exactly one checkpoint**: at `classify` entry, before `let clock =
ContinuousClock()`. It is the only site that can abort having measured nothing, and it is outside
every bracket by construction. There is deliberately none after `inferEnd` either — the contract
clause promises the opposite there.

The sites the engines cannot see belong to the two layers above them:

| Site | Where | Why THERE |
|---|---|---|
| before the load bracket opens | `ClassificationModel.run(_:)` | The only place a run can be abandoned having paid nothing at all. The engines cannot hold this one: `loadModel`'s bracket is the *driver's*, so a check at `loadModel`'s entry would sit inside it. |
| after the load bracket closes, before `.classifyBegan` | `ClassificationModel.run(_:)` | The bracket is shut and `pendingLoad` assigned, so the measurement is complete and untouched; the cheapest place to stop before committing to an inference. |
| after `classify` returns, before `record(_:)` | `ClassificationModel.run(_:)` | The engine deliberately has no post-compute checkpoint, so this is where a superseded result is dropped — and it is upstream of both the recorder and the ledger, which is what makes Decision 1 true by construction rather than by filtering. |
| top of each leg iteration | `FallbackEngine.classify(_:)` | The chain's own boundary, invisible to every engine: the walk is the thing being stopped. It sits before the on-demand-load clock starts, so the chain's bracket is untouched too. |

**The remote leg is the one place this is more than a checkpoint.** `URLSession` genuinely cancels a
request in flight (ADR-0013's engine is a real `URLSession` over a real socket), so `session.data(for:)`
throws when its task is cancelled and the connection is torn down — no checkpoint could achieve that,
and no other leg can offer it. The mapping to `.cancelled` happens in the existing `catch`, which sits
between `inferStart` and `inferEnd`; on that path `inferEnd` is never read and no `RunTiming` is ever
constructed, so **no number is perturbed on any path that produces one**.

**`loadModel` gains no clause and no checkpoint**, and the reason is the same invariant. Its bracket
belongs to the driver, so every site inside it is inside a measurement. Nothing is lost by leaving it
out: the driver's pre-load checkpoint already covers "cancelled before the load", and a load that has
started is a load the next run will legitimately use.

**The chain must never treat `.cancelled` as a leg failure.** A leg that reports cancellation has not
failed, so the walk propagates it immediately instead of stepping down. Without this the chain would
respond to a user's new photo by trying every remaining backend, and — worse — would write
`.fellBack` hops for hops that never happened, putting a fabricated degradation on screen and, had
Decision 1 gone the other way, in the ledger. It holds in `loadModel`'s walk for the same reason.

## Invariant 4 — no new state case, because the consumer does not exist

`InferenceState` is unchanged. A `cancelled` case would have a producer (the driver knows), but
**nothing would ever draw it**: a cancelled run exists only because a new run is already starting, so
the machine's next event is the superseding run's `.classifyBegan`. A case whose every occurrence is
overwritten in the same turn is a case nothing can observe — the `warming` mistake with a different
name.

Cancellation is therefore a **transition, not a state**, and the transition already existed:
`(.inferring, .classifyBegan) -> .inferring`, written at rung 23 for this rung. The screen shows a
spinner over the new photo throughout, which is the truth: something is being classified, and it is
the thing the person just picked.

## Concurrency — invariant 2 holds at zero

Nothing here introduces an `@unchecked Sendable`. `Task.isCancelled` is a read of the current task's
own flag, `Task<Void, Never>` is `Sendable`, and the driver's in-flight handle lives on `@MainActor`.
The count stays **zero** and the CI lint's ceiling of at most one is untouched.

## What this ADR does NOT decide

- **It does not make the driver serialize runs, and that falsifies a prediction written at rung 24.**
  `ClassificationModel`'s invariant-1 note recorded case 3 (two loads before any classify) as
  undecided and predicted the fix: *"making it decided means serializing runs, which is the
  cancel-on-input-change rung's subject."* This rung is that rung, and it does the opposite — it
  **supersedes** runs rather than serializing them. Awaiting a superseded run before starting the new
  one would make a new photo wait behind a compute that ADR-0005 makes uninterruptible, which is a
  worse product than the ambiguity it would close. Case 3 is **narrowed, not closed**: it now also
  requires the superseded run's load to return after the superseding one's. What would close it is a
  shared load task so two overlapping runs cannot both load — a load-deduplication concern, not a
  cancellation one. Recorded as a finding in docs/ROADMAP.md.
- **No pre-emptive cancellation, and none is possible** under ADR-0005's on-actor design. An engine
  never promises to abandon work in progress.
- **No ledger schema change**, no new `DegradationReason`, no `run_degradations` CHECK change.
- **No UI state case**, and no timeout, deadline or auto-cancel policy. The only thing that cancels a
  run is another run starting.
- **No cancellation clause on `loadModel`** — see Decision 3.
- It does not re-open invariant 1's ratified choices. The percentile definition, the cold/warm
  boundary and the warm-up policy are untouched; what was ratified here is *where a checkpoint may
  sit*, which is a placement decision the brackets themselves already determined.

## Consequences

- The contract is what changed, so the guarantee is uniform: a caller holding `any InferenceEngine`
  can cancel and get the same behaviour whichever of the five is behind it — which is the property
  the whole protocol exists for, tested once in the shared suite rather than five times.
- `InferenceError` gains its sixth case. Exactly one exhaustive switch existed over it
  (`isRetryable`), so the blast radius was knowable before the first line was written.
- `LIMITATIONS`-style claims that cancel-on-input-change is unbuilt become false in two places — the
  README's design-stage list and `ClassificationModel.run(_:)`'s own comment — and are retired with a
  keyed claims-audit sweep, the disposition every superseded claim in this repo gets.
