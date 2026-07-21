# Prompt — rung 21: the fallback chain and the remote leg's honest shape

The instruction that drove the rung, verbatim, plus honest execution notes on where reality
pushed back — the rung-15 convention: the prompt is the plan; the commits are what happened.
One warning to a future reader: the blockquote below quotes this rung's keyed claims-audit
regex literally, so re-running the gate with that key matches THIS file by construction — see
execution note 3 before reading such a red as a finding.

---

## The driving prompt (as received)

> Driving prompt — rung 21: the fallback chain as a value, and the remote leg's honest shape
>
> Paste into a FRESH Claude Code session at the repo root (origin/main = 7bbaebf, 21 rung tags,
> badge 21/37, suite 132/131/1). Commit as docs/prompts/rung-21-fallback-chain.md during the rung
> (third entry; rung-15 convention: verbatim + execution notes).
>
> Read the on-disk record FIRST. git log --oneline -20, CLAUDE.md — especially invariant 3 (the
> chain is a VALUE, degradation surfaced never silent, and note the ledger already stores
> kind/from_backend/to_backend as columns) and invariant 4 (every state case needs a producer that
> exists in THIS codebase; warming was deleted for lacking one — do not repeat that mistake with a
> streaming case). Then docs/ROADMAP.md (ladder line 21; the claims-audit contract WITH both
> amendments — landing order is edit → gates → commit → claims-audit → push; keyed claims fire at
> the docs rewrite, not before), ADR-0005 (engine concurrency, zero @unchecked), ADR-0008/0009
> (the seam and scope-cut precedents), InferenceEngine.swift (the contract the chain itself should
> satisfy), both engine implementations, InferenceStateView/ClassificationModel (where
> success(degraded:) renders), and the two committed prompt docs as format precedents. Verify
> every line number by opening the file — this series shipped ordinal errors whenever it trusted
> memory.
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
> Landing. Per-commit: stage first → width (per-file convention) → anchor → claims A1 →
> test-clean (pinned destination confirmed) → commit → claims-audit (the A2 window). Keyed claim
> for this rung (≥4 chars, quoted, no inline # in interactive zsh): chain does not exist|remote
> leg is not. make land RUNG=21 at the feat HEAD; trailing docs untagged; badge 22/37. Counts
> re-measured, never added — CLAUDE.md and ROADMAP's anchored sentence move together in one commit
> if the suite grows. STOP before push with the evidence bundle (gates labeled by push-side; a
> pre-push Check B red naming only this rung's self-cited sha is the gate working). Then git push
> --atomic origin main rung-21 and the post-push judgment run.
>
> Standing rules: one commit, one concern; no AI-attribution trailers; interview material never
> enters the tree — the remote leg's justification in ADR-0010 is architectural, not situational;
> verify before asserting; prefer deleting an abstraction over adding one — a chain of one real
> leg and one stub may be exactly right.
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

## Execution notes — where reality pushed back

1. **"The emergency load lands in no timing column" — the first ADR draft said it, and the
   repo's own ratified boundary corrected it mid-review.** The draft disclosed a per-call
   step-down's on-demand load as unmeasured. The maintainer's correction pointed at rung 12's
   ratified sentence — cold is the first run after A LOAD — so the step-down run is recorded as
   the fallback backend's COLD run: `is_cold` set, `load_ns` carrying the emergency load, and
   the only unrecorded residue is the failed attempt's wasted time, unattributable to a row
   whose backend is the leg that answered. The correction reached the contract as
   `InferenceOutcome.onDemandLoad` — a `Duration`, the sample's own unit, per a second review
   rider, so the store keeps sole ownership of the nanosecond encoding — and the driver's
   precedence rule, each site carrying the ratification comment in those words.

2. **"the result view's degradation line gains the from→to naming if it lacks it" — it did not
   lack it.** `DegradationBanner` has rendered "X answered — Y was unavailable" since the
   state-machine rung, and the `state-04` fixture already draws the exact LiteRT → Core ML hop.
   Step 2 collapsed to verification: no view file changed at this rung, so the six fixtures and
   the caption's sha stand — the rung-25 regeneration rule triggers on a view change, and there
   was none.

3. **The keyed sweep swept clean at every gate — and this file is the one place it can never
   sweep clean again.** Nothing tracked ever asserted the chain's absence in the key's words;
   the stale claims were found by reading, not by the regex: the README's composition bullet
   naming a bare engine, the design-stage list, the app comment promising a non-retryable
   failure for a missing model file, and two comments claiming `Backend` is not `Equatable`.
   The key's literal text now sits in the verbatim blockquote above, so a keyed re-run matches
   this file by construction. That hit is the ROADMAP three-way classification's third case — a
   historical quote, left in place — and rung-25's note 3 met on the tree surface, where
   paraphrase is not available because the blockquote's whole value is that it is verbatim. The
   keyed gate's job finished, green, on the commit before this file landed.

4. **Typed throws has an edge the plan never named.** An untyped `throws` helper inside a `do`
   block widened the chain's `throws(InferenceError)` to `any Error` and broke every typed
   `catch` in the new spec. The build failed — and `test-clean` returned 2, not 1: the
   build-failure/test-failure discriminator installed by the `37fbc1e` correction reported the
   truth on its first live firing this session.

5. **ROADMAP's Design-of-record list had silently stopped at ADR-0007.** ADR-0008 and ADR-0009
   were accepted and never indexed there — the cross-document pointer gap ROADMAP itself
   specifies a check for, found while indexing ADR-0010 and closed in the same commit.
