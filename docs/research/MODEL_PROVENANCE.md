# Model provenance — which bytes, from where

This file answers one question: **which model bytes, from where.** It is distinct from
`BENCHMARK_METHOD.md` ("how the numbers were produced") and
`docs/adr/0003-benchmark-comparison-scope.md` ("why this comparison and not the other").

The benchmark compares two **vendor-shipped** MobileNetV2 models, each at its **native
default precision** — different weights *and* different precision, on purpose. See
ADR-0003 for why (a) two vendor models, and why precision is an ecosystem property here,
not a controlled variable.

## Artifacts

| Side | Artifact | Source | Precision (native) | ~Size | Checksum |
|------|----------|--------|--------------------|-------|----------|
| Core ML | `MobileNetV2FP16.mlmodel` | `https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2FP16.mlmodel` | FP16 (Apple's recommended baseline) | 12,393,551 B (~12.4 MB) | `sha256:c76832208ff4c936365f0f2609f7b77f7f1a6caf62b0b429056d5ad7e48635ad` |
| TFLite | `mobilenet_v2` float32 `.tflite` | Google-hosted (`download.tensorflow.org` / Kaggle Models) — exact URL verified on fetch | FP32 (Google's default float model) | ~11 MB | deferred to rung 15 (pinned when the LiteRT engine lands) |

*The Apple `.mlmodel` URL was HEAD-checked live and its sha256 computed 2026-07-18 (200 OK,
12,393,551 bytes, Core ML protobuf). `make bootstrap` re-verifies this sha256 on every fetch and
fails loudly on mismatch, so a silently-changed upstream breaks the build rather than slipping in.
The Google `.tflite` is deferred to rung 15, where the LiteRT path is built — pinning it now would
be speculative.*

## Notes

- **Different weights.** Apple's and Google's MobileNetV2 are trained independently: same
  *architecture*, not the same *artifact*. Cross-model top-1 agreement is a measured,
  published result (the cross-model agreement benchmark), never an equality assertion (ADR-0003).
- **Different native precision (Apple FP16 vs Google FP32), reported not controlled.**
  This is each ecosystem's default — what a reader actually deploys. The difference (and
  the fact that Core ML execution precision depends on the compute unit: the ANE runs
  FP16) is disclosed prominently in `BENCHMARK_METHOD.md`, alongside "different weights"
  and "delegate choice." It is not fake-controlled by forcing FP32/FP32 — see ADR-0003
  for why that would be worst of both (illusory control, unrepresentative).
- **Not committed.** Both files (~23 MB together) are large enough to be real clone bloat,
  so — consistent with how the `TensorFlowLiteC` xcframework is handled (ADR-0002) — they
  are pinned by checksum here and fetched at `make bootstrap`, not stored in git.
  Checksums guarantee identical bytes on every clone.
- **`make bootstrap` precedes `swift build`.** The models are fetched by script (the SPM
  `binaryTarget` mechanism is xcframework-only, so it cannot fetch a `.mlmodel`/`.tflite`).
  A plain `swift build` alone therefore does **not** yield a working app; `make bootstrap`
  must run first. CI runs bootstrap before test; the README states it in one
  line.
- **Common preprocessing:** ImageNet-1k labels, 224×224 input, on both sides. Any
  preprocessing divergence (mean/std, resize filter, color order) is itself a confound and
  is recorded in `BENCHMARK_METHOD.md`.

## Open input (approved deferral)

The exact Google `.tflite` download URL is verified when the LiteRT engine lands (rung 15). The
**precision (Google FP32 default) is decided now**; only that literal URL and its checksum are
pinned then. The Apple `.mlmodel` is already pinned (see the table); this is the single remaining
deferred literal in the model pipeline.
