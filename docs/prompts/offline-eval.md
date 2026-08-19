# Prompt — the offline eval becomes code

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

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
> Notes for whoever runs it: Step 0's threshold (decision 3) is the rung's one biasable choice —
> bring a concrete value with its reasoning to the review loop, not a vibe. And the loop's thesis
> sentence finally becomes fully executable code with this rung — the README paragraph that says "the
> two loops meeting was the thesis" gets its last clause; edit it with that weight.

## What turned out wrong

The NDJSON carries no version field, so the unknown-version refusal had nothing to gate on and
became a required key set instead: a line missing a key, or carrying an unknown one, is refused by
line and by key. Calling `LatencyRecorder` rather than reimplementing it created the first
dependency between two libraries, which the module rules had until then forbidden.
