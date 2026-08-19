# Prompt — the fallback chain

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

> Driving prompt — rung 21: the fallback chain as a value, and the remote leg's honest shape
>
> Step 0 — the scope decision, before any code (the ADR-0009 discipline). The ladder line says
> "fallback chain LiteRT → CoreML → remote stub as a VALUE". Decide, in ADR-0010, what the remote
> leg IS — and decide it on the thesis, not on wishes:
>
> Stub-only (the ladder as written): a third chain entry that always fails or returns a canned
> refusal, existing to prove the chain's degradation surfacing end to end. Smallest honest scope.
> Invariant 4 gains producers for fallback degradation TODAY.
> Real remote endpoint: an actual network classify call. Earns "backend APIs" but needs a server
> story, an API contract, timeouts as named degradation reasons, and a no-network test discipline.
> Decide what the repo can PROVE without a production server — a local test server in the suite is
> provable; a hardcoded third-party URL is not.
> A streaming surface does not fit THIS rung honestly: classification is one-shot, and a streaming
> state with no real token producer is the warming mistake again. If a streaming AI surface is
> ever built, it is its own rung with its own producer (e.g. a describe-the-result feature),
> justified by a thesis clause in its own ADR — not smuggled into the chain. Name this explicitly
> in ADR-0010's "what this does not decide."
>
> The decision standard is ADR-0009's: name what each option provides that nothing else does, and
> record the option not taken as carefully as the one taken. The maintainer decides via the review
> loop before implementation starts.
>
> Step 1 — the chain as a value that satisfies the engine contract. FallbackEngine (name per
> taste) holding [any InferenceEngine] in priority order — LiteRT, CoreML, remote-per-ADR-0010 —
> itself conforming to InferenceEngine, so assertConformsToContract runs over the CHAIN as one
> more engine. Composition swaps one engine for the chain in ONE line (the rung-29 comment said
> "deliberate, reversible" — this is the reversal proving it). Requirements already written down:
>
> The chain is DATA — an array walked in order, never an if-ladder (invariant 3 verbatim).
> Every hop is a DegradationReason with from_backend/to_backend named; the reasons flow into
> success(degraded:) AND the ledger row's existing columns — screen and ledger state the same
> fact. The NDJSON export then carries them with no new work (rung 26 already passes those columns
> through — verify, don't assume).
> A chain where every leg fails maps to failed(retryable:) with the LAST error, reasons list
> intact — decide and test whether earlier errors are recorded or only the final one, and say so
> at the type.
> Concurrency per ADR-0005: the chain owns no handle; it awaits actors. Zero @unchecked.
> Tests: the conformance suite over the chain; hop-recording asserted with stub engines that fail
> on cue (the SinkSpy/@MainActor precedent); the all-legs-fail path; and the one-line composition
> swap compiles both ways.
>
> Step 2 — the screen shows the degradation. No new state case unless a producer exists. The
> existing success(degraded:) list renders the hops; the result view's degradation line gains the
> from→to naming if it lacks it. Screenshot fixtures: if the view changes, the six regenerate and
> the caption sha moves — the rung-25 procedure, including the unselected-affordance disclosure
> standard.
>
> Notes for whoever runs it
> Step 0 is the rung. The code in Step 1 is a day's work once ADR-0010 is decided; decided wrong,
> it is the module-with-no-producer pattern wearing a network hat. Bring the decision to the
> review loop as an AskUserQuestion with the three options above.
> The streaming question will feel tempting to fold in. Don't. The state machine's honesty is the
> repo's spine; a streamingPartial case with a stub producer would be the first dishonest state it
> ever shipped. If streaming earns a rung later, it gets a real producer and its own ADR.
> Reuse what rung 18 already built. The fallback columns exist, the export passes them through,
> and invariant 3 named the chain a value two months of rungs ago. This rung is mostly connecting
> recorded decisions — which is why the scope discipline matters more than the code.

## What turned out wrong

The load a step-down performs was disclosed as unmeasured, and the ratified cold boundary put it
somewhere: cold is the first run after a load, so that load is recorded as the answering backend's
cold run and reaches the ledger as `load_ns`. The result view already named both ends of a hop, so
no view file changed. An untyped `throws` helper inside a `do` block widened the chain's typed
throws to `any Error` and broke every typed `catch` in the new spec.
