# Prompt — cancel-on-input-change

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

> Step 0 — three decisions via the review loop, before code:
>
> Does a cancelled run write a ledger row? The honest default: NO — the ledger records runs that
> answered; a cancelled attempt is not a run, no new schema, no new kind (the v3-rebuild lesson
> stands). But name the cost: compute spent on a cancelled run vanishes from the record. Record the
> option not taken.
> Does the engine CONTRACT gain a cancellation clause? classify is async, so Task cancellation
> propagates; decide whether the contract PROMISES cooperative cancellation (checked at stage
> boundaries, throwing CancellationError) and whether the conformance suite asserts it. If it does,
> the assertion must be structural (cancelled-before-compute throws; a completed compute is not
> retroactively cancelled), never a timing bound — the rung-31 lesson about what shared hardware can
> judge.
> Checkpoint placement — before preprocess, between preprocess and infer, after infer before the
> ledger append; the brackets themselves untouched. The chain adds its own boundary: between legs.
> State at each site why THERE.
>
> Step 1 — the driver owns cancellation. ClassificationModel cancels the in-flight task when a new
> photo arrives (and on whatever the ladder line names — deinit/disappear if it says so); the stale
> task's result must never paint over the new photo's flow, and a cancelled run never reaches the
> ledger or the recorder (p50/p95 stay clean by construction). UI: no new state case unless Step 0
> finds a producer AND consumer — the expected shape is a TRANSITION straight into the next
> inferring.
>
> Step 2 — tests with the house precedents. A slow/blocking stub engine (SinkSpy style) proving:
> cancel-then-select shows only the new result; the cancelled attempt wrote no row (assert the ledger
> count); the remote leg's URLSession task actually cancels (the loopback /slow endpoint finally
> earns a second use); the chain cancels between legs; cancellation before compute throws
> CancellationError per the contract decision. Counts re-measured, CLAUDE.md and ROADMAP move
> together.

## What turned out wrong

The contract cannot promise `CancellationError`: `classify` throws a typed `InferenceError`, so the
promise became `InferenceError.cancelled` and the two decisions collapsed into one. One of the three
checkpoint sites does not exist, because `inferStart` is a single clock read closing preprocess and
opening infer, so a check there would be measured as preprocess time. The prompt counted four
conformers; `StubEngine` is the fifth and needed the checkpoint too.
