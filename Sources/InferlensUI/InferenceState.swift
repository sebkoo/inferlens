// The UI state machine — CLAUDE.md invariant 4, as a value.
//
// No engine knowledge. This file imports `InferlensCore` and nothing else: not `InferlensCoreML`,
// not `InferlensLiteRT`, not `InferlensStore`. It never names a concrete engine and never calls
// one — a driver calls the engine and reports what happened as an `InferenceEvent`. That is what
// makes the machine testable without a model file, a simulator, or a `TfLiteInterpreter*`: the
// whole transition table is a pure function over two enums.
//
// The rule the invariant imposes, and the reason this file is short: **every case must have an
// observable trigger.** Not a name someone thought the screen might need — a signal that exists in
// this codebase and can actually put the UI into that state. Building the machine cost the
// invariant its `warming` case, which had been written down since the bootstrap commit and turned
// out to be unreachable: the engine contract requires warm-up to complete INSIDE `loadModel()`
// (`InferenceEngine.loadModel`: "must not return until the engine can infer at steady-state
// speed"), and both engines honour it in a private `warmUp` with no callback and no second
// `await`. A driver cannot see it, so nothing could enter the state. Dropped rather than drawn —
// CLAUDE.md invariant 4, first correction.

import InferlensCore

// MARK: - State

/// What the screen is showing. An enum, never a set of booleans (invariant 4): two booleans admit
/// four combinations, of which `isLoading && isFailed` is a state the run was never in, and no
/// amount of care at the call sites removes it from the type. Here the impossible states cannot be
/// spelled.
///
/// Five cases, each with the signal that produces it:
///
/// | State | Produced by |
/// |---|---|
/// | `idle` | the initial value, and `.reset` from anywhere |
/// | `loadingModel` | `.modelLoadBegan` — the driver entered `await engine.loadModel()` |
/// | `inferring` | `.classifyBegan` — the driver entered `await engine.classify(_:)` |
/// | `success(degraded:)` | `.classifySucceeded` — `classify` returned an `InferenceOutcome` |
/// | `failed(retryable:)` | `.failed` — `loadModel` or `classify` threw an `InferenceError` |
///
/// Nothing here is aspirational: every one of those five events is emitted by a driver doing what
/// the engine protocol already allows. A sixth case whose event no driver could emit is what the
/// first correction removed.
public enum InferenceState: Sendable, Equatable {
    /// Nothing has been asked for yet — no image chosen, or the screen was reset after a run.
    case idle

    /// `loadModel()` is in flight. This is the whole cold-start cost: model compilation, ANE
    /// preparation, and the engine's private warm-up all happen inside that one call, which is
    /// exactly why there is no separate `warming` case to sit beside this one.
    case loadingModel

    /// `classify(_:)` is in flight.
    case inferring

    /// A result came back. The payload is the outcome's `degradations`, unmodified.
    ///
    /// A `[DegradationReason]`, deliberately not a `Bool`. The ledger records a degradation
    /// structurally — `kind`, `from_backend`, `to_backend` as columns (`LedgerSchema`) — so a
    /// boolean here would make the screen show strictly less than the row describing the same run,
    /// and "something was degraded" cannot say that LiteRT was unavailable and Core ML answered.
    /// Invariant 3 asks that degradation be *surfaced*, not merely flagged.
    ///
    /// Empty means clean. `success(degraded: [])` is the ordinary good outcome, not a special case.
    case success(degraded: [DegradationReason])

    /// No result came back — the engine threw. The payload is `InferenceError.isRetryable`,
    /// read straight from Core rather than re-derived here, so there is one definition of
    /// "retrying this could plausibly work" and the UI cannot drift from it.
    ///
    /// `retryable` is a **rendering** fact, not a transition guard: it decides whether the view
    /// offers a Retry button. It does not gate what the machine will accept next, because a
    /// non-retryable failure (`.unsupportedInput` on one image) says nothing about whether a
    /// *different* image can be classified — and conflating the two would strand the screen.
    case failed(retryable: Bool)

    /// Whether this state carries at least one degradation. Convenience for a view that only needs
    /// to decide whether to show the banner; the banner itself reads the reasons.
    public var isDegraded: Bool {
        switch self {
        case .success(let degradations): !degradations.isEmpty
        case .idle, .loadingModel, .inferring, .failed: false
        }
    }
}

// MARK: - Events

