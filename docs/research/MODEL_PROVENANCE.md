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
| TFLite | `mobilenet_v2_1.0_224.tflite` | Extracted from Google's `download.tensorflow.org/models/tflite_11_05_08/mobilenet_v2_1.0_224.tgz` | FP32 (Google's default float model) | 13,978,596 B (~14 MB) | `sha256:9f3bc29e38e90842a852bfed957dbf5e36f2d97a91dd17736b1e5c0aca8d3303` |

*The Apple `.mlmodel` URL was HEAD-checked live and its sha256 computed 2026-07-18 (200 OK,
12,393,551 bytes, Core ML protobuf). The Google `.tflite` was pinned 2026-07-19: Google ships it
only inside a ~75 MB training-dump archive, `.../tflite_11_05_08/mobilenet_v2_1.0_224.tgz` (sha256
`a9fce7e2db6389dfa1e640a9c98a6f29a55e482e463c5f01c377a19806f66ee2`, 78,310,785 bytes), so `make
bootstrap` verifies the archive's sha256, extracts the single `.tflite` member, and verifies the
member's sha256 too. Either mismatch fails the build loudly, so a silently-changed upstream breaks
it rather than slipping in.*

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
- **Not committed.** The two extracted models (~26 MB together — Apple 12.4 MB + Google 14 MB)
  are real clone bloat, so — consistent with how the `TensorFlowLiteC` xcframework is handled
  (ADR-0002) — they are pinned by checksum here and fetched at `make bootstrap`, not stored in
  git. The 78 MB Google archive is downloaded, verified, and discarded once the `.tflite` is
  extracted. Checksums guarantee identical bytes on every clone.
- **`make bootstrap` precedes `swift build`.** The models are fetched by script (the SPM
  `binaryTarget` mechanism is xcframework-only, so it cannot fetch a `.mlmodel`/`.tflite`).
  A plain `swift build` alone therefore does **not** yield a working app; `make bootstrap`
  must run first. CI runs bootstrap before test; the README states it in one
  line.
- **Common preprocessing:** ImageNet-1k labels, 224×224 input, on both sides. Any
  preprocessing divergence (mean/std, resize filter, color order) is itself a confound and
  is recorded in `BENCHMARK_METHOD.md`.
- **Google `.tflite` I/O contract (read at load, not assumed).** Input `input`: FLOAT32
  `[1, 224, 224, 3]`, RGB, normalized to `[-1, 1]` (`v/127.5 - 1`) — the caller normalizes; it is
  not baked in. Output `MobilenetV2/Predictions/Reshape_1`: FLOAT32 `[1, 1001]`, post-softmax (so
  each value is in `0…1`), where index 0 is a "background" class and 1…1000 are ImageNet-1k. The
  raw `.tflite` carries no embedded label strings, so `LiteRTEngine` labels classes by index while
  the Apple side carries real label strings — a divergence for rung 17's cross-model agreement to
  reconcile, recorded here as provenance.

## Resolved input (pinned at rung 15)

The Google `.tflite` was the single remaining deferred literal in the model pipeline. It is now
pinned (table + note above): the source is the canonical `download.tensorflow.org` float
MobileNetV2 dump, and both the archive and the extracted member are checksum-verified by `make
bootstrap`. The precision (Google FP32 default) was decided earlier (ADR-0003); rung 15 fixed only
the literal URL and the two checksums, by fetching the bytes and computing their sha256.
