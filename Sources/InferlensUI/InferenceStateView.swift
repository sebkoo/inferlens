// The views over the state machine. One `switch`, five arms, no engine knowledge.
//
// These views take an `InferenceState` and render it. They do not own an engine, do not start a
// run, and do not decide when to move — a driver does that and hands the new state down. The
// consequence worth having: rendering every state is a matter of constructing a value, so a
// preview (or a screenshot test) can show the fallback banner without a phone that has actually
// thermally throttled.
//
// What is NOT here: the result itself — labels, confidences, the backend name, p50/p95. Those
// arrive with the screen rung that wires an image to an engine and has something to display. This
// rung is the machine and its chrome; adding fields now would mean shipping payload nothing reads.

import InferlensCore
import SwiftUI

// MARK: - The state machine, rendered

/// Renders exactly one of the five states of `InferenceState`.
///
/// The `switch` is exhaustive without a `default` on purpose: a sixth state cannot be added to the
/// enum without the compiler stopping here and demanding it be drawn. That is the same mechanism
/// `PixelFormat.bytesPerPixel` uses in Core — the type system forcing a decision rather than
/// letting a new case inherit someone else's behaviour.
public struct InferenceStateView: View {
    private let state: InferenceState
    private let onRetry: (() -> Void)?

    /// - Parameters:
    ///   - state: what to draw.
    ///   - onRetry: invoked when the user taps Retry. Optional because a host that has nothing to
    ///     retry with should not be able to promise a button that does nothing; when it is `nil`,
    ///     no Retry button is offered even for a retryable failure.
    public init(state: InferenceState, onRetry: (() -> Void)? = nil) {
        self.state = state
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .idle:
                Text("Choose a photo to classify.")
                    .foregroundStyle(.secondary)

            case .loadingModel:
                // One label for the whole cold start, because it IS one call — the model compile,
                // the ANE preparation and the engine's warm-up are all inside `loadModel()`.
                ProgressView("Loading model…")

            case .inferring:
                ProgressView("Classifying…")

            case .success(let degradations):
                Label("Classified", systemImage: "checkmark.circle")
                    .foregroundStyle(.primary)
                // Invariant 3: degradation is surfaced, never silent. An empty list draws nothing,
                // so a clean run is not decorated with an "all good" badge.
                if !degradations.isEmpty {
                    DegradationBanner(reasons: degradations)
                }

            case .failed(let retryable):
                Label("Couldn't classify this photo", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.primary)
                // The one place `retryable` is read. It decides whether a Retry button appears —
                // it does not gate what the machine accepts next (see `InferenceState.failed`).
                if retryable, let onRetry {
                    Button("Try again", action: onRetry)
                } else {
                    Text("Trying the same photo again won't help.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Degradation

/// The banner that makes a degraded result legible — which degradation, not merely that there was
/// one. This is the visible half of invariant 3: the ledger records `.fellBack(from:to:)` as
/// structured columns, and the screen says the same thing in words, from the same value.
public struct DegradationBanner: View {
    private let reasons: [DegradationReason]

    public init(reasons: [DegradationReason]) {
        self.reasons = reasons
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                Text(reason.displayText)
                    .font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
    }
}

extension DegradationReason {
    /// Presentation text. It lives in the UI module rather than Core because it is a rendering
    /// decision — Core stays free of anything a designer would want to change, and the ledger keeps
    /// its own encoding (`LedgerCodec`) so a stored row is never at the mercy of wording.
    ///
    /// A `switch` without a `default`, for the reason the file header gives: a new
    /// `DegradationReason` must be spelled out here, not silently rendered as someone else's text.
    public var displayText: String {
        switch self {
        case .thermallyThrottled:
            "Slower than usual — the device is hot."
        case .fellBack(let from, let to):
            "\(to.displayName) answered — \(from.displayName) was unavailable."
        }
    }
}

extension Backend {
    /// The engine's name as a reader would say it, not as the enum spells it.
    public var displayName: String {
        switch self {
        case .coreML: "Core ML"
        case .liteRT: "TensorFlow Lite"
        case .remote: "The remote fallback"
        }
    }
}

// MARK: - Previews

// One preview per state, for developing the views. They are NOT the source of the README's
// screenshots — that is `StateScreenshotTests`, which renders the same five states with
// `ImageRenderer` on the pinned simulator (ADR-0007).
//
// Why not the canvas: Xcode cannot render previews in this package. The executable target
// `InferlensApp` requires `ENABLE_DEBUG_DYLIB=YES`, which an SPM package does not cleanly expose, and
// the canvas fails before drawing anything. Recorded here so the next person does not spend the
// afternoon rediscovering it. The declarations stay because they cost five lines each and are how a
// SwiftUI module is ordinarily developed; they become useful the day that build setting is reachable.
//
// EVERY VALUE BELOW IS FABRICATED. No engine is constructed, no model is loaded, no inference runs,
// and no ledger row is written — a `success` here is a state value spelled out by hand, not a result.
// That is the payoff of the machine being a pure function over two enums, and it is simultaneously
// the hazard: these renders are indistinguishable from real ones to anyone looking at a picture.
// ADR-0007 therefore requires any image derived from them to carry, verbatim, "rendered from
// fabricated values; no engine ran, nothing was written to the ledger."

#Preview("idle") {
    InferenceStateView(state: .idle)
}

#Preview("loadingModel") {
    InferenceStateView(state: .loadingModel)
}

#Preview("inferring") {
    InferenceStateView(state: .inferring)
}

// The degraded case carries a REASON pair, not a flag — the banner names both ends of the fallback
// because `success(degraded:)` and the ledger's degradation row hold the same value (invariant 3).
#Preview("success-degraded") {
    InferenceStateView(state: .success(degraded: [.fellBack(from: .liteRT, to: .coreML)]))
}

// `onRetry` is supplied so the Retry button actually renders: with it `nil`, a retryable failure
// deliberately offers no button, and a screenshot of that would show the non-retryable chrome under
// a retryable caption.
#Preview("failed-retryable") {
    InferenceStateView(state: .failed(retryable: true), onRetry: {})
}