/// What the driver observed. One case per real transition point in a run, and nothing else — an
/// event with no emitter would smuggle back exactly the unreachability the `warming` correction
/// removed.
///
/// The driver (the screen rung, then the app rung) owns the engine and translates its own control
/// flow into these: it emits `.modelLoadBegan` immediately before `await engine.loadModel()`,
/// `.classifySucceeded` with `outcome.degradations` after `classify` returns, `.failed` from the
/// `catch`. The machine never calls an engine, so it never has to know which one is loaded.
public enum InferenceEvent: Sendable, Equatable {
    /// About to `await engine.loadModel()`.
    case modelLoadBegan

    /// About to `await engine.classify(_:)`.
    case classifyBegan

    /// `classify(_:)` returned. Carries `InferenceOutcome.degradations` verbatim — the same list
    /// that goes into the ledger row for this run, so screen and row cannot disagree.
    case classifySucceeded(degradations: [DegradationReason])

    /// `loadModel()` or `classify(_:)` threw. Carries the error itself rather than a pre-computed
    /// flag, so the `retryable` mapping lives in exactly one place (the transition below).
    case failed(InferenceError)

    /// The user dismissed the result, or the screen was cleared. Always legal.
    case reset
}

// MARK: - Transitions

extension InferenceState {
    /// The transition table, as a total function.
    ///
    /// Returns `nil` for a transition the machine refuses — `.classifySucceeded` while nothing was
    /// classifying, a reload under an in-flight inference. `nil` rather than "stay where you are"
    /// on purpose: silently absorbing an impossible event is how a screen ends up showing a state
    /// the run never reached, which is the failure this whole enum exists to prevent. A driver that
    /// gets `nil` has a bug, and the test suite pins every refusal so the bug is visible here
    /// rather than on screen.
    ///
    /// The full table, refusals included, is asserted pair by pair in `InferenceStateTests`.
    public func applying(_ event: InferenceEvent) -> InferenceState? {
        switch (self, event) {
        // `.reset` is legal from anywhere, including `idle` (idempotent) — the escape hatch that
        // guarantees no state is terminal.
        case (_, .reset):
            .idle

        // Starting a run.
        case (.idle, .modelLoadBegan):
            .loadingModel

        // The load returned; the driver moves straight to inference. There is no state between
        // these two — see the file header.
        case (.loadingModel, .classifyBegan):
            .inferring
        case (.loadingModel, .failed(let error)):
            .failed(retryable: error.isRetryable)

        // The inference resolved, one way or the other.
        case (.inferring, .classifySucceeded(let degradations)):
            .success(degraded: degradations)
        case (.inferring, .failed(let error)):
            .failed(retryable: error.isRetryable)

        // The input changed while a classify was in flight. The state does not change, because the
        // screen is showing the same thing — a spinner over a new image. Cancelling the superseded
        // Task is the engine-level concern of the cancel-on-input-change rung, not a UI state; this
        // case is the seam it plugs into, and it is here rather than refused so that landing that
        // rung does not have to reopen the table.
        case (.inferring, .classifyBegan):
            .inferring

        // From a resolved run: classify again on the loaded model, or swap engine/model and reload.
        // Both are legal after `success` AND after `failed`, regardless of `retryable` — see the
        // note on `failed(retryable:)`: `retryable` describes the failed call, not the screen.
        case (.success, .classifyBegan), (.failed, .classifyBegan):
            .inferring
        case (.success, .modelLoadBegan), (.failed, .modelLoadBegan):
            .loadingModel

        // Everything else is refused. Written as an explicit default rather than exhaustive cases
        // because the refusals are the complement of the table above, and enumerating them twice
        // would let the two drift; the test suite enumerates them instead, where a drift fails.
        //
        // Refused: a second `.modelLoadBegan` while already loading or inferring; a `.classifyBegan`
        // from `idle` (nothing is loaded); and any resolution event — `.classifySucceeded`,
        // `.failed` — arriving when no call was in flight.
        default:
            nil
        }
    }

    /// Apply an event, or leave the state untouched if the machine refuses it.
    ///
    /// The convenience a driver actually calls. It discards the refusal, which is safe only because
    /// `applying(_:)` above is the tested surface — a driver that wants to know should call that.
    public mutating func apply(_ event: InferenceEvent) {
        if let next = applying(event) { self = next }
    }
}
