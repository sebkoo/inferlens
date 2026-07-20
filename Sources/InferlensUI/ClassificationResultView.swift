// The payload: what was seen, which engine answered, and how long it took.
//
// `InferenceStateView` draws the state; this draws the result underneath it. Splitting them keeps
// the state machine's view exactly as wide as the machine — five arms, no fields — and puts every
// question about a RESULT in one place.
//
// It knows no engine, like everything else in this module. `backend` arrives on the outcome, read
// from what actually ran rather than from what was asked for, which is the same value the ledger row
// stores and the same one a fallback would change (invariant 3).

import InferlensCore
import SwiftUI

// MARK: - The result

/// Top-3 labels with confidence, the backend that answered, and — when there is one — the latency
/// readout.
public struct ClassificationResultView: View {
    private let classifications: [Classification]
    private let backend: Backend
    private let readout: LatencyReadout?

    /// - Parameters:
    ///   - classifications: already sorted and already truncated by the caller. The contract
    ///     guarantees the sort (descending confidence, asserted by the conformance suite against
    ///     every engine); `ClassificationModel.topThree` does the truncation.
    ///   - backend: the engine that produced this result.
    ///   - readout: p50/p95 with the machine that measured them, or `nil` when nothing summarizes
    ///     this session's samples. `nil` draws NOTHING — not a placeholder, not a row of dashes.
    public init(
        classifications: [Classification],
        backend: Backend,
        readout: LatencyReadout? = nil
    ) {
        self.classifications = classifications
        self.backend = backend
        self.readout = readout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(classifications.enumerated()), id: \.offset) { _, classification in
                    HStack {
                        Text(classification.label)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        // A percentage, not the raw Float. `0.8231` on a screen is a number a
                        // person has to convert; the model's own precision is not the point here.
                        Text(Self.percent(classification.confidence))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Which engine answered — the fact the whole two-engine comparison turns on, so it is
            // on screen rather than inferred from a latency.
            HStack {
                Text("Answered by")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(backend.displayName)
            }
            .font(.footnote)

            if let readout {
                LatencyReadoutView(readout: readout)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// `0.823` as `"82.3%"`.
    static func percent(_ confidence: Float) -> String {
        String(format: "%.1f%%", confidence * 100)
    }
}

// MARK: - Latency

/// p50/p95 for this session, cold and warm, with the machine that produced them.
///
/// CLAUDE.md invariant 7 is why the device line is not optional and not a detail: no latency figure
/// exists without the hardware and OS behind it. `LatencyReadout` carries them, so this view cannot
/// be handed a number without one — and it prints them under every figure rather than beside the
/// first, because the line that gets screenshotted is the one that has to carry the caveat.
public struct LatencyReadoutView: View {
    private let readout: LatencyReadout

    public init(readout: LatencyReadout) {
        self.readout = readout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Cold and warm are separate rows, never averaged together: the cold run pays model
            // load and the warm ones do not, and pooling them would report a number no run
            // produced. The recorder keeps the buckets apart for the same reason.
            if let cold = readout.summary.cold {
                row(title: "Cold p50/p95", breakdown: cold)
            }
            if let warm = readout.summary.warm {
                row(title: "Warm p50/p95", breakdown: warm)
            }

            Text("\(readout.device) · \(readout.os)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    private func row(title: String, breakdown: TimingBreakdown) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(LatencyFormat.text(breakdown.total))
                .monospacedDigit()
            // The sample count travels with the number, because a p95 over 3 runs and over 300 are
            // different claims and only one of them is worth quoting.
            Text("(\(LatencyFormat.evidence(breakdown)))")
                .foregroundStyle(.secondary)
        }
    }
}
