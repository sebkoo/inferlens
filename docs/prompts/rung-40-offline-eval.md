# Rung 40 — the offline eval becomes code

The ninth entry in `docs/prompts/`. Each file holds the prompt that drove one rung, verbatim, plus
what the rung found out that the prompt did not know. Disclosure is a method, not a per-commit
trailer ([ADR-0004](../adr/0004-commit-hygiene.md)).

This is also where the rung's **keyed claim** retires to. The claim audited out of the tree at this
rung is quoted below inside a verbatim blockquote, which is what makes this file simultaneously the
gate's last hit and the record of what the claim was. A keyed re-run of the pattern will match here
by design, and only here — the [rung-31](rung-31-ci.md) and [rung-21](rung-21-fallback-chain.md)
prompt docs carry the same property for their own claims.

> Keyed claim for this rung: `offline tooling over the export, not code here` — retired when its
> quotation enters this prompt doc.

## The prompt, as received

> Read the on-disk record FIRST. README's Loop-engineering paragraph — the sentence this rung
> retires is its own honesty note: "evaluate is offline tooling over the export, not code here." The
> rung-37 prompt doc reserved this boundary revision "when real data exists to evaluate" — two
> releases now carry real NDJSON (demo-sim-b1c8fbe and demo-sim-ac8d402), so the recorded condition
> is met; say so in the ADR. ADR-0003 (cross-model agreement is measured and published — paired-run
> agreement is NOT this rung; the export carries no image key), LedgerExport and its tests (the
> NDJSON contract, its version field, its golden fixtures — the CLI parses THIS and nothing looser),
> the LatencyRecorder and the rung-12 ratified choices (nearest-rank percentile in integer
> arithmetic; the cold rule), the run_signals superseding-verdict policy, ADR-0014 (cancelled runs
> never reach the export — the eval never sees them, worth one sentence), and the ladder — use an
> existing eval line if one exists, else append per the 37/38/39 precedent.
>
> Step 0 — ADR-0015, the boundary revision. Decisions for the review loop (AskUserQuestion), each
> option named with what it alone provides:
>
> In-repo Swift over external tooling — the export schema and the ratified statistics stay
> single-sourced in code the suite already tests; a Python sidecar re-implements both and drifts, and
> its correctness is checked by nothing this repo runs.
> The shape that keeps tests on the pinned suite: an InferlensEval LIBRARY target (depends on Core
> only; tested in the existing suite on the pinned simulator) plus a thin inferlens-eval executable
> over it — the logic never lives where only a macOS run could test it, so test-clean and CI cover it
> unchanged.
> The refusal threshold: below a minimum row count per backend the tool REFUSES to recommend — that
> minimum is a biasable choice, maintainer-ratified, documented at the code (invariant-1 discipline
> applied offline). On today's two-row demo exports the honest output IS the refusal, and that is the
> tool working.
> Reuse over reimplement: percentile and cold/warm semantics come from the same ratified definitions
> the recorder uses — shared, not copied; assert identity in a test (same series in, same numbers
> out).
>
> Step 1 — the tool, smallest honest scope. Parse (version-gated, malformed rows REFUSED never
> repaired — the RemoteEngine validation precedent), group by backend, cold/warm split by the rows'
> own column, emit per-backend p50/p95 with n, the signal table under the documented superseding
> policy, and the verdict line: a recommendation ONLY above the ratified n, otherwise a printed
> refusal naming the shortfall and what would satisfy it. Every number in the output carries the
> device+OS the rows themselves name (invariant 7 flows through to the report).
>
> Step 2 — proof. Golden fixture → byte-exact expected report; the n-refusal path; unknown-version
> refusal; malformed-row refusal; the ratified-definition identity test; a fixture containing rows
> from two backends → the comparison table renders both with their own device columns. All
> structural, no clocks — CI-sound by design. Counts re-measured; CLAUDE.md and ROADMAP move
> together.
>
> Landing. README's Loop-engineering sentence moves — keyed claim not code here (quoted, retired when
> its quotation enters the prompt doc, the ninth entry). Full cadence per commit; make land RUNG=NN
> at the feat HEAD (retarget if trailing docs moved HEAD, per the recorded convention); STOP before
> push with the bundle; git push --atomic origin main rung-NN; post-push judgment includes CI green
> on the new commit.
>
> Standing rules: interview material never enters the tree; one commit, one concern; no
> AI-attribution trailers; verify before asserting; the tool never states a judgment the rows do not
> support.
>
> Notes for whoever runs it: Step 0's threshold (decision 3) is the rung's one biasable choice —
> bring a concrete value with its reasoning to the review loop, not a vibe. And the loop's thesis
> sentence finally becomes fully executable code with this rung — the README paragraph that says "the
> two loops meeting was the thesis" gets its last clause; edit it with that weight.

