# Prior art and positioning

## Name

Inferlens. US exact-wordmark knockout, human-verified in a rendered browser on
2026-07-17 (tmsearch.uspto.gov; Wordmark search; status filters Live[Registered,
Pending] + Dead[Cancelled, Abandoned] all enabled):

| Wordmark  | Live | Dead | Note              |
|-----------|------|------|-------------------|
| Inferlens | 0    | 0    | chosen            |
| Latenzo   | 0    | 0    | backup, unused    |
| Millilab  | 0    | 0    | backup, unused    |

Scope: exact-wordmark knockout only. Does **not** clear confusingly-similar marks.

## Confusion risk — LOW, closed

"Inferlens" is phonetically and visually distinct from Snap's "LENS" / "LENS STUDIO"
and Google "Lens"; goods/services differ (a developer benchmarking tool vs an AR
consumer camera); "-lens" is generic in imaging. This is proportionate diligence for
an OSS repo with no install base. Revisit with counsel only before a commercial App
Store release with revenue.

## Prior art

- **MLPerf Mobile** — github.com/mlcommons/mobile_app_open. Genuinely adjacent:
  standardized on-device inference benchmarking across backends. This is the nearest
  neighbour. The wedge to verify at README time: MLPerf produces standardized
  *scores*; it does not close an eval loop (per-run ledger + captured user signal +
  export to offline eval) and does not ship a visible runtime fallback chain. Position
  Inferlens on the closed loop and the fallback state machine, not on measurement.
- **john-rocky/apple-silicon-llm-bench** — LLM on Apple Silicon. Off-target: this is
  the LLM slot, not the vision/TFLite slot.
- **rockyshikoku.medium.com**, "Local LLM on iPhone: which runtime is actually
  fastest" — LLM; does not occupy the vision/TFLite slot. Its existence is *evidence
  for* the README's SEO thesis (people do search "which runtime is fastest"), not
  evidence against the wedge.

## LiteRT / TensorFlow Lite iOS distribution (Task 0 — resolved 2026-07-17)

**Question:** Is there a first-party Swift Package Manager package for LiteRT / TFLite
on iOS today, or is CocoaPods still the only official route with community XCFramework
wrappers filling the SPM gap?

**Answer:** No first-party SPM package for the general (vision) LiteRT / TensorFlow
Lite runtime. CocoaPods is the only official route; community XCFramework wrappers fill
the SPM gap.

Primary source (fetched, canonical): `ai.google.dev/edge/litert/ios/quickstart`
301-redirects to `developers.google.com/edge/litert/ios/quickstart`. That page
documents **CocoaPods only** — `pod 'TensorFlowLiteSwift'` (Swift),
`pod 'TensorFlowLiteObjC'` (Objective-C), with subspecs `['CoreML', 'Metal']` — plus a
**Bazel / source** build. No SPM is mentioned. Because this doc is primary for the
claim "how is LiteRT distributed," the conclusion is **documentation, not inference**;
the fallback path in the task ("if the canonical URL is unreachable, mark inferred")
does not apply.

- **Issue google-ai-edge/LiteRT#125** ("Make TensorFlow Lite available as a Swift
  Package Manager package") is **Closed**. The closing comment was not readable in the
  fetch, so no claim is made about *why* it closed — and it is not load-bearing,
  because the quickstart is primary and shows no SPM shipped. An older twin exists
  upstream: `tensorflow/tensorflow#44609`, same title.
- **Pod liveness:** `TensorFlowLiteSwift` stable latest = **2.17.0** (the TF 2.17
  line); nightlies ended in 2025. Read in mid-2026, the pod is **frozen** — no live
  release stream — and was **not** renamed to a "LiteRT" pod (Google's own iOS
  quickstart still says `pod 'TensorFlowLiteSwift'`). The decision is therefore not
  "pod vs binaryTarget" but between two frozen artifacts, only one of which is SPM;
  see ADR-0002. The `TensorFlowLiteC` bytes themselves are Google's, hosted at a stable
  `dl.google.com/tflite-release/...` URL that the CocoaPod merely points at.

**Trap avoided (the flattering result).** Web search surfaced "LiteRT moved to SPM."
That is **LiteRT-LM** — the *LLM* inference framework (`ai.google.dev/edge/litert-lm/
swift`, `google-ai-edge/LiteRT-LM`), which does ship a first-party Swift/SPM API. Per
the ground-truth facts, the LLM slot is off-target; Inferlens occupies the vision/TFLite
slot. Conflating the two would have manufactured a must-have that does not exist for
this project. The flattering "the must-have is already easy" sentence was distrusted
exactly as hard as a painful one would have been.

The resulting distribution decision is recorded in
[docs/adr/0002-litert-distribution.md](../adr/0002-litert-distribution.md).
