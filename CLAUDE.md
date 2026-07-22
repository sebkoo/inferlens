# CLAUDE.md — architecture context and invariants

This file is the fixed context every change is reviewed against. It is deliberately
committed before any code. If a change conflicts with an invariant here, the
change is wrong, not the invariant — raise it, do not silently work around it.

Decisions of record: [docs/adr/0001](docs/adr/0001-module-boundaries.md) (module
boundaries), [0002](docs/adr/0002-litert-distribution.md) (LiteRT distribution),
[0003](docs/adr/0003-benchmark-comparison-scope.md) (benchmark scope),
[0004](docs/adr/0004-commit-hygiene.md) (commit hygiene),
[0005](docs/adr/0005-litert-engine-concurrency.md) (LiteRT engine concurrency),
[0006](docs/adr/0006-run-ledger-storage.md) (run ledger storage),
[0007](docs/adr/0007-readme-media.md) (README media),
[0008](docs/adr/0008-latency-summary-boundary.md) (the latency-summary boundary),
[0009](docs/adr/0009-document-store-scope.md) (document-store scope),
[0010](docs/adr/0010-remote-leg-scope.md) (the remote leg and the chain's cold rule),
[0011](docs/adr/0011-app-shell.md) (the app shell, and invariant 5 precised),
[0012](docs/adr/0012-label-table-provenance.md) (where the truth of index → label lives),
[0013](docs/adr/0013-remote-leg-realization.md) (what "real" means for the remote leg without a
production server),
[0014](docs/adr/0014-cooperative-cancellation.md) (cancellation — a contract clause, a transition,
and no ledger row),
[0015](docs/adr/0015-offline-eval-boundary.md) (the offline eval becomes code — the module graph's
first library → library arrow, and a ratified refusal threshold). Plan:
[docs/ROADMAP.md](docs/ROADMAP.md).

## The thesis

The product loop and the developer's evaluation loop are the **same loop**:
run inference → append to ledger → capture signal (thumbs) → export → offline eval →
choose next model/backend → run inference. Every decision must be defensible by pointing
at that sentence. A module that serves no clause of it is cut.

## Dependency direction (one way)

```
app  →  {InferlensUI, InferlensStore, InferlensFlags, InferlensBench,
         InferlensCoreML, InferlensLiteRT, InferlensRemote,
         InferlensFallback, InferlensEval}  →  InferlensCore

                            InferlensEval  →  InferlensBench
```

- `InferlensCore` depends on nothing. It is protocols + value types only.
- Engines (`CoreML`, `LiteRT`, `Remote`) depend on Core, never on each other. `InferlensRemote`
  is the chain's third leg as a real `URLSession` engine over the wire contract ADR-0013
  documents; it ships composed with NO endpoint, and no public endpoint ships.
- The fallback chain (`InferlensFallback`) depends on Core only: legs arrive as the protocol,
  so cross-engine work lives above the engines without naming one (ADR-0010) — including in its
  own tests, which is why the remote leg moved out of that module (ADR-0013).
- `InferlensUI` depends on Core's types and the engine *protocol*, never a concrete engine.
- `InferlensEval` reads the exported NDJSON and is the ONE module that depends on another library.
  `Eval → Bench` is the graph's first library → library arrow and it is deliberate: invariant 1 makes
  the percentile a ratified choice and `LatencyRecorder` is the only place one is computed, so the
  eval EXECUTES those choices instead of holding a second definition of the benchmark. It is legal
  under the lint below because Bench is neither an engine nor Core (ADR-0015). The eval imports no
  engine and not `InferlensStore`: the stored tokens are the format.
- The app target is thin: composition only. The `inferlens-eval` executable is thin for the same
  reason and a second one — it is the only target the simulator suite cannot run, so it holds
  nothing that can be wrong.
- A CI dependency-lint fails any arrow pointing back toward an engine or into Core.

## Invariants (forbidden patterns)

1. **Timing code — agent-written, human-decided, human-reviewed (third correction, rung 12).**
   The whole measurement path — the per-engine `classify()` brackets AND the `LatencyRecorder`
   aggregation — is **agent-written and human-reviewed**. The **biasable choices** — the percentile
   definition, the cold/warm boundary, and the warm-up policy, where a hidden choice would skew the
   benchmark — are **decided by the maintainer**, **documented in a comment at the code**, and **no
   agent may introduce or change a biasable choice without an explicit recorded ratification**. The
   per-engine brackets are reviewed at the diff for the boundary (the compute call ALONE in `infer`;
   all data-prep in `preprocess`; `inferEnd` immediately after the call, before reading output; the
   load-time warm-up excluded, in `loadModel`). At rung 12 the aggregation's three choices were
   ratified: (a) percentile = nearest-rank in integer arithmetic — floating `ceil` can land on the max
   and misreport p95; (b) cold = the first run after a load, its `total` carrying the load cost; (c) the
   recorder discards nothing — the cold run is reported in the cold bucket, not dropped. A comment may
   never label agent-written code "hand-written." This is the **third** recorded correction to this
   invariant: the original "no agent-authored timing code" became split trust at rung 15 (the biasable
   aggregation to stay hand-written), and rung 12 corrected that in turn — the maintainer decides and
   ratifies the biasable choices but does not hand-author the code, so the earlier "hand-written"
   framing was falsified. Recorded like the CI miss, the invariant-2 correction, and the RAII
   correction; see [ADR-0005](docs/adr/0005-litert-engine-concurrency.md).
2. **At most one `@unchecked Sendable`** in the whole codebase — at the LiteRT C-handle
   boundary, and only if a design requires it. It is a ceiling, not a target: under Swift
   6.3 the shipped on-actor `LiteRTEngine` requires **zero**. `TfLiteInterpreter*` is a
   non-Sendable, non-thread-safe C handle, but `OpaquePointer` is a trivial value and
   `Task.detached` takes a `sending` closure, so region-based isolation would let the handle
   cross a boundary with no box — a wrapper is a deliberate off-actor choice, not a compiler
   necessity. The design instead keeps every C call synchronous and on-actor (the actor
   serializes all access) and frees the handle in an `isolated deinit` (SE-0371). The type
   system does **not** enforce this — triviality defeats the region check — so the on-actor
   discipline is manual and documented at the Invoke site. Cleanup is RAII, not a `deinit`: an
   `isolated deinit` crashed on deferred teardown and a nonisolated actor `deinit` cannot even read the
   non-Sendable handles, so a private wrapper class frees them synchronously via ARC at refcount zero —
   a second empirical correction, recorded in ADR-0005, still zero `@unchecked`. A second `@unchecked Sendable`, or
   one away from that boundary, fails the CI lint (rung 16), which enforces **at most one**.
   Evidence, the fork, and the verbatim probe table:
   [ADR-0005](docs/adr/0005-litert-engine-concurrency.md). This premise was corrected by
   experiment, like the CI miss in the README — the earlier "exactly one, required to compile"
   was falsified by the probes in ADR-0005.
3. **The fallback chain is a value**, not an `if`-ladder. `LiteRT → Core ML → remote` is
   data; degradation is surfaced in the UI, never silent.
4. **UI states are an enum**, never booleans:
   `idle | loadingModel | inferring | success(degraded:) | failed(retryable:)`.
   Every case must have an **observable trigger** — a signal that actually exists in this
   codebase and can put the UI into it. A case no signal can produce is decoration, and
   decoration in a state machine is the same lie as an empty `make` target that exits 0.
   `success(degraded:)` carries the `[DegradationReason]` list, not a `Bool`, so what the
   screen shows and what the ledger row records are the same fact (invariant 3; the ledger
   stores `kind`/`from_backend`/`to_backend` as columns — `LedgerSchema`).
   **First recorded correction: `warming` is dropped, and `degraded:` is a reason list.**
   The contract requires warm-up to *complete inside* `loadModel()` — "must not return until
   the engine can infer at steady-state speed" (`InferenceEngine.loadModel`) — and both engines
   honour it in a private `warmUp` with no callback, no progress signal, and no second `await`.
   A driver therefore cannot distinguish loading from warming, so `warming` was a case nothing
   could enter. It returns only if an engine gains a load-progress signal, which is an
   engine-contract change, not a UI one. Thermal throttle and OOM keep their mapping onto
   `success(degraded:)` and `failed(retryable:)`, but neither has a *producer* yet
   (`.thermallyThrottled` is written at the thermal rung; `InferenceError.outOfMemory` is
   thrown from exactly one site, `CoreMLEngine`'s pixel-buffer allocation) — named here rather
   than implied. Recorded like the invariant-1, invariant-2 and RAII corrections; the
   equivalence argument in [ADR-0001](docs/adr/0001-module-boundaries.md) is corrected with it.
   **A second case was proposed and refused, at the cancel-on-input-change rung: `cancelled`.**
   It fails the test from the other side — it has a producer (the driver knows exactly when it
   cancels) and no **consumer**, because a cancelled run exists only when a new run is already
   starting, so the case would be overwritten by the superseding run's `.classifyBegan` in the same
   turn it was entered. A state nothing can ever draw is the `warming` mistake wearing a producer.
   Cancellation is therefore a **transition** and not a state — `(.inferring, .classifyBegan) ->
   .inferring`, the line already in the table — which is why this invariant is unchanged by that
   rung rather than corrected a second time. The reasoning is
   [ADR-0014](docs/adr/0014-cooperative-cancellation.md); this is a case the rule REJECTED, so it is
   recorded as evidence the rule bites, not as a correction to it.
5. **No CocoaPods — no second dependency manager of any kind. Dependency management is pure
   SPM.** LiteRT is a checksum-pinned `binaryTarget` (ADR-0002). Precised at rung 37 the
   recorded way (the "exactly one" → "at most one" precedent): the invariant's target was always
   dependency management, and the earlier wording "The build is pure SPM" read as forbidding any
   `.xcodeproj`, which over-restricted the principle — an app shell adds a run/install path, not
   a dependency decision. The committed minimal project at `App/Inferlens.xcodeproj` (ADR-0011)
   therefore fits inside the invariant: its dependencies still resolve through SPM against
   `Package.swift`. What still fails review: a second dependency manager in any form, an
   unpinned or checksum-less binary, and a package-resolution override inside the pbxproj (a
   pinned revision, a fork URL, a replaced package) — the pbxproj is an app-shell artifact with
   no say in dependencies. Recorded like the invariant-1/2/4 corrections; the fork and the
   refused alternatives are in [ADR-0011](docs/adr/0011-app-shell.md).
6. **No large binaries in git.** Models and the xcframework are checksum-pinned and
   fetched (`make bootstrap` / SPM), never committed. `*.mlmodel`, `*.mlpackage`,
   `*.tflite`, `*.xcframework` are git-ignored.
7. **Every number carries its device + iOS version.** No latency figure exists without
   the hardware and OS that produced it.
8. **`make bootstrap` precedes `swift build`.** The models are script-fetched; a plain
   `swift build` alone does not produce a working app.
9. **No AI attribution trailers in commit messages** — no `Co-Authored-By: …Claude`, no
   `Generated with …`, no 🤖. Enforced by `.githooks/commit-msg` (wired by `make
   bootstrap`) and the CI commit-hygiene lint (ADR-0004). Disclosure is a method
   (`docs/prompts/`, this file), not a per-commit disclaimer.

## Process

- Conventional Commits. One commit, one concern; a commit touching two concerns is split.
- Every commit is green: `make bootstrap` plus the simulator suite via `bash scripts/test-clean.sh`
  (a fresh `-derivedDataPath` per run; 205 tests counted, 204 run, 1 skipped on the pinned
  iPhone 17 Pro / iOS 26.1) pass. The skipped one is the screenshot renderer, which writes files
  only when asked — and a count is a fact about a tree and a simulator, so it is stated with both
  rather than as a bare number. (Under CI the three per-engine `…SteadyStateTiming` tests XCTSkip on
  shared hardware, so a CI run reports four skipped, not one — the timing gate is scoped to where it is
  sound; see the rung-31 finding in the roadmap.) `make lint` and `make test` are still stubs that
  echo a TODO and check nothing, so they are NOT the green bar — naming them would be the same "empty
  target readable as a pass" this repo guards against elsewhere. test-clean is run as the script, not as
  `make test`, because `make` collapses its 0/1/2 exit-code contract (findings/could-not-run) to a bare 2;
  wiring swiftformat/swiftlint into `make lint` and a contract-preserving `make test` is a ROADMAP
  Harness-backlog item. One recorded exception: a **spec-first RED commit** on a trust-critical path (invariant 1), marked RED in its
  message, whose green pair lands in the **same push** and is never pushed alone. The pair proves the
  spec preceded the implementation (rung 12: the RED half of the pair → the green aggregation) — it is evidence of
  order, not of authorship, and the red half is never pushed by itself.
- Benchmark honesty over polish: `LIMITATIONS.md` before any feature list; disclosed
  error bars, not badges.
- **Never commit** interview-prep notes, JD text, or recruiter correspondence.
  `NOTES.local.md` is git-ignored for scratch; keep it there.

## Anti-slop (treat as build failures in docs)

No emoji headers. A badge stays only if it is **verifiable and scoped** — a reader can click through to a file in the
repo and check exactly what it covers (that is the test, not how many badges there are). A per-workflow
badge qualifies: `commit-hygiene | passing` names its own scope and links to
[its workflow](.github/workflows/commit-hygiene.yml), so a reader sees precisely what it lints — as do
the version pins and the license. A generic `CI | passing` or a coverage badge does not: the label
implies build/test coverage the check does not measure, so it stays off the page until that coverage
actually runs (rung 31). This precises the principle, it does not loosen it — recorded like the
invariant-1/2 corrections: the earlier blanket "a CI-pass badge does not qualify" over-restricted
"verifiable and scoped," and a badge that names its own scope is exactly what the principle is for. Banned words: revolutionary, seamless,
blazing fast, cutting-edge, leverage, game-changing, robust, powerful, elegant, simply,
effortlessly. No sentence that survives deleting the project name. Every capability claim
links to the file that implements it. No "Features" list of nouns — show the state machine.
