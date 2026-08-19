# Prompt — the LiteRT engine

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

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

## What turned out wrong

The C handle needed no `@unchecked Sendable` at all. Typecheck probes under
`-strict-concurrency=complete` showed `OpaquePointer` is trivial and an on-actor design serializes
every C call, so the engine ships zero. An `isolated deinit` compiled and then crashed at test-bundle
teardown, so cleanup became RAII: a private class frees the handles in its own `deinit`
([ADR-0005](../adr/0005-litert-engine-concurrency.md)).
