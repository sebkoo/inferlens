# Inferlens roadmap

An atomic commit ladder. Every rung is a Conventional Commit, independently reviewable,
and **green** (builds + tests pass, clean under Swift 6.3 `-strict-concurrency=complete`).
A rung that would touch two concerns is split. Rung 00 is the bootstrap; rungs 01–40 are
the build ladder.

Progress is not tracked in this file — **git tags are**: `git tag -l 'rung-*'` is the
authoritative record of what landed (one tag per landing commit), and the README badge is
derived from it (`make readme-sync`). This file is the plan; git is the progress. Land a rung
with `make land RUNG=NN` so the tag is declared, not remembered.

**Which commit a `rung-N` tag points at — the convention, written down at rung 23.** A rung
usually lands as more than one commit: the `feat`, then the doc corrections it forced. The rule:

> `rung-N` tags the rung's **`feat` commit**. Doc updates, README syncs and invariant corrections
> that follow it are part of the rung and are pushed with it, but they are **untagged**.

Chosen because the tag then answers "where is this rung implemented" rather than "where did the
paperwork stop", and because the number of trailing doc commits varies per rung while the feat
commit does not. It was already the de-facto convention — `rung-10`, `rung-12` and `rung-18` each
sit on their `feat` commit — but it was never written, so rung 23 initially landed on its README
commit and had to be moved before the push.

**Recorded exception: `rung-15` does not follow this rule.** It points at `df4f421`
(`docs(prompts): rung-15 LiteRT-engine prompt`), three commits after `65b5798`
(`feat(litert): LiteRTEngine`). It is pushed, and moving a published tag is a shared-history
rewrite, which costs more than it buys — so the exception is recorded here instead of corrected,
the same disposition as the `37fbc1e` and rung 26 → 31 corrections below. The convention is
3-of-4 historically and 4-of-5 from rung 23 forward; nothing derives a number from it, so the
one outlier misleads a reader and breaks no check.

**Named gap: `make land` does not implement this rule on its own.** It tags `HEAD` and amends the
derived badge into `HEAD`, which is correct only when the `feat` commit *is* `HEAD`. When doc
commits follow, run `make land RUNG=NN` as usual and then `git tag -f rung-NN <feat-sha>` before
pushing — the badge is derived from the tag *count*, so which commit carries the amend does not
affect it. Teaching `land` to take a target sha is a Harness-backlog item.