## What the rung found that the prompt did not know

**1. "Its version field" does not exist.** The prompt described the NDJSON contract as having one and
asked Step 2 for an "unknown-version refusal". Checked before any code, on both published assets:

```
$ jq -c 'keys' exported-runs.ndjson | head -1
["backend","classifications","degradations","device_model","id","infer_ns","is_cold",
 "load_ns","model_input_height","model_input_width","model_name","model_precision",
 "os_version","preprocess_ns","recorded_at_ms","signals"]
```

Sixteen keys, none a version. `LedgerExport`'s version gate reads the SQLite file's `user_version` —
a check upstream of the export and invisible to anyone downstream of it. The exporter's header even
appeals to that gate on a *reader's* behalf, which it cannot reach; that comment is annotated at the
code and the gap is a ROADMAP finding. The refusal became a **required key set** instead, which is
strictly weaker (it cannot tell "newer" from "wrong") and is what the format supports. Recorded as
[ADR-0015](../adr/0015-offline-eval-boundary.md), Decision 5.

**2. "Depends on Core only" and "reuse over reimplement" cannot both hold.** Decisions 2 and 4 of the
prompt contradict each other: `LatencyRecorder` lives in `InferlensBench`, and
[ADR-0008](../adr/0008-latency-summary-boundary.md) put it there on purpose. Three ways out existed;
two were refused (move the recorder into Core, reversing ADR-0008; or let the eval compute its own
percentile, which is the sidecar's duplication re-admitted because it is written in Swift). The taken
one is the graph's **first library → library arrow**, `Eval → Bench`, legal under the CI dependency
lint because Bench is neither an engine nor Core. Both forks went to the review loop as
`AskUserQuestion` before a line was written.

**3. The threshold has a derivation, and it is the ratified percentile's own arithmetic.** The prompt
asked for "a concrete value with its reasoning, not a vibe". The value is **20 warm rows per compared
backend**, and it is read off `LatencyRecorder`'s ratified choice (a) rather than chosen: with
`rank = min(max((95*N + 99)/100, 1), N)`, every `N` below 20 gives `rank == N`, so the figure printed
under the heading `p95` *is* the slowest run. 20 is the smallest `N` at which that stops being true.
The alternatives were named with what they lack — `n ≥ 30` has no derivation available in this repo
(the recorder makes no distributional assumption, so the central-limit folklore has nothing to attach
to), `n ≥ 2` licenses precisely the output the refusal exists to prevent.

**4. A fourth decision the prompt did not anticipate: the verdict weighs latency only.** Weighing the
thumbs would need a *second* ratified threshold, and the entire corpus holds three signal rows. A
veto rule ratified against that is a branch no fixture drawn from real data could reach — invariant
4's `warming` mistake relocated from a state machine into a statistic. So the signal table is printed
with its own `n` and the report says, in its own output, that the verdict does not weigh it.

**5. The keyed sweep retired one sentence and missed a second saying the same thing.** The pattern
`offline tooling over the export, not code here` fired on three surfaces, all of them the act of
retiring — ADR-0011's deferral (annotated superseded in the same commit) and two blockquotes in
ADR-0015. But the README carried the *same claim in different words* four hundred lines earlier —
"`evaluate` is offline tooling reading the export, not code in this repo" — and no keyed regex would
have caught it. It was found by grepping the idea. That is the gate's own limit, written down: a
keyed pattern retires the sentence it was given, not the belief.

**6. The fixture is the published artifact, and that closed a scope gap rather than decorating one.**
The spec could have used authored fixtures alone, and the tool would then have been proven against a
shape a fixture author imagined. It uses `demo-sim-ac8d402`'s `exported-runs.ndjson` — 166,609 bytes,
byte for byte, with the spec re-computing its sha256 against the value published in the release notes
— so "the tool reads what the app actually exports" is a gate rather than a manual step. The
two-backend case, which the real file cannot supply, is the one place an authored fixture carries the
byte-exact golden.

**7. The RED half was 17 of 18 red, and saying "all red" would have been the loose count this repo
keeps correcting.** The eighteenth test hashes the fixture and compares it to the published digest;
it depends on no implementation, so it passed in the RED half and was always going to. Stated in the
commit message rather than rounded up.

## What the rung did NOT produce

A number. The corpus is four rows across two exports, one backend, one simulator, and the tool refuses
on it. What it demonstrates is that the eval leg's machinery is real and tested — not that any
backend is faster than any other. The refusal is specific enough to be useful: the measurement rungs
now have a consumer with a stated appetite, printed in the output, of twenty warm rows for each of
two backends on one device and OS.
