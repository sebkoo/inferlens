# Prompt — rung 22: cancel-on-input-change, and whether the contract should promise it

The instruction that drove the rung, verbatim, plus honest execution notes on where reality pushed
back — the rung-15 convention: the prompt is the plan; the commits are what happened. The same
warning a future reader needs at every entry in this directory: the blockquote below quotes this
rung's keyed claims literally, so re-running the sweep with that key matches THIS file by
construction. See the landing section before reading such a red as a finding.

---

## The driving prompt (as received)

> Read the on-disk record FIRST. `git log --oneline -8`, ROADMAP ladder line 22's exact text (scope
> to it; it lands out of numeric order — the entry records the TECHNICAL reason from the ladder's own
> framing, nothing else), CLAUDE.md invariant 4 (states are an enum; a new case needs a producer AND
> a consumer — cancellation may be a transition, not a state), invariant 1 (the timing brackets are
> ratified; cancellation checkpoints sit BETWEEN them, never inside), ADR-0005 (the engines are
> actors whose C calls are synchronous and on-actor — an in-flight Invoke cannot be interrupted, so
> cancellation is cooperative at stage boundaries), ADR-0013 (the remote leg's URLSession CAN
> genuinely cancel mid-flight — the one leg where cancellation is more than checkpoints),
> ClassificationModel (where the in-flight task lives and where a new photo selection arrives),
> RunLedger/LedgerExport (what a "run" means to the ledger), the conformance suite, and the committed
> prompt docs for format.
>
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
>
> Landing. Full cadence per commit; keyed claim ONLY if a rewrite honestly retires a real sentence
> (check whether any doc claims inference cannot be cancelled — do not invent one). `make land
> RUNG=22` at the feat HEAD, trailing docs untagged, badge derived (27/40). STOP before push with the
> bundle; `git push --atomic origin main rung-22`; post-push judgment includes the CI run on the new
> commit (the cancellation tests must be CI-sound by design — structural, not timed).
>
> Standing rules: interview material never enters the tree; one commit, one concern; no
> AI-attribution trailers; verify before asserting; every gate prints which way it went.
>
> Notes for whoever runs it: Step 0's second question is the rung's real content — a cancellation
> promise in the CONTRACT binds all four conformers (three engines + the chain), which is exactly
> what makes it worth a rung instead of a UI patch. And the standing interrupt rule: an interview
> invitation pauses this mid-anything.

---

## Execution notes — where reality pushed back