Design of record: [ADR-0001](adr/0001-module-boundaries.md) (module boundaries),
[ADR-0002](adr/0002-litert-distribution.md) (LiteRT distribution),
[ADR-0003](adr/0003-benchmark-comparison-scope.md) (benchmark scope),
[ADR-0004](adr/0004-commit-hygiene.md) (commit hygiene),
[ADR-0005](adr/0005-litert-engine-concurrency.md) (LiteRT engine concurrency),
[ADR-0006](adr/0006-run-ledger-storage.md) (run ledger storage),
[ADR-0007](adr/0007-readme-media.md) (README media — screenshots, video, and the byte ceiling
invariant 6 never gave),
[ADR-0008](adr/0008-latency-summary-boundary.md) (the latency-summary boundary),
[ADR-0009](adr/0009-document-store-scope.md) (document-store scope),
[ADR-0010](adr/0010-remote-leg-scope.md) (the remote leg and the chain's cold rule),
[ADR-0011](adr/0011-app-shell.md) (the app shell — the committed minimal project, and
invariant 5 precised),
[ADR-0012](adr/0012-label-table-provenance.md) (where the truth of index → label lives),
[ADR-0013](adr/0013-remote-leg-realization.md) (what "real" means for the remote leg without a
production server),
[ADR-0014](adr/0014-cooperative-cancellation.md) (cancellation — a contract clause, a transition,
and no ledger row),
[ADR-0015](adr/0015-offline-eval-boundary.md) (the offline eval becomes code — the graph's first
library → library arrow, and a ratified refusal threshold).
Ground truth: [PRIOR_ART.md](research/PRIOR_ART.md),
[MODEL_PROVENANCE.md](research/MODEL_PROVENANCE.md).

## The thesis every rung serves

The product loop and the developer's evaluation loop are the **same loop**:
`run inference → append to ledger → capture signal (thumbs) → export → offline eval →
choose next model/backend → run inference`. A wrapper app calls an API; this app closes
a loop. Every decision is defensible by pointing at that sentence.

## Build model (explicit: bootstrap precedes build)

The SPM `binaryTarget` mechanism is xcframework-only, so the two benchmark models are
fetched by script, not by SPM. `swift build` **alone** does not yield a working app, and the
macOS host build fails on iOS-era stdlib (`Duration`) besides — verify on iOS:

```
make bootstrap && xcodebuild build -destination 'generic/platform=iOS Simulator'
```

CI (the CI rung) runs `make bootstrap` before the iOS test build. The README states it in one line.

## The ladder (rungs 00–40)

```
00 chore(repo): bootstrap toolchain, license, agent context
01 docs(readme): project overview — what it is, where it stands, what is decided
02 build(spm): Package.swift workspace + empty local module targets + thin app placeholder
03 feat(core): inference contract protocols (InferenceEngine, ModelDescriptor,
               LatencySample, InferenceOutcome) — zero dependencies
04 build(make): derive the README badge from rung tags; cite docs by stable component
               name, not rung number (numbers live only in this file); drop hand-typed
               progress state
05 test(core): StubEngine — a deterministic in-memory engine, no model, no framework
06 test(core): assertConformsToContract — the engine-agnostic conformance suite, run
               against the stub (never names or imports a concrete engine)
07 test(core): broken stub variants prove the suite catches what it claims
               (unsorted classifications, confidence > 1, lazy-load in classify)
08 build(make): wire `make test` to xcodebuild on the iOS simulator — it has been exit-0
               since commit #1; this is where it stops lying
09 chore(models): pin Apple MobileNetV2 (FP16 .mlmodel, native) + Google MobileNetV2
               (FP32 .tflite, default) by source URL + checksum in MODEL_PROVENANCE.md;
               make bootstrap fetches them (verify Google .tflite URL here)
10 feat(coreml): CoreMLEngine over the fetched FP16 .mlmodel, conforms to the contract
11 perf(coreml): OSSignposter spans around load / preprocess / infer
12 feat(bench): LatencyRecorder — p50/p95 over cold/warm (agent-written, maintainer-decided;
               nearest-rank + no-discard policy ratified and documented at the code)
13 build(litert): produce & publish the vendored TensorFlowLiteC.xcframework release —
               extract from the dl.google.com archive; read Info.plist AvailableLibraries
               and ASSERT ios-arm64_x86_64-simulator FIRST; re-zip; tag GitHub release
14 build(litert): declare binaryTarget(url:checksum:) + simulator link smoke test
15 feat(litert): LiteRTEngine over the C API — actor-isolated, ONE @unchecked Sendable
               boundary (required to compile under strict concurrency); uses FP32 .tflite
16 ci(litert): document the Sendable boundary + CI lint enforcing AT MOST ONE
               @unchecked-Sendable (the on-actor rung-15 engine ships ZERO; ADR-0005)
               + a strict-concurrency data-race test
17 feat(bench): measure & PUBLISH cross-model top-1 agreement on a FROZEN golden set
               (different weights → disagreement is data, not a gate; ADR-0003)
18 feat(store): SQLite append-only run ledger + versioned migrations (SQL)
19 feat(store): document/KV store for model metadata + flag cache (NoSQL)
20 feat(flags): FeatureFlagProvider protocol + local JSON provider
21 feat(engine): fallback chain LiteRT -> CoreML -> remote stub as a VALUE (not if-else)
22 refactor(engine): engine actor; cancel in-flight Tasks when input changes
23 feat(ui): InferenceState enum + SwiftUI state-machine views, no engine knowledge
24 feat(ui): pick/capture image -> classify -> top-3 + confidence + backend + p50/p95
25 feat(ui): thumbs up/down signal -> append to ledger
26 feat(store): ledger export (NDJSON) for offline eval
27 feat(thermal): map ProcessInfo.thermalState + model-load failure + OOM to named states
28 feat(flags): EntitlementProvider seam + AlwaysEntitled stub; paywall flag OFF
29 feat(app): thin app target composes the modules — the one MVP screen
30 test(store): migration + append-only invariant tests
31 build(ci): GitHub Actions — make bootstrap, then swiftformat --lint, swiftlint, and
               build+test on the iOS simulator via
               `xcodebuild -destination 'generic/platform=iOS Simulator'` — never
               `swift build`/`swift test` on the host (the host build was green only for as
               long as it was meaningless — empty targets; iOS-era stdlib such as `Duration`
               breaks it, discovered at rung 03). Commit-hygiene trailer lint from commit #1
               (ADR-0004). Derived-vs-declared lints, each failing loud where a hand-typed
               value would rot silent: (a) no hand-typed rung number anywhere outside this
               file; (b) every component reference in docs resolves — the Core ML engine,
               the LiteRT vendoring step, InferlensCoreML — to a real target or ROADMAP
               rung; (c) the `rungs N/D` badge equals the derived pair, `rung-*` tags on
               ORIGIN over the ladder's rung count in this file, so an unpushed tag makes N
               lag and fails here (the core.hooksPath trap again); (d) every `rung-*` tag
               names a real ladder rung in this file (no orphan tags). LiteRT device-only
               contingency documented in ADR-0002 if the sim slice is ever absent
32 perf(bench): make bench on-device harness emits JSON (device, iOS, thermal, run count,
               warm-up policy)
33 docs(method): BENCHMARK_METHOD.md (ecosystem comparison; native precision per side —
               Apple FP16 vs Google FP32 — reported prominently; different weights;
               warm-up policy; run counts; thermal state) + LIMITATIONS.md
34 docs(loop): EVAL_LOOP.md (product loop == eval loop) + docs/prompts/ (one per rung)
35 docs(monetization): MONETIZATION.md (Pro surface as a plan; revisit-trademark line)
               + docs/ASO.md
36 docs(readme): COMPLETE the README — fill the latency table with real runs, link the 20s
               video as a GitHub attachment (NEVER a tracked GIF — ADR-0007), publish docs/
               via GitHub Pages (the README itself lands at rung 01)
37 build(app): the installable app shell — a committed minimal Xcode project at
               App/Inferlens.xcodeproj wrapping the package (library products only; signing
               stays the maintainer's; ADR-0011)
38 feat(labels): index -> word, so the thumbs signal is judgeable — the loop's human surface.
               The screen showed `class 973`, an ImageNet index nobody can judge, so the signal
               measured plausibility rather than correctness. The table is DERIVED at bootstrap
               from the pinned Apple .mlmodel's own embedded 1001-entry label vector (never a web
               list: those are 1000 entries with no background class, and the off-by-one puts a
               confident wrong word under the thumbs button). Ordering is proved three ways —
               count, eight spot-checks against upstream TensorFlow's published output, and a
               fixture photograph whose subject is known by looking at it. One table, both
               engines; `class N` stays the explicit fallback (ADR-0012)
39 feat(remote): the chain's third leg becomes provable code — the thesis's backend choice becomes
               real. "Choose next model/backend" is only a choice if a remote backend EXISTS; until
               now the leg was a stub whose whole contract was one thrown error, so the sentence
               named an option nothing could take. The leg is now a URLSession engine over a wire
               contract documented as the API's source of truth, and it is proven the way ADR-0010
               said a remote leg would have to be — against a local test server the suite stands up
               (an NWListener loopback fixture; Network is a system framework, so no dependency is
               added and invariant 5 is untouched). It passes the same engine-agnostic conformance
               suite as the two on-device engines, which the stub explicitly could not. Composed
               with NO endpoint it throws exactly as the stub did, so nothing users see changes and
               no public endpoint ships (ADR-0013)
40 feat(eval): the loop's sixth clause becomes code — `export -> offline eval` stops being a
               sentence about tooling that does not exist. ADR-0011 deferred this and named the
               condition ("its revision is its own ADR when real data exists to evaluate"); two
               releases now ship a real exported-runs.ndjson, so the deferral is met on its own
               terms. An InferlensEval LIBRARY (tested by the pinned simulator suite like every
               other module) plus a thin inferlens-eval executable: parse the export key-set-gated,
               refusing malformed rows by line and key rather than repairing them; group by
               (backend, device, OS) so invariant 7 decides the population and not just the caption;
               p50/p95 by CALLING InferlensBench.LatencyRecorder, never by reimplementing it, with
               a test asserting that as an identity; the signal table under the schema's superseding
               read rule, reported and explicitly not weighed. The verdict RECOMMENDS only above a
               maintainer-ratified 20 warm rows per compared backend — a number read off the
               ratified nearest-rank percentile, below which p95 is the slowest run — and otherwise
               prints a refusal naming the shortfall and what would satisfy it. On today's four-row
               corpus the refusal IS the output (ADR-0015)
```

**Split rule honored:** the conformance work splits into stub / suite / proofs / wiring
(05–08); SQL vs NoSQL (18/19); produce-artifact vs wire-binaryTarget (13/14);
engine-lands-isolated vs enforce-the-boundary (15/16); state-enum vs screen-wiring
(23/24); signal vs export (25/26); CI vs on-device bench (31/32); each doc cluster its own
rung. The README is created at rung 01 and completed at rung 36 — not created twice.

## Phase map (groups the ladder into the six README phases; make readme-sync reads it)

`make readme-sync` reads the lines below plus the `rung-*` tags to regenerate the README rung-status
block — edit the grouping HERE, never in the README. Every rung 00–40 belongs to exactly one phase, and
readme-sync fails loud if this map and the ladder ever disagree.

<!-- phase-map:start -->
- Foundation: 00 01 02 03 04 05 06 07 08
- Supply chain: 09 13 14
- Engines: 10 11 15 16 21 22 39
- Measurement: 12 17 32 33 36 37
- Product loop: 18 19 20 23 24 25 26 27 28 29 30 34 35 38 40
- Hardening: 31
<!-- phase-map:end -->

**Rung numbers are identifiers, not a work queue.** Tags bind to them (`rung-N`), the badge counts
them, and a published tag cannot be renumbered without invalidating what it names — so a rung keeps
its number for the life of the repo regardless of when it lands. Landing order is recorded in the
section below, and a rung landing out of numeric order is a routine decision to justify there, not a
deviation to apologise for. Written down because the ambiguity has surfaced twice, and each time the
absence of this line made an ordinary reordering read as a violation.

**Deliberate out-of-order landings.** The ladder is a dependency order, not a queue, and a rung
taken early is recorded here so a gap in the generated block is legible as a decision rather than
read as a skip. The block itself is honest by construction — it shows `[x] 23` beside `[ ] 19` and
`[ ] 20` — but only the *why* is missing from it, and the why is the part that rots.

- Rung 23 landed before 19 and 20. Both of those add a module with no producer — a second store
  and a flag provider nothing reads — while 23 extends the `run → ledger` chain the product-loop
  phase exists to close. Landing them first would have enlarged the sentence the README already
  has to write about steps that do not touch. Deliberate, not skipped; 19 and 20 remain on the
  ladder and are unblocked.

- Rungs 19 and 20 landed after 23 and 24, and **together**, which is the point. The objection
  recorded above — that each "adds a module with no producer" — is true of either one alone and
  false of the pair: rung 19's document store exists to hold the flag cache, and rung 20's provider
  is what reads it. Landing 19 by itself would have shipped a store with no client; landing 20 by
  itself would have shipped a provider whose flags do not survive a launch. So the deferral was
  removed by making the objection untrue rather than by overruling it.

  The pairing is also what let rung 19 ship **smaller than its ladder line**: with a real consumer
  in hand, the model-metadata half had to justify itself against three existing records and could
  not ([ADR-0009](adr/0009-document-store-scope.md)). A speculative store would have kept it.

  Neither rung is a prerequisite for the screen that preceded them. That ordering was a choice, not
  a dependency: hardcoding one engine for one rung is honest and reversible, where a flag system
  built to avoid hardcoding it would have been the module-with-no-producer this section already
  warns about.

- Rung 37 landed before 30–36. The measurement rungs — the on-device bench (32), the method doc's
  numbers (33), the demo video (36) — require an installable app, and nothing in 30–36 is a
  prerequisite for the shell. That is the whole reason; the decision record is
  [ADR-0011](adr/0011-app-shell.md), and the launchability raise below records the closure.

- Rung 38 landed before 30–36, and its number is the point of the exercise. The rung fixes a defect
  in the **thesis**, not in a view: the loop's third clause is *capture signal (thumbs)*, and a
  signal captured against `class 973` measures how plausible the app felt rather than whether it was
  right. Every rung downstream that reads the ledger — the export's offline eval, the agreement
  measurement — would otherwise be built on signal rows nobody could have judged. It is also a
  prerequisite for the demo the README's completion wants: a video of someone approving `class 973`
  demonstrates the wrong thing.

  **Ownership was corrected before the rung was written, exactly as at rung 37.**
  [ADR-0009](adr/0009-document-store-scope.md) had named the label table "the one candidate that is
  real" for the document store and then declined it, assigning the reconciliation to the cross-model
  agreement rung. Declining was right; the destination was wrong, twice over. The table is not a
  document-store subject — nothing about it is a document, a cache, or a per-model record — and it is
  not the agreement rung's either, because that rung MEASURES disagreement and needs a shared
  vocabulary to express one in. Giving it away would have made the agreement rung's first task
  building what its own subject presupposes. Recorded rather than silently reworded; the declining
  paragraph in ADR-0009 stands, annotated. Full reasoning:
  [ADR-0012](adr/0012-label-table-provenance.md), Decision 4.

- Rung 39 landed before 30–36, and it is the ladder's own future being executed rather than a new
  idea. [ADR-0010](adr/0010-remote-leg-scope.md) recorded a real remote endpoint as the option NOT
  taken and named exactly what would unblock it — "a local test server in the suite is provable; a
  hardcoded third-party URL is not". That condition became satisfiable with no new dependency, so
  the rung is the earlier ADR's own standard being met, not a scope increase. It is placed in the
  Engines phase, beside the two rungs that built the other legs.

  The technical reason it did not wait: the thesis's sixth clause is *choose next model/backend*,
  and until this rung the chain's third position held a leg whose entire contract was one thrown
  error. A choice with one available option is not a choice, so the clause named something the repo
  could not do. Nothing downstream is blocked by that — but every rung that cites the loop was
  citing a sentence with a hole in it, and the hole was cheaper to close than to keep annotating.

  **One prediction in ADR-0010 did not survive, which is the more useful half.** That ADR expected a
  real endpoint to bring "timeout-shaped degradation reasons". It brings none: a timeout produces no
  result, and a degradation is something a result carries. The question was forced into the open by
  a constraint nobody had looked at — `run_degradations` pins its `kind` column with
  `CHECK (kind IN ('thermallyThrottled', 'fellBack'))` in migration v1, and SQLite cannot `ALTER` a
  CHECK — so a new reason case meant a v3 table rebuild under append-only triggers. Verifying that
  turned a preference into a decision with a cost attached, and the decision went the other way from
  the prediction. [ADR-0013](adr/0013-remote-leg-realization.md), Decision 4.

- Rung 31 landed before 27–30, and it is trust infrastructure the anti-slop badge rule already named —
  "a generic `CI | passing` badge … stays off the page until that coverage actually runs (rung 31)". It
  has no code dependency on the open rungs, so it earns that sentence's condition rather than waiting
  behind features it does not touch. It completes the Hardening phase.

  **Scope, recorded so the rung's ledger closes honestly: ladder line 31's lint steps were deliberately
  NOT wired.** The line reads "make bootstrap, then swiftformat --lint, swiftlint, and build+test on the
  iOS simulator"; only build+test landed. `make lint` and `make test` are stubs that echo a TODO and exit
  0 (CLAUDE.md, Process), so invoking them in CI would be an empty target readable as a pass — the exact
  lie this repo guards against elsewhere. Wiring `swiftformat --lint` and `swiftlint`, and repointing
  `make test` at a contract-preserving runner, is the standing "wire swiftformat/swiftlint" Harness-backlog
  item, not this rung; the derived-vs-declared lints the line also lists, (a)–(d), are their own backlog
  items too, save the badge derivation (c) that `make readme-sync` already does. Recorded rather than
  silently narrowed — the same disposition as the rung 36 GIF→video correction.

  **The CI toolchain/sim split is recorded in full in the rung's prompt doc**
  ([docs/prompts/rung-31-ci.md](prompts/rung-31-ci.md)) and named on the README: no hosted runner image
  carries both Swift 6.3 and the iOS 26.1 runtime, so CI runs the exact-toolchain image (macos-26 / Xcode
  26.6, the local toolchain) on the nearest sim it has (iPhone 17 Pro / iOS 26.5), the deviation named in
  the workflow and the README. It retires by construction: `test-clean`'s destination default is the
  counted pin, so when one image ships both, deleting the workflow's resolve step restores iOS 26.1 with
  no other change.

- Rung 22 landed after 23–26, 29, 31 and 37–39, and the reason is in the ladder line's own framing.
  It reads "engine actor; cancel in-flight Tasks **when input changes**" — and an input-change site is
  a driver. There was none until rung 24 built `ClassificationModel` and rung 29 composed it, so the
  rung had no place to put its subject. The first clause was already satisfied when this rung began
  (all four engines have been actors since rungs 10, 15, 21 and 39), which is why the landing is
  entirely the second. The code named this rung by name while waiting for it, at
  `ClassificationModel.run(_:)` and at `InferenceState.applying(_:)`'s `(.inferring, .classifyBegan)`
  case; both comments are now record rather than prediction.

  **Which commit carries the tag, since this rung has TWO `feat` commits.** The convention above says
  `rung-N` tags the rung's `feat` commit; it does not say which when there are two. The tag is on
  `feat(ui)` — the driver — because that is the ladder line's literal deliverable and the rung is not
  functional before it; `feat(core)`, which lands the contract clause and is the rung's larger
  content, is pushed with it and untagged, as the ADR and the trailing docs are. Recorded because the
  convention's stated purpose ("where is this rung implemented") genuinely has two answers here.

- Rung 40 landed before 27–30 and 32–36, and it is a deferral being met rather than a rung being
  pulled forward. [ADR-0011](adr/0011-app-shell.md) wrote the condition down — *"its revision is its
  own ADR when real data exists to evaluate"* — and two releases now ship an `exported-runs.ndjson`
  produced by the shell that ADR authorized. The condition became true without anything being
  decided again, which is the same shape as rung 39 meeting ADR-0010's own standard.

  It belongs to the Product-loop phase because it closes that phase's sentence: the thesis names six
  clauses and, until this rung, the sixth pointed at tooling that did not exist. Nothing in 27–36 is
  a prerequisite — the eval reads a file, so it needs neither a thermal state, nor a flag, nor a
  device number.

  **What it is honest to say the rung did NOT produce: a number.** The whole corpus is four rows
  across two exports, one backend, one simulator. The tool refuses on it, by design, and the refusal
  is the deliverable — see the finding below on what that refusal is worth. A rung that shipped a
  recommendation here would have shipped the failure its own threshold exists to prevent.

  **Two of the driving prompt's premises did not survive contact, and both are recorded at the
  code.** The prompt specified a "version-gated" parse: the NDJSON has no version field, and
  `LedgerExport`'s gate reads the SQLite `user_version` — upstream of the export and invisible to
  anyone holding the file. The prompt also specified "depends on Core only", which cannot hold with
  its own instruction to reuse the ratified statistics, since those live in `InferlensBench`. Both
  were taken to the review loop before any code and both are decided in
  [ADR-0015](adr/0015-offline-eval-boundary.md), Decisions 5 and 2.

## Finding, recorded against `ClassificationModel` — case 3 is narrowed, not closed

Rung 22 falsified a prediction it was itself named in, which is the more useful half of landing it.

> `ClassificationModel`'s invariant-1 note recorded case 3 — two loads before any classify, where the
> cold sample carries whichever load finished last — as undecided, and named the fix: *"making it
> decided means serializing runs, which is the cancel-on-input-change rung's subject."*

That rung is rung 22, and it does the opposite. It **supersedes** runs rather than serializing them:
`start(_:)` cancels the run in flight and does **not** await it, because cancellation is cooperative
(ADR-0005 leaves an in-flight `TfLiteInterpreterInvoke` no suspension point to be interrupted at), so
awaiting the superseded run would queue the new photo behind a compute nothing can stop. A responsive
screen was worth more than a closed ambiguity.

What the rung did change: a superseded run now stops at the checkpoint after the load bracket, so
reaching an overwrite additionally requires the SUPERSEDED run's load to return after the superseding
one's. Narrower, still reachable, still ordering-decided.

**What would actually close it: a shared load task**, so two overlapping runs cannot both call
`loadModel()` — the second awaits the first's rather than starting its own. That is load
deduplication, not cancellation: it would also stop a real model being loaded twice, which is a cost
this rung leaves in place. Recorded here rather than smuggled into rung 22, whose commit would then
have touched two concerns.

## Finding, recorded against the export — the NDJSON has no version field

Found by building the reader, which is the only way it could have been found: the writer's spec is
complete and correct, and it says nothing about this because it is not the writer's question.

> `LedgerExport`'s header justifies the always-present `"signals": []` key by saying an absent key
> *"would read as 'this exporter predates signals', an ambiguity the version gate exists to remove."*
> The version gate reads the SQLite file's `user_version`. A reader holding only the `.ndjson`
> cannot see a `user_version`, so nothing in the emitted format distinguishes an old exporter's
> output from a new one's.

The clause it defends is still right, and for a better reason than the one given: the explicit empty
array removes the ambiguity **by itself**, with no gate to consult. What is wrong is the appeal to a
gate that does not reach the reader it is invoked on behalf of. The comment is annotated at the code,
not rewritten — the disposition every corrected claim here gets.

The consequence for the eval is Decision 5 of ADR-0015: with no version to gate on, the **required
key set** is the contract. A line missing a key, or carrying one this build does not know, is refused
by line and by key. That is strictly weaker than a version — it cannot tell "newer" from "wrong" —
and it is what the format actually supports.

**What would close it: a `schema_version` key on every exported line.** Not done here, on two counts.
It changes a published interface inside a rung whose subject is a reader, which is two concerns. And
the two released exports lack the key, so a version-gating tool would refuse, on the day it shipped,
the entire corpus whose existence justified the rung — a gate whose scope excludes its only case,
which is the recurring defect this file already has a section about. It needs its own rung, with a
documented rule for what an absent version means.

## Finding, recorded against the eval — a refusal is not a result, and four rows is not a benchmark

Recorded so the rung's ledger closes honestly, and so nobody quotes the tool's output as evidence of
anything about Core ML or LiteRT.

`inferlens-eval` runs, parses both published exports, and prints a refusal. That is the correct
output and it is the whole of what the rung demonstrates: the *machinery* of the eval leg is real and
tested. It demonstrates **nothing** about which backend is faster, because the corpus is one backend,
one machine, and one warm row per file.

What the refusal is worth is that it is specific. It names the shortfall (`liteRT has 1 warm row
(needs 20); fewer than two backends measured`) and the condition that would clear it, so the gap
between "the loop is built" and "the loop has said something" is a printed number rather than a
caveat somebody has to remember. The measurement rungs (32, 33, 36) now have a consumer waiting with
a stated appetite: twenty warm rows for each of two backends, on one device and OS.

**The signal half is thinner still and is reported as such.** Three signal rows exist across the
whole corpus. The verdict weighs latency only, and says so in its own output rather than in a
comment; weighing signal would need a second ratified threshold, and a rule ratified against three
rows would be a branch no real-data fixture could reach.

## Finding, recorded against a shared preprocessing seam — the resize now exists three times

Rung 39 surfaced this by adding the third copy, knowingly, rather than by discovering it.

> `LiteRTEngine`, `CoreMLEngine` and now `RemoteEngine` each carry their own `vImageScale` +
> RGB-extraction + normalization path. The three are deliberately identical — three engines that
> resized differently would be a benchmark confound (BENCHMARK_METHOD.md), which is the whole reason
> the new one was copied rather than improvised. Identical-by-discipline is exactly the arrangement
> that drifts.

It was not extracted at this rung on the split rule. A shared preprocessing seam touches the
**measured `preprocess` brackets of two already-shipped engines**, and invariant 1 puts those under
review at the diff; folding that into a rung whose subject is a new leg would put an
engine-measurement change inside a networking commit, where nobody is looking for it. It is also
not obviously a module: Core cannot host it (Core depends on nothing, and this needs Accelerate), so
the seam is either a tenth module or a shared internal target, and that is a boundary decision with
an ADR's weight rather than a refactor.

What makes it recordable rather than a nit: the failure mode is silent. A change to one copy leaves
the other two compiling, passing, and measuring a different image — and no gate in this repo
compares the three. Until the seam lands, the standing manual step is: **a change to any engine's
resize or normalization is a change to all three**, and the conformance suite will not tell you
otherwise.

## Finding, recorded against rung 31 — the steady-state gate is unsound on shared CI hardware

Running the conformance suite on a hosted runner for the first time (rung 31) exposed this — the same
"found by using the thing" genre as the `warming`, `.reset`, export-race and `crane` findings, invisible
to every gate until the thing ran where it had never run.

> The engine-agnostic suite's steady-state check asserts run 1's compute is within 4× of run 2's — the
> gate that catches a lazy-load engine (ADR-0005). On a macos-26 CI runner it measured **10.3×** for Core
> ML (run 1 0.52 s, run 2 0.05 s) and reddened the build, though the identical code passed locally and on
> two prior CI runs. The first classify pays a model-compile / first-inference cost `loadModel`'s warm-up
> does not cover on the CPU-emulated simulator — and the Core ML test's own caveat claimed the opposite
> ("the steady-state half passes TRIVIALLY here — run 1 ≈ run 2"), which running on hosted hardware
> falsified.

On shared, virtualized hardware the check cannot tell a genuine lazy-load from an emulator's cold
first-inference: a single-run ratio is weather, not evidence. The resolution is SCOPE, not a wider
threshold. The gate is split into per-engine `…SteadyStateTiming` tests that XCTSkip on shared CI
hardware — logging the measured ratio, so a CI results page reads "3 timing tests skipped on shared
hardware", the precise fact — and gate fully at 4× locally and on devices. `steadyStateMaxRatio` is
untouched everywhere it runs, so no invariant-1 biasable choice is re-ratified: the maintainer ratified
the SCOPING, not a value. The `test<Engine>ConformsToContract` tests keep only shape/behavior and run
green everywhere; the suite count grew by 3 (one timing test per engine), and the counts moved together in
CLAUDE.md and the README. The falsified Core ML sim-caveat comment is corrected in the same change.

Why the split rather than a retry or a looser ratio: a retry masks real regressions too, and a looser
threshold weakens the gate on device where it IS sound. Splitting keeps 4× exactly where timing is
meaningful and removes it exactly where it is noise — and every test's label stays exactly true, which is
the property a retry or a widened constant would have quietly spent.

## Product finding, recorded against rung 24 — two states look identical and mean different things

> `loadingModel` and `inferring` render identically — same spinner, one differing label. They mean
> different things to a waiting user: a cold start that happens once, versus a per-photo cost that
> repeats. Nothing on screen distinguishes them. Surfaced by rendering the five states side by side;
> invisible in the code, and no gate can see it.

Rung 24 owns the screen and owns this; it is not fixed here. Recorded because of where it came from.

**Closed at rung 24, and the fix is a difference in SHAPE.** The load is now a full-width card with a
subtitle — "First run only — this happens once per launch" — and the inference is a compact inline
row. Re-labelling would not have closed it: people watching spinners do not read labels, so two
states separated by one word are two states nobody can tell apart. The regenerated `state-02` and
`state-03` images are the evidence, and they differ in height (486 px against 174 px) before a reader
gets as far as the text.

This is the JD's "AI UX under non-determinism" in one concrete case, and the concrete case is sharper
than the phrase. What a user waiting on a spinner needs is not *working* — it is **will this happen
again**. A cold start is a once-per-launch cost a person will absorb without complaint if they know that
is what it is; the same spinner appearing on every photo is a product that feels slow. The two are the
same pixels today, separated by one word, and people watching spinners do not read labels. The server
analogue is the one ADR-0001 draws: "connecting" and "generating" are both waits, and a UI that renders
them identically has told the user nothing they can act on.

**Where it came from is the point.** Every other finding this session was caught by a check, or by
building a check after a defect appeared — the placeholder glyph, the all-black capture, the clipped
text, the gate flagging its own prose. This one came from *looking at the five states next to each
other*, which no assertion in this repo could have produced: the images are correct, the state machine
is correct, every gate is green, and the screen is still ambiguous to the person it is for. A test can
tell you the render matches the view. It cannot tell you the view answers the user's question.

So it is written into the ladder rather than left in a session log, where it would evaporate — and it is
the argument for rendering the states side by side at all, beyond having pictures for the README.

## Finding, recorded against a later rung — `.reset` now has no emitter

Building the screen's driver produced a second finding, of the same kind as the `warming` correction
and found the same way: by trying to use the thing.

> `InferenceEvent.reset` returns the machine to `idle` from anywhere. After the screen rung, **nothing
> in the shipped app emits it** — only tests do. The event enum's own documentation forbids exactly
> this: "an event with no emitter would smuggle back exactly the unreachability the `warming`
> correction removed."

It has no emitter because using it would strand the screen. `idle` means "nothing is loaded" to the
transition table — `(.idle, .classifyBegan)` is refused — but a driver that has run once has a
**loaded** engine. A reset therefore lands the machine in a state whose only exit is
`.modelLoadBegan`, and emitting that would draw "Preparing the model" for a load that never happens.

The three ways out are all worse than having no Clear button, which is why the screen has none: lie
about a load, unload a model that is perfectly good, or teach the machine a notion of "loaded" it does
not have. The third is the real fix and it is a **state-machine change, not a screen change** — which
is why this is recorded rather than done at the screen rung. Choosing another photo is legal from
`success` and from `failed`, so nothing is blocked meanwhile.

## Finding, recorded against the composition — the export affordance can lag the first run

Driving the shell-installed app end to end at rung 37 surfaced this; the same genre as the
`warming` and `.reset` corrections — found by using the thing, invisible to every gate.

> `ComposedScreen` refreshes `canExport` on `.task` (the ledger just opened, zero rows) and on
> every `model.state` change. `ClassificationModel` appends a finished run to the ledger in an
> UNSTRUCTURED task (`pendingRunAppend`) that nothing awaits before the state becomes `success`.
> The refresh and the append therefore race: after the FIRST run of a fresh install, the export
> button can stay disabled although the row is already in the ledger, until any later state
> change refreshes it again.

By construction, not by observation: on this rung's simulator drive the button was enabled by the
time it was tapped (a second run had refreshed it), and the taps that missed earlier did so for a
window-coordinate reason unrelated to the app. The thumbs path does NOT race — it awaits
`pendingRunAppend` before appending its signal, which is why both verdicts landed. The fix
belongs to the composition (refresh after the pending append completes, not merely on state
change); recorded here rather than patched at this rung — the shell rung ships a run/install
path, not a behavior change.

## Finding, recorded against the Core ML engine — a class is lost, and a dictionary loses it

Rung 38 surfaced this. Same genre as the `warming`, `.reset` and export-race findings — found by
using the thing, invisible to every gate — with one difference: this one was invisible because
nothing could COUNT it until the label table arrived.

> `CoreMLEngine` reads its results from `classLabelProbs`, which Core ML hands back as a
> `[String: probability]` DICTIONARY keyed by label. The model has **1001** output positions but only
> **1000** distinct label strings, because `"crane"` is the label of both index 135 (the bird) and
> index 518 (the machine). Two positions collapse onto one key: one probability never reaches the
> engine, with no error, and not deterministically the same one. That engine has always returned 1000
> classifications, not 1001.

It could not have been noticed before. A count nobody took, over two classes nobody could tell apart
— both were the string `"crane"`, so even reading the output by hand would have shown one plausible
row. The table made the count checkable (1001 positions against 1000 distinct labels), and the
assertion that was written to say "the model emits one probability per table row" failed with
`("1000") is not equal to ("1001")`. The test was wrong and the finding was real, which is the useful
kind of failure.

The fix is to read the raw output vector positionally instead of the label dictionary — a change to
how the engine talks to Core ML, not a labelling change, so it is recorded here rather than done at
the labelling rung. Meanwhile the number is asserted in `CoreMLLabelTests` and stated at the code in
`CoreMLEngine.classifications`, so it is a documented property rather than a surprise waiting for
whoever next compares the two engines' output lengths.

Worth naming for the general lesson, which is the inverse of the recurring defect below: that one is
a check whose SCOPE excludes the failure. This is a failure no check could have had in scope, because
the vocabulary needed to state it did not exist yet. Adding a fact to a system sometimes makes an old
silence audible.

## Finding, recorded against the agreement rung — the index is not in the ledger

`Classification` gained an `index` at rung 38: the model's own output position, which is its raw
identity for a class where the word is a rendering of it. The screen shows it. **The ledger does
not** — no column, no migration, and the NDJSON export is byte-identical with and without an index on
the value type (asserted in `LedgerExportTests`, stated as data rather than as a snapshot).

That is a deferral with a reason, not an oversight. The ledger records the fact a person judged — the
word they saw — and a schema migration needs a caller. The first thing that would want one is the
cross-model agreement rung: comparing two models by label string is comparing renderings, and
`"cornet"` against `"cornet, horn, trumpet, trump"` is a formatting difference dressed as a
disagreement. Index-keyed comparison is the right shape for that rung, and it should add the column
when it needs it rather than have one waiting for it.

The consequence to know meanwhile: a `Classification` read back out of a ledger row has `index ==
nil` even when the one written had an index. Round-tripping is lossy in exactly that field, and it is
documented at the property.

## Harness backlog — a standing shell-build gate (recorded at rung 37)

The shell's proof at this rung is manual: `xcodebuild build` against `App/Inferlens.xcodeproj`
for the simulator and (unsigned) for the device slice, the bundled model bytes hash-compared to
the fetched originals, a simulator install+launch, and `test-clean` re-run with the project in
the tree — the last one because a root-placed project would enter xcodebuild's container
discovery and break the bare `-scheme Inferlens-Package` resolution (probed at the rung-37
landing; the shell lives under `App/` for exactly that reason). Wire it as a scripted gate with
the 0/1/2 contract at the CI rung; until then it is a manual step in the landing checklist,
beside the others this file already names.

## Product finding, recorded against rung 19 — model metadata already lives in three places

Rung 19 reads "document/KV store for model metadata + flag cache (NoSQL)". That is two things, and
only one of them is clearly earned. Recorded now, while it is fresh, rather than discovered by
whoever builds it — the same disposition as the `loadingModel`/`inferring` finding against rung 24.

**The flag cache is earned.** Flags have to survive a launch, and nothing in the repo persists them
today: [InferlensFlags](../Sources/InferlensFlags/InferlensFlags.swift) is a three-line skeleton.
(True when recorded. Rungs 19/20 then landed exactly this split — the cache in `DocumentStore`, the
provider over it — and ADR-0009 is this finding's resolution; the sentence above stays as the state
that motivated it.)

**The model-metadata half is not, yet.** The same facts are already recorded in three places, each
doing a different job, and a KV store would be the fourth:

| Where | What it holds | What makes it different |
|---|---|---|
| [MODEL_PROVENANCE.md](research/MODEL_PROVENANCE.md) | which bytes, from where, at what checksum | build-time, human-readable, reviewable in a diff |
| [`fetch-models.sh`](../scripts/fetch-models.sh) via `make bootstrap` | the same facts, enforced | fails closed on a mismatched pin — a claim with teeth |
| the ledger row (`LedgerSchema`) | `model_name`, `model_precision`, `model_input_width/height` | copied per run, so a row stays self-contained when the model is swapped |

CLAUDE.md is explicit that a module serving no clause of the thesis is cut. So rung 19's first
obligation is to name what a store holds that those three do not — and if it cannot, to drop that
half and record the decision. **The decision not to duplicate is worth as much as the store**, and it
is an ADR either way.

The one candidate visible from here is the **ImageNet label table**: `MODEL_PROVENANCE.md` records
that the raw `.tflite` carries no embedded label strings, so the LiteRT engine named classes
positionally while the Apple side carried real strings. That is a genuine gap none of the three fills
— but the same document assigns the reconciliation to **rung 17** (cross-model agreement), not to 19,
so claiming it here would take a rung's subject from another rung rather than justify this one.

*(True when recorded, and both halves have since moved. The gap was closed at rung 38, not by a
document store: the table is derived from the pinned `.mlmodel` and lives on the model path. The
rung-17 attribution was wrong for the reason given in [ADR-0012](adr/0012-label-table-provenance.md),
Decision 4 — the agreement rung needs a shared vocabulary to express a disagreement in, so it cannot
also be the rung that builds one. The paragraph stands as the reasoning that was available then;
this rung's keyed claims-audit is what caught the stale present tense in it.)*

Scope, and what this finding did NOT read: it compares what the three sources *record*. It does not
survey NoSQL options, does not say what shape a store should take if one is built, and says nothing
about the flag half beyond that it is earned.

## Harness backlog — the per-rung claims audit (recorded at rung 12)

Rung 12's real cost was not the `LatencyRecorder`; it was tracking one false claim ("the
aggregation is hand-written") across twelve sites. Three were invisible to a working-tree
`grep -r` and cost most of the passes:

- a claim inside a **commit message** (`git log`, not the tree)
- a **dead-sha reference** — alive locally via a backup branch, but 404 on origin once a
  rebase orphaned the sha it named
- stale text a **rebase resurrected** from an old commit *after* the sweep had already passed

So a per-rung **claims audit**, keyed on the rung's subject-claim, must sweep all three
surfaces — the working tree, `git log --format=%B`, and dead-sha references (short-sha strings
that a rebase can orphan) — not just `grep -r`. It lands as a lint with the CI rung; until
then it is a manual step in the landing checklist. This is a derived-vs-declared check like the
others (a claim is "declared" in the subject and must hold everywhere it is "restated").

## Correction of record — test-clean returned 1 for a build failure the contract assigns to 2

This section used to be a backlog item: the exit-1 and exit-2 paths were unexercised and should be
teeth-tested, because "an unexercised contract is a claim, not a guarantee." That was right, and the
claim was false. Exercising it found a real bug.

`37fbc1e`'s pushed body states the contract as "2 the harness could not run (no simulator, **or the
build never reached test execution**)". The script did not do that. It returned 1 on the
`** TEST FAILED **` marker alone — and under `xcodebuild test` a failed **build** emits that marker
too, because the action that failed is the test action whatever stopped it. So a compile error
returned 1, "tests ran and failed", for a run in which no test ever executed. The claim was wrong
when it was written.

Observed, not hypothesized: a compile error in `InferlensStore` during the run-ledger rung produced

```
Testing failed:
    Overlapping accesses to 'info.machine', ...
    Testing cancelled because the build failed.
** TEST FAILED **
The following build commands failed:
```

Note what is absent — no `** BUILD FAILED **` (the test action swallows it), and no `Executed N tests`
line at all. **The presence of an `Executed` line is the discriminator**, not the SUCCEEDED/FAILED
marker: it is the only thing in the log that says the runner reached test execution. Fixed in
`fix(scripts): test-clean returns 1 for a build failure the contract assigns to 2` — exit 1 now
requires the marker **and** an `Executed` line; everything else is 2, with the build-failure case
named in its own message.

`37fbc1e` is pushed and cannot be amended without rewriting shared history, so the correction lives
here — the same disposition as the rung 26 → 31 correction below.

### The contract, exercised — every path, old script vs fixed

Each path was forced by planting the exact condition it exists to report, both scripts run back to
back on the same tree:

| Path | Forced by | Old | Fixed |
|---|---|---|---|
| 0 — tests ran and passed | the tree as committed | 0 | **0** |
| 1 — tests ran and failed | an `XCTFail` planted in the store suite | 1 | **1** (no regression) |
| 2 — build never reached tests | a type error planted in `LedgerCodec.swift` | **1** ← the bug | **2** |
| 2 — no usable destination | the simulator parser forced to return no records | 2 | **2** |

Path 1 holding at 1 matters as much as path 2 moving to 2: a "fix" that collapsed every failure to 2
would satisfy the headline and destroy the contract. The point is that the two stay distinguishable.

Scope, honestly: the last row was forced by neutering the parser, not by removing the machine's
simulators, so it proves the branch refuses to fall through to a default destination — it does not
prove behaviour on a genuinely simulator-less machine (a CI runner will). Automating all four as a
standing check lands with the CI rung; until then they are a manual step in the landing checklist.

The general lesson is the one this repo keeps re-learning: a marker is not the same as the thing it
is read to mean. `** TEST FAILED **` was trusted to mean "tests failed" for the same reason a reused
DerivedData was trusted to mean "this tree passed" — nobody had made it lie on purpose yet.

## The claims-audit contract — Check A is pre-push, Check B is POST-push

Recorded so the next red is judged rather than waved past, because it will recur on every rung whose
docs cite their own commit — which [ADR-0007](adr/0007-readme-media.md) requires of any README media
caption.

`claims-audit.sh` runs two independent checks and reports both through one exit code:

- **Check A — forbidden claims** (`claims-audit.sh:45`). Sweeps the working tree and the unpushed
  commit messages for phrasings that are false in this repo. It reads only what is already local, so
  it is meaningful at any moment. **A pre-push gate: red means fix it before pushing.**
- **Check B — dead-sha references** (`claims-audit.sh:89`). Every short sha named in the docs must be
  reachable **from `origin/main`**, because a reader's commit link resolves against the remote, not
  against a local clone. **A post-push gate**, unavoidably: a caption that cites its own rung's `feat`
  commit names a sha that by construction is not on origin until the push happens.

So: **a red Check B immediately before pushing a doc that cites its own sha is expected, and is the
gate working.** The judgement is the re-run straight after the push, when the sha is reachable. **A
Check B still red after the push is a real finding** — the caption names a commit that does not exist
on the remote, usually because history was rewritten after the caption was written, and a reader's
link 404s.

**Amendment — Check A has TWO surfaces, and one of them is empty after a push.** The rule above
says when each check is authoritative. It omitted that Check A is not one sweep but two, with
different lifetimes:

- **A1, the working tree.** Always live, independent of what has been pushed.
- **A2, the commit messages**, over `RANGE="$BASE..HEAD"` — `origin/main..HEAD`, set at
  `claims-audit.sh:42` from the `BASE` at `:37`. After a successful push that range is **empty**,
  so A2 inspects nothing.

So the two runs cover different things:

| Run | A1 (tree) | A2 (messages) | Check B (shas) |
|---|---|---|---|
| pre-push | live | **live — the only time it runs** | expected red if a doc cites its own commit |
| post-push | live | **empty — inspects nothing** | authoritative |

**Neither run alone is the full gate.** The pre-push run is the only one that ever reads a commit
message; the post-push run is the only one whose Check B verdict means anything. So **"claims-audit
is green" is never a blanket pass — it is always qualified by which side of the push it came
from**, and a report that omits which side has said less than it appears to.

A2 is not an incidental surface. It is the **second** of the three surfaces named in the per-rung
claims-audit item *above*, and it is the one rung 12 built Check A for, after a false claim inside
a commit body survived a working-tree `grep -r`. A workflow that only ever ran the gate after
pushing would never exercise it.

Deliberately **not** recorded as an eighth instance of the recurring defect. No check here has run
and reported clean about the wrong corpus; what exists is an **incomplete rule** — a documented
gate whose scope statement omitted a surface. It becomes an instance the first time someone reads
a post-push green as a blanket pass, which is what this amendment exists to prevent. Counting it
now would inflate a count already corrected twice in the same series.

One property of this amendment is the cheapest possible demonstration of it: the commit that lands
this text is unpushed when its own gate runs, so `RANGE` is non-empty and **A2 is live over this
commit's own message**. The text documenting A2's coverage gap is covered by A2 — verified by
running the gate before pushing, not asserted.

Two consequences worth stating, since the exit code alone cannot distinguish them:

- The gate reports exit 1 for either check, so "claims-audit failed" must always be read with the
  FAIL line beside it. A pre-push red that names a forbidden claim is a stop; one that names only a
  sha the current push will publish is not.
- Rewriting history after writing a caption invalidates the caption. It happened at the screen rung:
  the feat commit was rebuilt to move a comment into it, its sha changed, and the caption had to be
  repointed — Check B is exactly what would have caught that had it gone unnoticed.

**Amendment two — the gate must run BETWEEN commit and push, or A2 never sees the message.** The
window in which `RANGE` is non-empty is after `git commit` and before `git push`: that is the only
moment A2 can sweep the message being landed. A gate run before the commit exists sweeps every
message except the one being written, and the post-push run sweeps none. Not hypothetical — two
published messages were never swept by any valid A2 run: the out-of-order record (`91b3280`; its
gates ran pre-commit, `make land` amended it twice, and the push followed with no gate between) and
the 83-to-108 count fix (`e3eb479`; same shape). Both were reviewed by hand, which is a disposition,
not a gate. So the landing order is: edit, then width/anchor/A1, then commit, then **claims-audit**,
then push. `make land` does not run the gate — a named gap, like the tag-convention gap already
recorded for it — so the step is manual until the Harness backlog lands it.

## Harness backlog — a cross-document pointer check (recorded now)

claims-audit catches forbidden phrasings and dead shas, but not cross-document POINTERS: a `rung N`
that names no rung in this ladder, a `#anchor` that no heading generates, a repo file path that has
moved. Same breakage as a dead sha — a well-formed pointer to nothing — a different regex. Motivating
case: the CI build+test gate is rung 31 here, yet eleven prose sites (`.github/workflows/build.yml`,
`CLAUDE.md`, `README.md`) had drifted to "rung 26" — the ledger-export rung — and nothing caught it.
Add this check with the CI rung; until then it is a manual landing step, beside the no-simulator teeth
test above.

**The specification, written from a sweep that was actually run.** A check described as a good idea
gets built less often than one whose spec already exists, so the manual sweep done at the screen rung
is recorded here as the spec rather than as an anecdote.

- **Pattern:** `rung [0-9]` and `rung-[0-9]`, **case-insensitive**. The first run of this sweep was
  case-sensitive and silently missed every sentence opening with `Rung 04's …` — seven lines,
  including three in the contract file. The scope gap was in the grep itself, which is the defect this
  ROADMAP section already names.
- **Corpus:** `Sources/ Tests/ scripts/ Makefile .github/ CLAUDE.md docs/adr/` **plus the root
  dotfiles** — `.swiftlint.yml` carried two, and the first sweep did not read it because the corpus
  was written as directories.
- **Three-way classification** for every hit:
  1. a hard-coded ladder number in code or config → **remove it**, cite the stable component name;
  2. a `rung-N` **tag** name (`make land`, the badge derivation, the tag convention) → **legitimate**,
     tags are identifiers and that is what this file now says they are;
  3. a **historical quote or authorship record** — `commit-hygiene.yml`'s record of the broken
     `ci.yml`, the invariant-1 correction trail in `CLAUDE.md` and ADR-0005, the RED/green pair note in
     `LatencyRecorderTests` → **leave**, and check a quote carries its do-not-update marker.
- **Measured blast radius, not an estimate:** 95 hits. The contract file alone
  (`InferenceEngine.swift`) held **14 wrong** ones, and `InferlensApp.swift` one more; the rest of
  `Sources/` and `Tests/` resolved correctly and were converted to component names anyway.
- **Why neither existing gate sees it:** claims-audit reads shas and forbidden phrasings, anchor-check
  reads headings. A well-formed reference to the *wrong* rung is invisible to both.

## Harness backlog — audit the claims written AHEAD of their implementation (recorded now)

Every correction this session came from new work touching an old assumption — the screen rung reading
the contract file, the rung-19 question reading the flags skeleton — and none came from sequential
review. That is a pattern with a target: **a claim written before the thing it describes exists** is
the one most likely to be wrong, because nothing has yet forced it to be true.

The instances are all of this shape: `InferenceEngine.swift` named the recorder's rung four rungs
before the recorder was built and got it wrong; `InferlensFlags.swift` named its own two rungs and got
both wrong; `CoreMLEngine`'s brackets carried a "hand-written" label that was false when written. The
audit is: for each doc comment that describes something not yet built, check it against what was
eventually built, and correct or delete it.

It pairs with the cross-document pointer check above — same job, one keyed on pointers and one on
claims — and lands with the CI rung. Until then it is a manual step in the landing checklist.

## Harness backlog — wire swiftformat/swiftlint, and a contract-preserving make test (recorded now)

`make lint` and `make test` are stubs that echo a TODO and exit 0 — they check nothing, so they are not
part of the green bar (CLAUDE.md's Process now names `bash scripts/test-clean.sh` as the real runner).
Wire `swiftformat --lint` and `swiftlint` into `make lint`, and repoint `make test` at a runner that
preserves test-clean's 0/1/2 exit-code contract — a naive `test: test-clean` would route the suite
through `make`, which collapses a recipe failure to a bare 2 and erases the fired-vs-could-not-run
distinction. Lands with the CI rung; until then the green bar rests on test-clean run as the script, plus
the standing commit-hygiene and claims-audit gates.

## Harness backlog — teeth-test the commit-hygiene WORKFLOW with a planted trailer (recorded now)

This item asked for a teeth test of "commit-hygiene (the AI-attribution-trailer lint that runs on every
push, plus the committed commit-msg hook)" as one gate. Doing it showed they are **two** gates, and the
test only covered one.

The **`commit-msg` hook** is now teeth-tested: a message carrying a planted `Co-Authored-By: …Claude`
trailer is rejected with exit 1 and its own explanatory message, then removed. Done.

The **CI workflow** (`.github/workflows/commit-hygiene.yml`) is NOT. It greps the pushed commit range for
`co-authored-by.*claude|generated with|🤖` — different code, in a different place, running on a different
machine from the hook — and nothing has forced it to refuse a planted trailer. The hook's result is not
evidence for the workflow, so the README now counts **five** standing gates, four teeth-tested, rather than
folding the two together to reach "four of four."

To close it: push a branch whose head commit carries a planted trailer, confirm the workflow run fails,
delete the branch. It cannot be done by amending `main` — the hook would reject the commit locally before
it could ever reach CI, which is itself worth noting as evidence the two gates are independent.

One already-pushed commit records the superseded count in its own subject: `ba23aed` ("the harness pillar
is working — four standing gates, three teeth-tested this session"). It is reachable on origin and cannot
be amended without rewriting shared history, so the corrected count is recorded here and on the README
instead — the same disposition as `37fbc1e` above and the rung 26 → 31 correction below. This is the
commit-message surface the rung-12 claims audit was built for: a `grep -r` over the working tree would
never have seen it.

## Harness backlog — the exit-code contract is exercised for test-clean only (recorded now)

The three script gates share one exit-code contract: 0 clean, 1 findings, 2 the gate could not run. Only
`test-clean`'s has been driven down every path (see the correction of record above), and doing so found a
real bug — so this is not a theoretical gap.

`claims-audit` and `anchor-check` both have a findings path (exit 1) that has been teeth-tested, and both
have a could-not-run branch (`claims-audit.sh:40`, `anchor-check.sh:32` and `:84`) that **nothing has ever
forced**. An unexercised could-not-run branch is the same hazard as the one just fixed: if it silently
returns 0 or 1, a gate that never ran becomes indistinguishable from a gate that passed. Force each — a
non-git working directory, and whatever internal failure line 40 guards — and confirm the exit is 2 and
distinguishable from both a pass and a finding. Lands as a check with the CI rung; until then it is a
manual step in the landing checklist, beside the workflow teeth test above.

## The launchability raise — raised at rung 29, closed at rung 37 on the shell side

The composition rung's green bar is real and is stated precisely in its commit: the composed app
BUILDS for the simulator inside the test-clean run. What it does not produce is an installable
`.app` — a pure-SPM `executableTarget` is a bare binary with no bundle, no `Info.plist`, and no
code signature, so "runs on a phone" is not yet a sentence this repo can write. Closing that gap
means an app shell, and an app shell touches invariant 5 ("No CocoaPods. The build is pure SPM"):
whether the shell is an `.xcodeproj` that wraps the package, an XcodeGen/Tuist-generated project,
or something else is a DECISION with an ADR's weight, not a chore — the invariant's wording was
written before this fork existed, and the decision must either fit inside it or amend it the
recorded way. Raised at rung 29 (where the gap became load-bearing) against the rung that will hit
it first: rung 36's demo video needs the app running somewhere real. Until that decision is made,
every claim about the app stays scoped to "builds under the package scheme on the simulator" —
which is what the README's composition bullet says, verbatim. (True when written; the decision and
its landing are recorded below.)

**Closed at rung 37 — on the SHELL side, and corrected from rung 36.** The decision is
[ADR-0011](adr/0011-app-shell.md): a committed, hand-authored minimal project at
`App/Inferlens.xcodeproj`, dependencies still resolving through SPM, invariant 5 precised in
CLAUDE.md — its target was always dependency management. Two corrections to this section's own
text, recorded rather than silently reworded:

- **Ownership.** The raise pointed at rung 36 as the rung that would hit the gap first — right as
  PREDICTION (the demo video cannot exist before an installed app), wrong as OWNERSHIP: rung 36's
  ladder line is the README's completion, and a `rung-36` tag on a shell commit would have made
  the derived status block claim work that has not happened. The rung-31 lint clause "every
  `rung-*` tag names a real ladder rung" is the reason a 36-tag was refused — enforced early, by
  refusal, before the lint exists. The shell got its own line, rung 37, in the Measurement phase:
  it exists because the measurement rungs require an installable app.
- **The heading.** It asserted the gap in the exact words this rung's keyed claims-audit sweeps
  for, so the closure rewrites it; the original assertion stands in the paragraph above as the
  historical record — true when written, retired by the shell.

**The DEVICE run is the OPEN half, owned by the measurement rungs.** The first-run checkpoint was
reduced to a SIMULATOR run through the shell BY MAINTAINER DECISION — a decision on record, not a
silent skip. What the simulator run produced: the shell-built `.app` installed and launched on the
pinned iPhone 17 Pro / iOS 26.1 simulator; the loop driven end to end in the installed app (run →
ledger row → thumbs, a down superseded by an up with history kept → export tapped, NDJSON pulled
from the app container); every exported row carrying `Simulator (iPhone18,1)` and `iOS 26.1` in
its own columns — the `DeviceIdentity` guard labelling the simulator as such, so no row can pose
as a phone (invariant 7 doing its job either way). Nothing at this rung claims hardware; hand-run
simulator numbers are not bench numbers and are quoted nowhere.

## Correction of record — rung 36 ships an attachment-hosted video, not a tracked GIF

Rung 36 read "add the 20s GIF" from the bootstrap commit forward.
[ADR-0007](adr/0007-readme-media.md) forbids a tracked `.gif` outright — a GIF of a screen recording
is video wearing an image container, and an extension-shaped loophole is how the first multi-megabyte
file gets in — so the ladder line and the ADR could not both stand. The ladder is corrected above:
rung 36's artifact is one uninterrupted video, uploaded as a GitHub attachment and linked, and the
repo carries no video bytes.

Corrected in the ladder itself rather than only in prose, because the ladder is what a future session
reads first. Left as it was, the next person would do rung 36 from the ladder alone and commit exactly
the file the ADR exists to prevent — the correction has to be where the instruction is, not only where
the reasoning is. Same disposition as the rung 26 → 31 correction below: the fix ships with the work
that revealed it, in the same push, so the contradiction never exists on origin.

## The recurring defect, named — a check whose SCOPE excludes the failure reports clean

Naming it because it has now been found seven times — the first six rediscovered from scratch, each
as if it were new, and the seventh caught by applying this section rather than by stumbling into
it — and
an unnamed pattern gets re-derived instead of checked for. The shape:

> A check runs, passes, and reports clean — about a corpus, an input, or a failure mode that does not
> include the thing under test. The green is true and answers a question nobody asked.

Every instance so far:

| Instance | The check said | What it did not read |
|---|---|---|
| Reused `DerivedData` | "tests passed" | this tree — the result came from an older build |
| `** TEST FAILED **` read as a test failure | "tests ran and failed" | whether any test executed at all (a build failure emits the same marker) |
| `claims-audit` / `anchor-check` over `git ls-files` | "clean, 18 files" | the untracked file that was the entire subject of the commit |
| The yellow-placeholder assertion in `StateScreenshotTests` | "the render is fine" | an image that was **entirely black** — a blank frame contains no yellow |
| `media-check`'s first alt-text pass | "3 findings" | the difference between an image and prose *about* an image, in backticks |
| Every render assertion, over the new load card | "the image drew correctly" | whether the text was **horizontally truncated** — SwiftUI ellipsises instead of overflowing, so no ink ever reaches the edge the clipping test watches |
| **The whole gate set, over the committed PNGs** (permanent, not a miss) | "green" | whether the images still match what the views render — the only check that could tell is skipped in every ordinary run |

Instances five and six arrived within an hour of each other, which is what forced this section.

The sixth arrived at the screen rung and is the sharpest yet, because the check that missed it was
written *specifically* to catch cut-off text. The bottom-edge assertion catches VERTICAL clipping: a
view measured too short renders ink through the last row of pixels. Horizontal truncation looks
nothing like that — SwiftUI replaces the overflow with an ellipsis, so the image is the right size,
has hundreds of colours, has a white background, has a clean bottom edge, and reads "First run only —
this happens once per lau…". The one sentence on the screen that answers *will this happen again* was
cut mid-word, every assertion passed, and a human looking at the picture is what caught it. Again.
No check for it has been written yet: detecting an ellipsis in a bitmap is not cheap, and a plausible
one that does not work would be worse than the honest gap. Recorded as a gap, not closed.

### The seventh is different: a permanent hole, not a miss

The first six were one-off misses — a check that ran and read the wrong thing. This one is
structural, and it does not get better on its own.

The suite at that rung reported **83 tests: 82 run, 1 skipped** (142/141/1 since rung 21). The
skipped one is `StateScreenshotTests` — the test that GENERATES the six README images. It skips
unless `TEST_RUNNER_INFERLENS_MEDIA_OUT` is set,
which is correct (an ordinary run must not be conscripted into writing files), and the consequence is
that **nothing verifies the committed PNGs still match what the views render**. Edit
`InferenceStateView`, commit, and all six standing gates pass — the four check scripts, the
`commit-msg` hook and the commit-hygiene workflow — while the README shows a screen that no longer
exists. Only four of the six could even in principle notice, and this is what each reads instead.

The hook and the workflow read commit messages and are not in the running at all. The four that scan
the repo do not read the images either — stated explicitly, because that is the rule this section
produced:

- **`media-check`** reads bytes, pixel dimensions, alt text, orphans and tracked video. It never opens
  an image's *content*, so a stale-but-well-formed PNG is indistinguishable from a fresh one.
- **`anchor-check`** reads links and headings. It confirms a pointer resolves, never what the thing it
  points at looks like.
- **`test-clean`** runs the suite — with the generator skipped. The renderer's own assertions (no
  placeholder glyph, enough distinct colours, a light background, no ink on the bottom edge) are real
  and they are exactly what does NOT run in a normal green build.
