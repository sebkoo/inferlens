// InferlensUI — the SwiftUI layer, expressing CLAUDE.md invariant 4's state machine.
//
// No engine knowledge: this module depends on `InferlensCore`'s value types and, where it needs
// one, the engine PROTOCOL — never a concrete engine. `Package.swift` is where that is enforced;
// `InferlensUI` lists exactly one dependency, so an `import InferlensCoreML` here would not
// compile.
//
// What is here:
//   InferenceState.swift          — the state enum, the events that produce it, the transition table
//   InferenceStateView.swift      — the views over it, plus the degradation banner (invariant 3)
//   ClassificationModel.swift     — the driver: photo in, state + result + latency sample out
//   ClassificationScreen.swift    — the screen: pick a photo, classify, show the result
//   ClassificationResultView.swift— top-3 with confidence, the backend, and the latency readout
//   LatencyReadout.swift          — a summary plus the machine that produced it (invariant 7)
//   ImageDecoding.swift           — a picked photo as the contract's raw `ImageBuffer` bytes
//
// The one boundary worth knowing before editing: this module can NAME a `LatencySummary` (it is a
// Core value type) and can never COMPUTE one — the recorder lives in InferlensBench, which is not a
// dependency, so a summarizing function is injected instead. That is ADR-0008, and it is what keeps
// exactly one definition of p50/p95 in the repo.
//
// Still to come: the thumbs signal, and the composition in the app target.
