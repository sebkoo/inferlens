# ADR-0005: LiteRTEngine concurrency — where the unsafe boundary is (and why there is none)

- Status: Accepted — 2026-07-19
- Deciders: maintainer
- Corrects the premise of CLAUDE.md invariant 2 ("**exactly** one `@unchecked Sendable`,
  required to compile under strict concurrency") to "**at most** one," by the probes below.
  Recorded as a methodology self-correction, like the CI-miss in the README.

## Context

Invariant 2 reserved the repo's single `@unchecked Sendable` for the LiteRT C-handle
boundary, on the stated premise that a non-Sendable `TfLiteInterpreter*` owned by an actor
*requires* one `@unchecked Sendable` to compile under `-strict-concurrency=complete`. Before
writing `LiteRTEngine`, that premise was tested rather than assumed. It is false at Swift 6.3.

## The two designs

- **On-actor Invoke.** Every C call — `TfLiteInterpreterGetInputTensor`,
  `TfLiteTensorCopyFromBuffer`, `TfLiteInterpreterInvoke`, `TfLiteTensorCopyToBuffer` — runs
  synchronously inside the actor, with no suspension between reading the handle and `Invoke`
  returning. The handle never crosses an isolation boundary during use. This matches invariant 2's own
  words verbatim: "owned by an actor that serializes all access." (Cleanup is a separate story that the
  compile probes got wrong at runtime — see "Cleanup" below.)
- **Off-actor Invoke.** The blocking `Invoke` runs on a `Task.detached`, so the actor's
  executor stays free during the ~10–30 ms inference.

## The probes (typecheck only, `-swift-version 6 -strict-concurrency=complete`, Swift 6.3.3)

`OpaquePointer` is explicitly non-Sendable — the one hard fact both designs start from:

```
error: conformance of 'OpaquePointer' to 'Sendable' is unavailable
note:  conformance of 'OpaquePointer' to 'Sendable' has been explicitly marked unavailable here
```

Yet neither design is forced to introduce a box. `Task.detached`'s real signature in this
toolchain is:

```
operation: sending @escaping @isolated(any) () async -> Success
```

It takes a **`sending`** closure, not a plain `@Sendable` one, so region-based isolation
(SE-0414) *transfers* the capture into the task; because `OpaquePointer` is a trivial value the
compiler treats each copy as an independent region and lets it cross with no `Sendable`
requirement.

| Probe | Design | Result |
|---|---|---|
| T1 | `OpaquePointer` where `Sendable` is required | FAILS (unavailable) — the only hard fact |
| T4 | actor stores handle; **nonisolated** `deinit` calls `…Delete` | COMPILES on host `swiftc` — but the package/iOS build REJECTS it (see Cleanup) |
| T5 / T5b | **`isolated deinit`** (SE-0371) calls `…Delete` | COMPILES, 0 diag — but crashes at RUNTIME (see Cleanup) |
| T6a / T6e / T6ff | off-actor Invoke, handle in an `@unchecked Sendable` box | COMPILES — box *sufficient* |
| T6b / T6c / T6d / T6f | off-actor Invoke, **no box** (bare ptr and class handle) | COMPILES, 0 diag — box *not necessary* |
| T6g | bare ptr, fire-and-forget, reused after | COMPILES, 0 diag |
| CONTROL-BAD-1 | non-Sendable in an *explicitly* `@Sendable` closure | FAILS (`#SendableClosureCaptures`) |

CONTROL-BAD-1 is the calibration: the harness *does* catch a real Sendable violation, so the
COMPILES rows are trustworthy negatives — they are silence, not a mis-run. The only way found
to force a box was an explicitly-typed `@Sendable` stored closure, a construct the engine has
no reason to use.

## Decision

Ship the **on-actor** design with **zero** `@unchecked Sendable`. Amend invariant 2 to "at most
one, at the C-handle boundary, only if a design requires it." Rewrite the rung-16 lint as "at
most one."

## Rationale

- **Honesty.** Zero `@unchecked Sendable` is what the compiler actually produces; padding one in
  to satisfy a literal "exactly one" would be a wrapper that exists only to justify itself — the
  opposite of CLAUDE.md's "prefer deleting an abstraction over adding one."
- **True serialization, and off-actor is the *unsafe* option here.** On-actor, the actor
  genuinely serializes every access. Off-actor is a hazard precisely because pointer-triviality
  defeats the region check: the compiler will silently let actor **reentrancy** across the
  `await` start a second `Invoke` on the same non-thread-safe interpreter — a C-level data race
  it cannot see. On-actor holds the actor for the whole synchronous call, so there is no
  reentrancy gap.
- **Clean latency measurement (invariants 1 & 7).** The measured span is `Invoke` alone.
  Off-actor wraps it in `Task.detached` scheduling, injecting executor-hop jitter into the very
  number the benchmark exists to report. On-actor brackets the blocking call directly.
- **The boundary is real but unenforced.** The type system does **not** protect it: an
  `OpaquePointer` is trivial, so the region check would wave an off-actor send through. The
  safety is therefore a **manual, documented discipline** — a load-bearing comment at the
  `Invoke` site stating the handle is touched only synchronously on-actor with no suspension.
  This ADR records that the guarantee is human-maintained, not compiler-checked.

## Consequences

- No `@unchecked Sendable` exists in the repo after rung 15. The rung-16 lint enforces "at most
  one" (a ceiling), not "exactly one" (a quota that would force a gratuitous box).
- If a future rung needs off-actor inference (e.g. to free the executor under heavy concurrent
  load), it may introduce the single `@unchecked Sendable` box at that boundary — deliberately,
  with its own justification, and with explicit serialization to close the reentrancy race — and
  the lint still passes.

## Cleanup — a second empirical correction (isolated deinit → RAII)

The compile probes (T5/T5b) said `isolated deinit` was fine. Runtime said otherwise. Freeing the C
handles in an `isolated deinit` shipped, then `InferlensLiteRTTests` crashed:

```
xctest malloc: *** error for object 0x…: pointer being freed was not allocated
Failing tests: LiteRTEngineConformanceTests.testDescriptorReadableWithoutLoading()
```

The crashing test makes no C calls of its own: `isolated deinit` defers the free onto the actor's
executor, and that asynchronous teardown raced the test bundle's process shutdown. Two facts then boxed
the fix in:

- `isolated deinit` is out — the deferred free *is* the bug.
- A nonisolated actor `deinit` cannot even READ a non-Sendable stored property. The package build
  rejects `deinit { …(interpreter) }` for `interpreter: OpaquePointer?` with "cannot access property …
  with a non-Sendable type … from nonisolated deinit." (A host-only `swiftc` probe had wrongly suggested
  otherwise — the package build under the iOS SDK is the authority, not a host typecheck.)

