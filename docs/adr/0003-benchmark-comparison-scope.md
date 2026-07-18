# ADR-0003: Benchmark comparison scope — ecosystem, not controlled-conversion

- Status: Accepted — 2026-07-17
- Deciders: maintainer
- Scope: the benchmark models and the README headline.

This ADR exists for the alternative it **rejects**. `MODEL_PROVENANCE.md` answers "which
bytes, from where"; `BENCHMARK_METHOD.md` answers "how the numbers were produced"; this
ADR answers "why this comparison and not the other" — the question an interviewer will
actually ask.

## Context

"Core ML vs TensorFlow Lite on iOS: which is actually faster?" can be answered two ways,
and the choice determines the model pipeline, the toolchain, and whether the headline is
honest.

## The rejected alternative (the point of this ADR)

**(b) One source model, converted to both runtimes** — a single MobileNetV2 source
converted to `.mlpackage` via coremltools and to `.tflite` via the TFLite converter, at
one precision, so the table isolates the runtime. Rejected, for reasons that compound:

- **JD-relevance.** Model conversion is ML engineering, not iOS engineering. The
  converting models would be the single least-JD-relevant work in the ladder, while the JD
  tests Swift / SPM / concurrency / on-device work.
- **Budget and risk.** It carries the largest toolchain in the project (Python +
  TensorFlow + coremltools 9.0) and the only conversion-fidelity risk — op-support and
  default-quantization divergence between two independent converters.
- **The control is partly illusory.** Even from one source, per-runtime kernels, delegate
  choice, and quantization defaults differ. (b) buys one degree less mess, not true
  isolation — so it pays the full toolchain cost for a partial gain.
- **Thesis.** The repo's wedge against MLPerf Mobile is the closed eval loop (ledger +
  signal + export) and the visible fallback chain — not microbenchmark purity. Spending
  the scarce weekend budget on conversion serves the weakest part of the pitch.

## Decision (the chosen alternative)

**(a) Two vendor-shipped MobileNetV2 models** — Apple's Core ML model and Google's TFLite
model — compared as an **ecosystem comparison**: *what each ecosystem's shipped
MobileNetV2 costs you on this phone.* This is more representative (the reader ships the
vendor model, not a self-converted one) and keeps the budget on the iOS surface the JD
tests. **coremltools is therefore excluded from the toolchain entirely — decided out, not
deferred.**

## Precision is part of the comparison, not a confound to control

Each side runs at its **native, default precision**: Apple's recommended **FP16**
`MobileNetV2FP16.mlmodel` and Google's **FP32** `mobilenet_v2` `.tflite`. The precision
difference is not eliminated; it is **reported as an ecosystem property** in
`BENCHMARK_METHOD.md`, prominently, alongside "different weights" and "delegate choice."

### Why not match precision (a reversal, recorded on purpose)

An earlier draft matched at FP32/FP32 to "control the only controllable variable." That
was a (b) instinct smuggled into an (a) design, and it was wrong on two counts:

- **Under (a), precision is part of what is being compared.** Each ecosystem's default
  precision *is* the ecosystem, and it is what a reader actually deploys. FP16 is Apple's
  recommended baseline; FP32 is Google's default hosted float model. Forcing them equal
  measures a configuration nobody ships.
- **FP32/FP32's control is illusory — and it sets the mirror image of the INT8 trap.**
  The Neural Engine executes in FP16. An FP32 `.mlmodel` therefore either gets downcast to
  FP16 (storage matched, *execution* not matched) or falls off the ANE onto GPU/CPU —
  which **handicaps Core ML off its fast path**, so the table would report "TFLite is
  faster" for a reason we introduced. FP32/FP32 is thus neither controlled (weights still
  differ, execution precision unknown) nor representative (nobody ships FP32 Core ML to an
  iPhone): worst of both.

INT8 is likewise refused as a forced match — the two vendors' quantization *schemes*
differ (Apple LUT palettization vs TFLite affine full-integer). Native precision on each
side is the honest (a) design: **name the difference, do not fake-control it.**

**Disclosed in BENCHMARK_METHOD.md, prominently:** the two sides differ in weights *and*
in precision (Apple FP16 vs Google FP32), and Core ML execution precision depends on the
chosen compute unit (the ANE runs FP16). The result is an ecosystem comparison, not a
controlled runtime isolation; the README headline is scoped accordingly.

## Consequence for cross-model agreement

The two models have **different weights** (independently trained). Disagreement on a
golden image is therefore **data, not a bug**. The cross-model agreement benchmark
*measures* top-1 agreement over a
golden set **frozen before measurement** — never curated until it agrees, because that
gate would protect nothing — and **publishes** the rate (e.g. "Apple and Google
MobileNetV2 agree on top-1 for N/50 golden images"). Any gate is a loose sanity floor to
catch a broken preprocessing pipeline; the actual number is always published, in the
README and BENCHMARK_METHOD.md.
