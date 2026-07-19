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
  returning. The handle never crosses an isolation boundary during use. Cleanup runs in an
  `isolated deinit` (SE-0371). This matches invariant 2's own words verbatim: "owned by an
  actor that serializes all access."
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
| T4 | actor stores handle; **nonisolated** `deinit` calls `…Delete` | COMPILES, 0 diag |
| T5 / T5b | **`isolated deinit`** (SE-0371) calls `…Delete` | COMPILES, 0 diag |
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

## Alternatives rejected

- **Off-actor Invoke + one `@unchecked Sendable` box.** Keeps invariant 2 literally true and
  demonstrates "exactly where the unsafe edge is," but the box is decorative (the compiler does
  not require it), it re-introduces the reentrancy race above, and it dirties the measured
  latency span. Rejected for this rung; available later if a real need appears.
- **Keep "exactly one" and pad a box in.** Rejected: it fabricates a necessity the probes
  falsified, and CLAUDE.md forbids working around an invariant silently. Raised with the
  maintainer; the invariant was amended instead.