So cleanup uses **RAII**: a private `final class Handles` owns the two handles and frees them in its own
plain, synchronous `deinit`. A non-actor class `deinit` may read its own non-Sendable stored properties
freely; the actor merely holds the `Handles`, and ARC runs that `deinit` when the actor is deallocated —
deterministic, synchronous, and race-free (refcount zero, so nothing can hold the actor). This keeps
**zero `@unchecked Sendable` and zero unsafe annotations**. (`nonisolated(unsafe)` on the stored handles,
or a single `@unchecked Sendable` box — which invariant 2 now permits — both compile too; RAII was
chosen because it keeps the unsafe-annotation count at zero.)

**Lesson — the compile authority is the package/iOS build, not host `swiftc`.** Probe T4 (a host
typecheck) said a nonisolated actor `deinit` reading the handles was fine; the package build under the
iOS SDK rejected it outright. Host-only probes are a fast first look, never the final word — deinit
isolation and concurrency rules must be confirmed in the actual `xcodebuild` build before they are
trusted. This ADR's earlier probe table (T4/T5) was written from host typechecks; both rows are now
annotated with what the package build actually did.

Verified before shipping:

- `-run-tests-until-failure -test-iterations 5`: 5/5 green, the original crashing order preserved
  (`testDescriptorReadableWithoutLoading` runs right after the model-loading tests), zero `malloc`/crash
  lines.
