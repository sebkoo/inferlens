// What a latency figure looks like on the screen — and what it must carry to be allowed there.
//
// ADR-0008 is the boundary decision behind this file: `LatencySummary` is a Core value type, so this
// module can NAME one; `LatencyRecorder` is in InferlensBench, so this module can never COMPUTE one.
// The screen is handed a summary by whoever composed it (the app target), and the only
// arithmetic here is converting a `Duration` into a number a person reads.
//
// CLAUDE.md invariant 7 is the reason `LatencyReadout` is a struct rather than a bare
// `LatencySummary` parameter: "no latency figure exists without the hardware and OS that produced
// it." A caller cannot supply the number and forget the device, because they are one value. The same
// requirement is repeated at the injection point (`LatencySource`) so it is impossible to wire a
// summarizer into the driver without naming the machine.

import InferlensCore

// MARK: - The readout

/// A latency summary together with the machine that produced it.
///
/// `device` and `os` are plain text, supplied by the composition, not a `DeviceIdentity`.
/// `DeviceIdentity` lives in InferlensStore because it needs `ProcessInfo` and `uname`, and Core has
/// no imports at all — pulling Foundation into the zero-dependency root to share two strings would
/// be a far larger change than the one it saves (ADR-0008).
public struct LatencyReadout: Sendable, Equatable {
    public let summary: LatencySummary
    /// e.g. `iPhone17,1`, or `Simulator (iPhone17,1)` — whatever the composition read.
    public let device: String
    /// e.g. `iOS 26.1`.
    public let os: String

    public init(summary: LatencySummary, device: String, os: String) {
        self.summary = summary
        self.device = device
        self.os = os
    }
}

// MARK: - Formatting

/// Milliseconds, one decimal place, for the two `Duration`s in a `Percentiles`.
///
/// Formatting lives in this module rather than in Core for the reason `DegradationReason.displayText`
/// does: it is a rendering decision, and Core carries nothing a designer would want to change.
public enum LatencyFormat {
    /// A `Duration` as whole and fractional milliseconds.
    ///
    /// `Duration.components` is `(seconds, attoseconds)`; there is no lossless millisecond accessor,
    /// so the two parts are combined once, here, instead of at three call sites.
    public static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// `"12.4 ms"`. The unit is never dropped: a bare number on a screen beside a device name is the
    /// kind of figure someone quotes without its units.
    public static func text(_ duration: Duration) -> String {
        String(format: "%.1f ms", milliseconds(duration))
    }

    /// `"12.4 / 31.0 ms"` — p50 then p95, one unit for the pair.
    public static func text(_ percentiles: Percentiles) -> String {
        String(
            format: "%.1f / %.1f ms",
            milliseconds(percentiles.p50),
            milliseconds(percentiles.p95)
        )
    }

    /// How many runs a percentile was computed over, said in words rather than left as a bare count.
    ///
    /// A p95 over three runs and over three hundred are different claims — the sample count travels
    /// with the percentiles in `TimingBreakdown` precisely so this can be said, and saying it is the
    /// whole difference between reporting a measurement and implying one.
    public static func evidence(_ breakdown: TimingBreakdown) -> String {
        breakdown.sampleCount == 1
            ? "1 run"
            : "\(breakdown.sampleCount) runs"
    }
}
