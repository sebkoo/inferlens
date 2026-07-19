# Prompt — rung 15: the LiteRTEngine

This is the first committed entry in `docs/prompts/`. From rung 15 forward the driving prompt is a
repo artifact, not a session handoff. Earlier rungs (00–14) are **not** backfilled: a reconstructed
prompt would not be the one that ran, and inventing it would be the fabrication this repo bans.

What a prompt file records: the instruction that drove the rung, verbatim, plus honest **execution
notes** on where reality pushed back (the prompt is the plan; the commits are what happened).

---

## The driving prompt (as received)

> Read the on-disk record FIRST: `git log`, CLAUDE.md (INVARIANT 2 verbatim — the one `@unchecked
> Sendable` is this rung's LiteRT C-handle boundary; also invariant 1: no agent-authored timing),
> ADR-0001, ADR-0002 (the vendored TensorFlowLiteC), MODEL_PROVENANCE (the FP32 `.tflite` model),
> `InferenceEngine.swift` (the contract), `CoreMLEngine.swift` (the REFERENCE — mirror its shape,
> honestly), `InferlensConformance/` (`assertConformsToContract` — you run this), `InferlensLiteRT/`.
> Verify the TFLite C API from the framework's own headers (`c_api.h` etc.), not memory.
>
> **Step 0 — pin the FP32 `.tflite` model.** Per MODEL_PROVENANCE, pin Google's FP32 MobileNetV2
> `.tflite`: source URL + sha256, fetched by `make bootstrap` into `Vendor/Models/` (git-ignored),
> checksum-verified (refuse on mismatch). Confirm the exact model + URL; do not invent one.
>
> **Step 1 — the LiteRTEngine, and the repo's ONE `@unchecked Sendable`.** An `actor LiteRTEngine`
> conforming to `InferenceEngine`. Mirror CoreMLEngine's shape: descriptor is `nonisolated let`;
> loadModel compiles/loads + warms; classify builds an honest `InferenceOutcome`. Drive the TFLite C
> API directly (create interpreter, allocate tensors, copy the preprocessed input, `Invoke`, read the
> output → classifications sorted desc, confidence 0...1, backend `.liteRT`). preprocess and infer
> timed SEPARATELY (hand-written, invariant 1). THE `@unchecked Sendable` — invariant 2, the whole
> reason it was reserved: `TfLiteInterpreter*` is a non-Sendable C pointer and the C API is NOT
> thread-safe; wrap it at EXACTLY ONE documented boundary. Typed errors: map TFLite C failures to
> `InferenceError`.
>
> **Step 2 — RUN the suite against it.** `try await assertConformsToContract(LiteRTEngine(...))` on the
> sim. If the suite fails, that is the finding — `ultrathink`, do not bend the engine to pass.
>
> **Step 3 — advance the PROMPT pillar.** Commit THIS prompt as `docs/prompts/rung-15-litert-engine.md`
> (the first real entry). Update the README scorecard's "Prompt engineering" line: committed from rung
> 15 forward; earlier rungs' prompts are not reconstructed. Do NOT backfill 00–14.
>
> **Build green, land, push-gate bundle.** `make land RUNG=15` (badge → 12/37, NO push). Bring the
> evidence a–h, then STOP before push.
>
> Standing rules: verify before asserting (C API from the headers); match the gate to reversibility
> (edits at the diff; commit + push gated on evidence); prefer deleting an abstraction over adding one.

## Execution notes — where reality pushed back

Two things in the prompt were **falsified by experiment** and became self-corrections (the method
working as intended: the prompt is a hypothesis, the build is the test).

1. **"The one `@unchecked Sendable`" → zero.** The prompt assumed the C handle *requires* one
   `@unchecked Sendable` to compile. Typecheck probes under `-strict-concurrency=complete` showed it
   does not: `OpaquePointer` is trivial and `Task.detached` takes a `sending` closure, so region-based
   isolation lets the handle cross with no box, and an on-actor design serializes every C call. The
   engine ships **zero** `@unchecked Sendable`. Invariant 2 was amended "exactly one" → "at most one,"
   and the fork/probe evidence recorded in [ADR-0005](../adr/0005-litert-engine-concurrency.md). Raised
   with the maintainer before changing the invariant; on-actor chosen over off-actor.

2. **Cleanup: `isolated deinit` → RAII.** An `isolated deinit` (SE-0371) compiled but **crashed at
   runtime** — it defers the free onto the actor executor, which raced test-bundle teardown
   (`malloc: pointer being freed was not allocated`). A nonisolated actor `deinit` cannot even read the
   non-Sendable handles in the package build. So cleanup is RAII: a private class frees the handles in
   its own class `deinit` at actor dealloc. Verified with 5× `-run-tests-until-failure`, an
   AddressSanitizer pass, and a forced-load-failure single-free test. Recorded in ADR-0005, including
   the lesson that the compile authority is the package/iOS build, not host `swiftc`.

The model (Step 0) is Google's `mobilenet_v2_1.0_224.tflite`, extracted and checksum-verified from the
canonical `download.tensorflow.org` archive (both shas pinned in
[MODEL_PROVENANCE.md](../research/MODEL_PROVENANCE.md)); a corrupt pin is refused.