**1. The prompt's Step 0 question 2 could not be answered as posed, and the reason decided the
answer.** It asked whether the contract should promise cancellation "throwing `CancellationError`".
It cannot: `classify` is declared `async throws(InferenceError)`, so `try
Task.checkCancellation()` does not compile inside it and `CancellationError` does not convert. That
left three real options — widen the typed throw, add a case to `InferenceError`, or promise nothing —
and the first would spend the property typed throws exists for ("no native Core ML or LiteRT error
crosses the contract", stated at the enum). So the clause and `InferenceError.cancelled` are one
decision, not two, and the shape was forced by a fact rather than picked. Recorded as ADR-0014,
Decision 2. The prompt's instinct was right; the mechanism it named was not available.

**2. The prompt named four conformers; there are five.** Its closing note says a contract promise
"binds all four conformers (three engines + the chain)". `StubEngine` conforms too — it is the engine
the conformance suite was built against, and it had to gain the checkpoint like everything else, or
the suite's new checks would have failed the type that exists to pass them. Small, and worth naming
because the whole argument for putting the clause in the contract is *how many* implementations one
sentence binds; undercounting weakens the case for the decision it was supporting.

**3. One of the three checkpoint sites the prompt listed does not exist, and finding that out was the
substance of Decision 3.** It asked for a checkpoint "between preprocess and infer". Reading the
three engines shows `inferStart` is a SINGLE clock read that closes `preprocess` and opens `infer` —
there is no gap between the phases. Any check written there is measured as preprocess time. It would
be one flag read, and "small enough not to matter" is exactly the judgement invariant 1 removes from
an agent's hands, so the site is recorded as REFUSED rather than quietly used. Each engine therefore
has exactly one checkpoint (at `classify` entry, above the split), the driver has the three the
engines cannot hold because it owns the load bracket, and the chain has the one no engine can see.

**4. A fourth site the prompt did not ask about had to be decided anyway: `loadModel`.** It gains no
clause and no checkpoint, for the same bracket reason — its bracket is the driver's, so every site
inside it is inside a measurement. Nothing is lost: the driver's pre-load checkpoint already covers
"cancelled before the load". `FallbackEngine.loadModel`'s walk consequently has NO `.cancelled` guard,
and the absence is written at the site with the trap it leaves for whoever adds the clause later — a
guard there today would be unreachable code claiming a capability, which is the `warming` failure in
a catch block.

**5. The chain needed a rule the prompt did not name, and it was the one place cancellation could
have produced a visible lie.** A cancelled leg must not count as a failed one. Without that, a
person's new photo would make the chain try every remaining backend and — worse — derive a
`.fellBack` hop for a step-down that never happened, putting a fabricated degradation on screen.
`.cancelled` propagates immediately instead. Three tests pin it: the leg below is never consulted, a
cancelled walk consults no leg at all, and the chain heals with no hop remembered.

**6. The `/slow` test's shape is where the rung-31 lesson actually bit.** The obvious test — cancel
mid-flight and assert it finished quickly — would have been a timing assertion on shared hardware,
the exact defect that forced `steadyStateMaxRatio` to be scoped out of CI. Instead the engine is built
with a **10-minute** timeout, so the timeout cannot be what ended the request; if cancellation did not
work the test hangs until XCTest kills it, which is a failure and never a pass. The assertion is an
identity — `.cancelled`, and specifically not `.backendUnavailable`. No clock is read. Same for the
two conformance checks, which spin on `Task.yield()` until cancellation is observable so the engine is
never entered before `cancel()` lands.

**7. The prompt asked for a state-case decision and the answer was "no", from the other side of the
rule.** Invariant 4's usual failure is a case with no producer (`warming`). `cancelled` has one — the
driver knows exactly when it cancels — and no CONSUMER: a cancelled run exists only because a new run
is already starting, so the case would be overwritten by the superseding `.classifyBegan` in the same
turn. Recorded in CLAUDE.md as a case the rule REJECTED, which is evidence the rule bites rather than
a third correction to it. The transition rung 23 wrote for this rung — `(.inferring, .classifyBegan)
-> .inferring` — turned out to be the whole UI change: the table is byte-identical.

**8. The rung falsified a prediction that named it.** `ClassificationModel`'s invariant-1 note said
deciding the `pendingLoad` overwrite "means serializing runs, which is the cancel-on-input-change
rung's subject". This rung supersedes rather than serializes: awaiting the run in flight would queue
the new photo behind a compute ADR-0005 makes uninterruptible. Case 3 is narrowed, not closed, and
what would close it — a shared load task — is named in ROADMAP as the load-deduplication concern it
is. The comment is corrected in place rather than deleted, the disposition every superseded claim in
this repo gets.

**9. A negative control was written WITH the check, not after it.** ROADMAP records "the earlier
gates have no NEGATIVE control" as standing backlog. `UncancellableEngine` — conforming in every
respect except that it ignores the flag and answers anyway — must fail the suite with the violation
that names the rule. A new check nobody has made fail is a green of unknown value.

---

## Landing — the keyed claim, and what it did and did not retire

The prompt's own instruction was to run a keyed claim **only if a rewrite honestly retires a real
sentence**, and to check rather than invent one. Two were found, both true before this rung and false
after it, so the key is real:

- `README.md`'s design-stage list: *"Cancel-on-input-change (the chain landed at rung 21; cancellation
  is its own rung)"* — removed.
- `ClassificationModel.run(_:)`: *"Deliberately not cancellable and deliberately not re-entrant"* —
  rewritten. Still not re-entrant; no longer not cancellable.

Nothing in the tree claimed inference *cannot* be cancelled, and none was invented to have something
to retire. The skills-matrix row moved off `partial`, which is a status change rather than a claim
retirement, and the fallback spec's test count moved 8 → 11 by being counted.

**The keyed sweep run pre-push was RED, on four surfaces, and every one is the act of retiring the
claim rather than the claim.** Reported in full, because the claims-audit contract says a verdict
that omits which surface it came from has said less than it appears to:

| Surface | Where | Judgment |
|---|---|---|
| A1, tree | `docs/adr/0014-…:29` | the retired comment, quoted in a blockquote attributed "at rung 24" — marked historical |
| A1, tree | this file, the two bullets above | the list of what was retired, each quoted and each followed by "removed" / "rewritten" |
| A2, message | `docs(prompts)` (this commit) | the same list, in the body that describes the retirement |
| Live assertion | **none** | `Sources/`, `README.md`, `CLAUDE.md` and `ROADMAP.md` hold no present-tense form of either claim |

That last row is the one the gate exists for, and it is the row that is empty. The keyed audit is
therefore a manual-judgment gate at this rung, read the way rung 39 read its own — the same
disposition, reached the same way: check that every hit is a marked record, and confirm no live
sentence survives. The **built-in** audit (no key) ran green over tree, messages and shas.

**Two `feat` commits, one tag.** The tag convention says `rung-N` tags the rung's `feat` commit and
does not say which when there are two. It is on `feat(ui)` — the ladder line's literal deliverable,
and the point before which the rung does not work — with `feat(core)`, which carries the contract
clause and is the larger half, pushed alongside and untagged like the ADR and the trailing docs.
Recorded in ROADMAP, because the convention's stated purpose ("where is this rung implemented")
genuinely has two answers here.

Counts re-measured on the pinned iPhone 17 Pro / iOS 26.1 via `scripts/test-clean.sh`: **187 counted,
186 run, 1 skipped** (178/177/1 before the rung). The nine new tests are four on the driver, three on
the chain, one on the remote leg, and one negative control on the suite.
