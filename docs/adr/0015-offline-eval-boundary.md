# ADR-0015: The eval leg becomes code, and it refuses more often than it recommends

- Status: Accepted — 2026-07-22
- Deciders: maintainer
- Relates to: [ADR-0011](0011-app-shell.md) (which reserved this revision, and named the condition
  that has now been met), [ADR-0008](0008-latency-summary-boundary.md) (the seam that decides where a
  percentile may be computed, and therefore where this tool's arrow points),
  [ADR-0006](0006-run-ledger-storage.md) (the ledger and the export's `run_signals` read rule),
  [ADR-0003](0003-benchmark-comparison-scope.md) (cross-model agreement — measured and published, and
  explicitly NOT this rung), [ADR-0014](0014-cooperative-cancellation.md) (a cancelled run writes no
  row, so the eval never sees one), [ADR-0001](0001-module-boundaries.md) (the module graph this ADR
  amends, 9 → 10), CLAUDE.md invariant 1 (the ratified statistics, reused rather than reimplemented,
  and the discipline applied to this rung's own biasable choice), invariant 5 (dependency management
  stays pure SPM), invariant 7 (every number carries its device + iOS version), and the ladder's
  rung 40.

## Context

The README's Loop-engineering paragraph carries the repo's own honesty note about the loop's sixth
clause, verbatim:

> What keeps this line honest: `evaluate` is offline tooling over the export, not code here, and no
> ledger number is a device number until the device rungs run.

ADR-0011 reserved the revision of that boundary and stated the condition precisely:

> The eval-CLI boundary (the README's "offline tooling over the export, not code here") stays as it
> is; its revision is its own ADR when real data exists to evaluate.

**The condition is met.** Two releases now carry a real export, produced by the installed shell on
the pinned simulator, each the artifact of a recorded take:

| Release | Asset | Rows | sha256 |
|---|---|---|---|
| [`demo-sim-b1c8fbe`](https://github.com/sebkoo/inferlens/releases/tag/demo-sim-b1c8fbe) | `exported-runs.ndjson` | 2 | `1375f288…0943a` |
| [`demo-sim-ac8d402`](https://github.com/sebkoo/inferlens/releases/tag/demo-sim-ac8d402) | `exported-runs.ndjson` | 2 | `dab26389…03700` |

That corpus is four rows across two files, one backend, one device, one OS. It is real and it is
thin, and both halves of that sentence shape every decision below. The tool this ADR authorizes
produces, on that corpus, a **refusal** — and the refusal is the tool working, not the tool being
unfinished.

## Decision 1 — the eval is in-repo Swift, not an external sidecar

The alternative this decision rejects is the obvious one: a Python script, a notebook, a `jq`
pipeline. Rejected because of what a sidecar would have to re-implement, and what would check it.

- **The export schema would exist twice.** The NDJSON's shape is defined in exactly one place today
  (`LedgerExport`'s DTOs, whose coding keys are the literal column names) and pinned by exactly one
  spec (`LedgerExportTests`). A sidecar parser is a second, unchecked statement of the same
  interface, and it drifts the first time a column is added — silently, because nothing in this
  repo runs it.
- **The ratified statistics would exist twice.** CLAUDE.md invariant 1 makes the percentile
  definition, the cold/warm boundary and the warm-up policy maintainer-ratified choices, and
  `LatencySummary.swift` states the consequence: `LatencyRecorder` is *"the only place any percentile
  is computed in this repo … a second implementation of any of them would be a second definition of
  the benchmark rather than duplicated code."* A Python `numpy.percentile` call is a second
  definition — and a *different* one: it interpolates by default, so it reports numbers no run
  produced, which is precisely what ratified choice (a) exists to forbid.
- **Nothing this repo runs would check it.** `test-clean` builds and runs the iOS suite. A sidecar
  lives outside that entirely, so its correctness would rest on the same footing as `make lint`
  today: a target readable as coverage that measures nothing.

In-repo Swift puts the parser next to the writer's spec and the statistics inside the module that
already owns them, on the suite that already runs.

## Decision 2 — a LIBRARY target plus a thin executable, and the arrow points at Bench

**The shape.** `InferlensEval` is a library target holding all of it — parse, group, summarize,
render, decide. `inferlens-eval` is an executable target whose whole content is argument handling,
a file read, a print, and an exit code. Nothing that can be wrong lives in the executable, because
the executable is the one part the pinned simulator suite cannot run.

**The arrow, which is the part that needed deciding.** The prompt for this rung specified "depends on
Core only". That cannot hold together with Decision 4: the ratified aggregation lives in
`InferlensBench`, and ADR-0008 decided deliberately that it stays there (*"the screen displays the
number; Bench is the only module that can make one"*). Three ways out were available and two were
refused:

- **Refused — move `LatencyRecorder` into Core.** It reverses ADR-0008 for the convenience of one new
  consumer, and it hands `InferlensUI`, which depends on Core alone, the ability to compute a summary
  it is documented as unable to produce.
- **Refused — let `InferlensEval` compute its own percentile.** It is the second definition Decision 1
  just rejected in a sidecar, re-admitted because it is written in Swift. An identity test between two
  implementations is weaker than having one implementation.
- **Taken — `InferlensEval` → `InferlensBench` → `InferlensCore`.**

```
app  →  {InferlensUI, InferlensStore, InferlensFlags, InferlensBench,
         InferlensCoreML, InferlensLiteRT, InferlensRemote,
         InferlensFallback, InferlensEval}  →  InferlensCore
                            InferlensEval  →  InferlensBench
```

This is the graph's **first library → library arrow**, which is why it is recorded here rather than
typed into `Package.swift` and discovered later. It is legal under the rule the CI dependency-lint
enforces — *"fails any arrow pointing back toward an engine or into Core"* — because `InferlensBench`
is neither an engine nor Core: it is aggregation over Core's value types, which is exactly what a
consumer of aggregation should be allowed to name. The direction stays one-way and acyclic. The
module count moves **9 → 10**, the same amendment ADR-0013 made at 8 → 9.

`InferlensEval` imports no engine, no `InferlensStore`, and no SQLite. It reads NDJSON. The exporter's
own header states the reason the arrow to Store is unnecessary: *"the stored tokens ARE the format …
What the columns hold is what the eval reads."*

**Invariant 5 is untouched.** Two targets and one product are added to `Package.swift`; no dependency
manager, no binary, no package-resolution override. One line is added to `platforms` —
`.macOS(.v26)` — because the package declared only `.iOS(.v26)` and a host build therefore fails on
`Duration` (*"'Duration' is only available in macOS 13.0 or newer"*, reproduced before this was
written). That line is what lets `swift build --product inferlens-eval` produce a runnable tool; it
changes no dependency and no iOS deployment target.

## Decision 3 — the refusal threshold, and where the number comes from

**This is the rung's one biasable choice.** It is maintainer-decided, ratified in the green commit's
message, and documented in a comment at the code, under exactly the discipline CLAUDE.md invariant 1
applies to the percentile definition and the cold/warm boundary — applied here offline, because a
threshold that decides when a benchmark is allowed to recommend a backend is as biasable as the
percentile it recommends on.

> **Ratified: a recommendation requires at least 20 warm rows for each compared backend, within one
> device + OS scope. Below that the tool prints a refusal naming the shortfall and what would satisfy
> it, and never names a winner.**

**The number is read off the ratified percentile definition rather than chosen.** `LatencyRecorder`'s
choice (a) is nearest-rank in integer arithmetic, `rank = min(max((p * N + 99) / 100, 1), N)`. For
p = 95:

```
N = 10  ->  (950  + 99) / 100  =  10  == N     p95 IS the maximum sample
N = 15  ->  (1425 + 99) / 100  =  15  == N     p95 IS the maximum sample
N = 19  ->  (1805 + 99) / 100  =  19  == N     p95 IS the maximum sample
N = 20  ->  (1900 + 99) / 100  =  19  <  N     p95 is finally not the maximum
```

Below 20 rows, the number the report prints under the heading `p95` **is the slowest run**. A
"p95 comparison" between two backends with 8 rows each compares two worst-cases and calls the result
a percentile. Twenty is the smallest N at which that stops being true, so the threshold is a
consequence of a choice already ratified rather than a second, independent one.

**The alternatives, and why not.** `n ≥ 30` is the conventional number, and nothing in this repo
derives it: the recorder makes no distributional assumption anywhere, so the central-limit folklore
that produces 30 has nothing to attach to — it would be a threshold whose only defence is custom,
which is the shape of hidden choice invariant 1 exists to forbid. `n ≥ 2` is the weakest floor that
has any spread at all, and it licenses a recommendation from two runs, which is the output the
refusal exists to make impossible. Adding a cold-bucket requirement (`n ≥ 3 cold`) was refused
because cold rows are one-per-load by ratified choice (b) — three cold rows means three separate
model loads per backend — and because the recommendation is about steady-state cost, so gating it on
the bucket a reader can least accumulate would refuse for a reason the verdict does not rest on.

**The scope of the comparison is `(backend, device_model, os_version)`, and that is invariant 7 doing
work rather than being quoted.** Rows from a phone and rows from a simulator are never pooled into
one percentile, and two backends measured on different machines are never compared — the tool refuses
instead. Invariant 7 says every number carries its device and OS; a report that averaged across them
would carry the label and lose the fact.

## Decision 4 — reuse over reimplement, asserted as identity

`InferlensEval` rebuilds a `LatencySample` from each row's own columns — `is_cold` and `load_ns` give
`LoadTiming`, `preprocess_ns` and `infer_ns` give `RunTiming` — and hands the array to
`LatencyRecorder.summarize`. The percentile, the cold/warm partition and the no-discard policy are
therefore not reproduced, described, or approximated here: they are *executed*, by the same code the
app runs.

The spec asserts it as identity rather than as intent: the same series of samples, fed once through
`LatencyRecorder` directly and once through the eval's whole parse-and-group path, produces equal
`LatencySummary` values. A test that compared the eval's numbers to hand-computed constants would
pass just as well against a second implementation; this one cannot be satisfied by writing one.

**Nothing about the ratified choices is re-opened.** The percentile definition, the cold/warm
boundary and the warm-up policy are untouched, and the recorder still discards nothing — the eval
adds no filtering step before `summarize`, so a cold row is reported in the cold bucket exactly as
choice (c) requires.

## Decision 5 — there is no version to gate on, and the prompt's premise was wrong

The rung was specified with a "version-gated" parser and an "unknown-version refusal". **Neither is
implementable, because the NDJSON carries no version field.** Verified before any code was written,
on both released assets:

```
$ jq -c 'keys' exported-runs.ndjson | head -1
["backend","classifications","degradations","device_model","id","infer_ns","is_cold",
 "load_ns","model_input_height","model_input_width","model_name","model_precision",
 "os_version","preprocess_ns","recorded_at_ms","signals"]
```

`LedgerExport`'s version gate reads the **SQLite file's** `user_version` and refuses a database this
build cannot read. That gate is upstream of the export and invisible to anyone downstream of it: a
reader holding only the `.ndjson` cannot see it, and cannot tell an old exporter's output from a new
one's. The exporter's own header half-notices this — it justifies the always-present `"signals": []`
key by saying an absent key *"would read as 'this exporter predates signals', an ambiguity the
version gate exists to remove"* — and the version gate does not, in fact, reach the reader it is
being invoked on behalf of. That sentence is annotated at the code rather than deleted, because it
records a real gap.

**What refuses instead: the required key set.** A line whose keys are not exactly the contract this
build knows is refused, by line number and by key — never repaired, never partially read (the
`RemoteEngine` validation precedent). `load_ns` is the one conditional key: present exactly when
`is_cold` is 1, absent otherwise, which is what the exporter's nil-omission produces and what
`LedgerExportTests` already pins from the writer's side.

**Adding a version field to the export was refused for this rung**, on two counts. It is a change to
a published interface inside a rung whose subject is a reader — two concerns in one commit. And the
two released exports lack the key, so a version-gating tool would refuse, on the day it shipped, the
entire corpus whose existence is this rung's justification: a gate whose scope excludes the only case
it has. Adding `schema_version` to `LedgerExport`, with a documented rule for what an absent version
means, is named here as its own future rung.

## Decision 6 — the verdict keys on latency, and says so

The report has three parts: a latency table, a signal table, and a verdict line. **The verdict weighs
latency only**, and the report states that in the output rather than in a comment nobody reading the
output will see.

The reason is a count. Weighing signal in the verdict requires a second ratified threshold — how many
judgements are enough to call one backend more-often-wrong than another — and the entire corpus holds
**three signal rows across two runs**, one of which is a `down` superseded by an `up`. A veto rule
ratified against that would be a branch no fixture drawn from real data could reach: a rule with a
producer and nothing that can exercise it, which is invariant 4's `warming` mistake relocated from a
state machine into a statistic.

So the signal table is **reported with its own n and explicitly not weighed**, and it applies the
schema's read rule — the last element of a row's `signals` array is the current verdict, earlier ones
are history (`run_signals`' DDL, carried across the export boundary on purpose). Rows with no signal
are counted as unjudged, never as agreement.

## What this ADR does NOT decide

- **Cross-model agreement is not this rung, and could not be.** ADR-0003 commits to measuring and
  publishing top-1 agreement over a frozen golden set. That is a *paired* measurement — the same
  image through two backends — and **the export carries no image key**: a line names its model, its
  device, its timings and its labels, and nothing that identifies the photograph. Two rows from two
  backends cannot be paired from this file at all. Agreement stays where ADR-0003 and ADR-0012 put
  it, and this tool does not approximate it.
- **A cancelled run is never in the input.** ADR-0014 Decision 1 puts no row in the ledger for a run
  that was superseded, so the export cannot carry one and the eval never sees one. The eval needs no
  filter, no `is_cancelled` column and no sentence about excluding them; the exclusion happened three
  layers upstream, and the compute those runs spent is the disclosed residue ADR-0014 already named.
- **No signal-weighted verdict, and no second threshold** — Decision 6.
- **No change to the export's format**, no `schema_version`, no new column, no ledger migration.
- **No CI lane for the tool beyond the suite it already runs in.** The library is tested by
  `test-clean` on the pinned simulator like every other module; the executable is built by the same
  scheme and run by hand.
- **No numbers published from this tool.** It reports what the rows say; the README's latency table
  is still empty and still waits on the measurement rungs. A four-row corpus produces a refusal, and
  quoting a refusal as a result would be the failure this whole rung is built to prevent.

## Consequences

- The thesis sentence becomes fully executable. `run inference → append to ledger → capture signal
  (thumbs) → export → offline eval → choose next model/backend` had one clause with no code behind
  it; the README's honesty note about that clause is retired as this rung's keyed claim, and the
  paragraph is rewritten to say what is now true and what is still absent.
- The module graph gains its first library → library arrow, documented above and amended into
  ADR-0001 and CLAUDE.md's dependency diagram.
- `Package.swift` declares `.macOS(.v26)`. A bare `swift build` on the host still fails — it reaches
  `InferlensLiteRT` and the vendored xcframework has no macOS slice — so the tool is built by product:
  `swift build --product inferlens-eval`. Named here so the next reader does not mistake the failure
  for a regression.
- The suite gains a fixture that is a **published release asset, byte for byte**: the
  `demo-sim-ac8d402` export, whose sha256 the spec re-computes and compares against the value in the
  release notes. It is 166,609 bytes of text, not a binary, and invariant 6 is untouched — but it is the
  reason the tool's coverage is a gate rather than a manual step, because the shape it parses is the
  shape that actually ships rather than the shape a fixture author imagined.
- On today's corpus the tool refuses, and the refusal is the deliverable. What would satisfy it is
  printed in the output: twenty warm rows for each of two backends on one device and OS — which is
  the measurement rungs' subject, now with a consumer waiting for it.
