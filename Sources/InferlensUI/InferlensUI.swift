// InferlensUI — the SwiftUI layer, expressing CLAUDE.md invariant 4's state machine.
//
// No engine knowledge: this module depends on `InferlensCore`'s value types and, where it needs
// one, the engine PROTOCOL — never a concrete engine. `Package.swift` is where that is enforced;
// `InferlensUI` lists exactly one dependency, so an `import InferlensCoreML` here would not
// compile.
//
// What is here:
//   InferenceState.swift     — the state enum, the events that produce it, the transition table
//   InferenceStateView.swift — the views over it, plus the degradation banner (invariant 3)
//
// Still to come: the screen that picks an image, drives an engine through this machine, and shows
// the result; the thumbs signal; the composition in the app target.