- **`claims-audit`** reads text and shas. The caption's sha proves which commit the images were
  generated from *when the caption was written*; nothing re-checks it after a later view edit.

So the caption's sha is the only link between the images and the code, and it is maintained by hand.

**Recorded as a backlog item, deliberately not closed here** — the same discipline as the truncation
gap above. The obvious check is "regenerate in CI and fail if the bytes differ", and PNG output is not
guaranteed byte-stable across toolchains or simulator versions, so a naive version would either flap
or be silently disabled. A check that does not actually work would be worse than a named hole. It
lands with the CI rung, where a pinned runner image makes the comparison meaningful; until then, the
manual step is: **regenerate the screenshots in any rung that touches a view, and update the caption's
sha.**

**The standing rule this produces: every new check states what it does NOT read**, in a comment at the
code and in the message that lands it. Not as documentation — as the design step that catches the defect,
because the scope gap is invisible from a passing run and obvious the moment someone has to write the
sentence. `media-check` prints its corpus size on success for this reason, and `test-clean` prints the
`-derivedDataPath` it used for the same one.

A second rule, from the two image cases specifically: a check aimed at one observed failure is worth
having, but it must not be mistaken for a check on the *class* of failure. The yellow assertion was
correct and useless on its own; what covers the class is the general pair beside it — distinct-colour
count and a background pixel — plus the bottom-edge test for clipping. Specific checks catch the bug you
had; general ones catch the bug you are about to have.

