# CLAUDE.md — architecture context and invariants

This file is the fixed context every change is reviewed against. It is deliberately
committed before any code (rung 00). If a change conflicts with an invariant here, the
change is wrong, not the invariant — raise it, do not silently work around it.

Decisions of record: [docs/adr/0001](docs/adr/0001-module-boundaries.md) (module
boundaries), [0002](docs/adr/0002-litert-distribution.md) (LiteRT distribution),
[0003](docs/adr/0003-benchmark-comparison-scope.md) (benchmark scope). Plan:
[docs/ROADMAP.md](docs/ROADMAP.md).

## The thesis

The product loop and the developer's evaluation loop are the **same loop**:
run inference → append to ledger → capture signal (thumbs) → export → offline eval →
choose next model/backend → run inference. Every decision must be defensible by pointing
at that sentence. A module that serves no clause of it is cut.

## Dependency direction (one way)

```
app  →  {InferlensUI, InferlensStore, InferlensFlags, InferlensCoreML, InferlensLiteRT}  →  InferlensCore
```

- `InferlensCore` depends on nothing. It is protocols + value types only.
- Engines (`CoreML`, `LiteRT`) depend on Core, never on each other.
- `InferlensUI` depends on Core's types and the engine *protocol*, never a concrete engine.
- The app target is thin: composition only.
- A CI dependency-lint fails any arrow pointing back toward an engine or into Core.

## Invariants (forbidden patterns)

1. **No agent-authored timing code.** `LatencyRecorder` and the measurement path are
   hand-written and hand-reviewed. Warm-up runs are discarded and the discard is
   documented. Never generate or auto-edit the timing path unreviewed.
2. **Exactly one `@unchecked Sendable`** in the whole codebase — the LiteRT C-handle
   boundary. `TfLiteInterpreter*` is non-Sendable and the C API is not thread-safe; it is
   owned by an actor that serializes all access, wrapped at exactly one documented
   boundary with a comment stating the invariant. Any other `@unchecked Sendable` fails
   CI lint (rung 12).
3. **The fallback chain is a value**, not an `if`-ladder. `LiteRT → Core ML → remote` is
   data; degradation is surfaced in the UI, never silent.
4. **UI states are an enum**, never booleans:
   `idle | loadingModel | warming | inferring | success(degraded:) | failed(retryable:)`.
   Cold start, model load, thermal throttle, and OOM each map to a named state.
5. **No CocoaPods.** The build is pure SPM. LiteRT is a checksum-pinned `binaryTarget`
   (ADR-0002).
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

- Conventional Commits. One rung, one concern; a rung touching two concerns is split.
- Every rung is green: `make bootstrap && make lint && make test` pass.
- Benchmark honesty over polish: `LIMITATIONS.md` before any feature list; disclosed
  error bars, not badges.
- **Never commit** interview-prep notes, JD text, or recruiter correspondence.
  `NOTES.local.md` is git-ignored for scratch; keep it there.

## Anti-slop (treat as build failures in docs)

No emoji headers. A badge stays only if a reader can check it against a file in the repo and see what it
covers: the version pins and the license qualify; a CI-pass or coverage badge does not,
and stays off the page until a real test run exists to link to (rung 27). What matters is
that each badge is verifiable and scoped — not how many there are. Banned words: revolutionary, seamless,
blazing fast, cutting-edge, leverage, game-changing, robust, powerful, elegant, simply,
effortlessly. No sentence that survives deleting the project name. Every capability claim
links to the file that implements it. No "Features" list of nouns — show the state machine.