- `-enableAddressSanitizer YES`: TEST SUCCEEDED, no ASan report — no double-free, no use-after-free. So
  the fix is memory-clean, not merely reordered.
- A forced load failure on garbage bytes (`testLoadFailsCleanlyOnBadModelBytes`) passes under ASan: the
  `loadModel` error paths free what they created without ever storing it, so a later `deinit` (handles
  `nil`) frees nothing — the single-free property, proven not just argued.

## Timing authorship — a third correction (invariant 1: split trust)

Adjacent to this ADR's two concurrency corrections, rung 15 surfaced a third. The engine's
`classify()` measurement brackets — the `ContinuousClock` reads bracketing preprocess and `Invoke` — were **agent-written
this session**, but the original invariant 1 forbade agent-authored timing code, and the engine comment
falsely labelled them "hand-written." Rather than ship a false label (or pretend a human wrote them),
the maintainer **relaxed invariant 1 to split trust**: the biasable aggregation (percentiles, cold/warm,
warm-up-run discard — the `LatencyRecorder`, rung 12) was to stay hand-written (interim — **superseded at
rung 12**; see "Timing authorship, settled at rung 12" below); the mechanical per-run brackets
are **agent-written, human-reviewed** — the maintainer reviews the compute-call-alone boundary before it
lands. Both engines' bracket comments now say exactly that; neither claims human authorship the agent did.
`CoreMLEngine`'s rung-10 brackets carried the same false "hand-written" label; git blame shows only the
committer (the maintainer), not the keystroke author, and human authorship was not confirmed, so they are
relabelled "agent-written, human-reviewed" too. See CLAUDE.md invariant 1.

## Timing authorship, settled at rung 12 — the aggregation is agent-written too

The rung-15 split trust above believed one more thing that rung 12 falsified.

- **Believed (rung 15).** The biasable aggregation — the `LatencyRecorder`'s percentiles, the cold/warm
  split, the warm-up policy — would **stay hand-written** by the maintainer, because a hidden choice there
  would skew the benchmark and only a human hand should make it.
- **Falsified (rung 12).** When the aggregation was built, the maintainer **decided and ratified** the
  biasable choices but did **not** hand-author the code — the agent wrote it to those decisions and the
  maintainer reviewed it. Calling it "hand-written" would have been the same false label this ADR already
  corrected for the brackets. The red→green pair (the RED half → the green aggregation) proves the spec
  preceded the implementation — **order, not authorship**.
- **Resulting rule (invariant 1, settled).** The whole measurement path — brackets AND aggregation — is
  **agent-written, human-decided, human-reviewed**. The biasable choices are **decided by the maintainer,
  documented in a comment at the code**, and **no agent may introduce or change one without an explicit
  recorded ratification**.
- **The three choices ratified at rung 12** (documented at the code in `LatencyRecorder.swift`):
  (a) percentile = **nearest-rank in integer arithmetic** — `rank = ceil(p*N/100)` written `(p*N+99)/100`,
  1-indexed, clamped `1...N`; integer on purpose, because binary-float `ceil(0.95*20.0)` can land on 20.0
  and misreport p95 == max (the bug `testP95IsNearestRankNotMax` guards);
  (b) **cold = the first run after a model load**, its `total` carrying the load cost (loadDuration +
  compute); every later run is warm;
  (c) **the recorder discards nothing** — the engine's one throwaway `Invoke` in `loadModel` is the only
  warm-up; the cold run is **reported in the cold bucket, not dropped**, because cold start is a real,
  user-visible cost and dropping slow early samples would flatter the benchmark.

## Alternatives rejected

- **Off-actor Invoke + one `@unchecked Sendable` box.** Keeps invariant 2 literally true and
  demonstrates "exactly where the unsafe edge is," but the box is decorative (the compiler does
  not require it), it re-introduces the reentrancy race above, and it dirties the measured
  latency span. Rejected for this rung; available later if a real need appears.
- **Keep "exactly one" and pad a box in.** Rejected: it fabricates a necessity the probes
  falsified, and CLAUDE.md forbids working around an invariant silently. Raised with the
  maintainer; the invariant was amended instead.