## Harness backlog — the earlier gates have no NEGATIVE control (recorded now)

`claims-audit`, `anchor-check` and `test-clean` have each been teeth-tested by planting the failure they
exist to catch, and each fired. None has been run against a control that must **not** be flagged. That
gap is not academic: **a gate that refused everything unconditionally would pass all three teeth tests**,
and nothing in the record would show it.

`media-check` had a negative control from the start — `plant-clean.png`, a small well-formed image
referenced with alt text, asserted to be left alone while three offenders beside it were refused by name.
That is what makes its positive results mean anything, and it is the pattern the other three need:

- `claims-audit` — a commit message and a live sha that must survive the sweep untouched
- `anchor-check` — a correct in-page anchor that must not be reported
- `test-clean` — a passing suite that must return 0 (exercised incidentally on every green run, but never
  as a stated control alongside the failure plants, which is a weaker claim than it looks)

Lands with the CI rung alongside the other gate work; until then it is a manual step in the landing
checklist.

## Harness backlog — the gates sweep `git ls-files`, so an untracked file is skipped silently (recorded now)

`claims-audit` and `anchor-check` both enumerate their corpus with `git ls-files`. An **untracked** file
is therefore not swept, and the gate says "clean" without saying what it did not look at — so a sweep's
coverage silently depends on whether the thing under test happened to be staged when it ran.

Observed while landing ADR-0007, not hypothesized: both gates were run against the new ADR while it was
still untracked and both reported clean — `anchor-check` naming **18** Markdown files. The file was
staged and they were re-run: **19** files, still clean. The second run is the one that means anything;
the first was a pass over a corpus that excluded the only new file in the tree.

This is the reused-DerivedData shape again, and the CI-workflow shape, and the `** TEST FAILED **`
shape: a green that is really a statement about a different input than the reader assumes. It was
caught by comparing 18 tracked against 19 on disk **by hand**, which is not a check.

To close it: have each gate report its corpus size, and either count untracked `*.md` and name them, or
exit **2** (could not run) when an untracked Markdown file exists — a scope the gate cannot cover should
be loud, not absent. Exit 2 rather than 1 because an unswept file is not a finding; it is the gate
declining to claim coverage. Lands as part of the CI rung with the other derived-vs-declared lints;
until then it is a manual step in the landing checklist — stage before sweeping, and read the count.

## Correction of record — the CI build+test gate is rung 31, not 26

This ladder is the index; prose is downstream of it. The CI build+test gate is **rung 31**
(`build(ci)` above); rung 26 is the ledger export. Repo prose had said "rung 26" for the CI gate in
eleven places, now corrected in the tracked tree by the `docs: correct the CI rung reference` commit
(the historical quote in `commit-hygiene.yml` is marked and deliberately left — it records the string
that actually broke). Two already-pushed commits — `4e12860` (claims-audit) and `37fbc1e`
(test-clean) — cite "rung 26" for the CI gate in their bodies and cannot be amended without
force-pushing shared history, which costs more than it buys; the correct number is recorded here
instead. From here, rung numbers are read from this ladder at the point of writing, never carried over
from conversation. Recorded like the invariant-1, invariant-2 and RAII corrections.

## Riskiest assumption (tested at rung 13, before any engine logic)

That Google's `TensorFlowLiteC.xcframework`, once re-zipped and pinned, contains an
`ios-arm64_x86_64-simulator` slice and links under Swift 6.3 strict concurrency. Rung 13's
first action reads `Info.plist` (`AvailableLibraries`) and asserts the slice; rung 14
proves it links on the simulator. If absent, the ladder goes red at 13 — before rung 15 —
and the ADR-0002 device-only CI contingency applies. See ADR-0002.

## Open inputs (approved deferrals — literals only, decisions made)

- Exact Google `.tflite` download URL — verified at rung 09. Precision (Google FP32
  default) is already decided (ADR-0003 / MODEL_PROVENANCE.md).
- Exact `TensorFlowLiteC` version pin, our release-asset URL, and its checksum — produced
  when rung 13 runs (a checksum cannot exist before the `.zip` does; ADR-0002).

## README

The project overview README lives at [README.md](../README.md) as of rung 01. It is not
duplicated here. Rung 36 completes it: the latency table filled with real runs, the video
(linked as an attachment, never a tracked GIF — [ADR-0007](adr/0007-readme-media.md)),
and GitHub Pages. The empty latency table and scoped headline are already on the page
today, marked empty because the measurements do not exist yet.
