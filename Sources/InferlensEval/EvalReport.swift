// The report a person reads. It formats `EvalResult` and decides nothing — every fact in it was
// settled before this file ran, which is why the byte-exact golden tests are a presentation spec and
// not a second copy of the arithmetic spec.
//
// NO FOUNDATION, and no `String(format:)` anywhere. Durations become milliseconds by integer
// arithmetic, the same reason `LatencyRecorder`'s ratified choice (a) is written in integers: a
// formatter is a locale away from printing `151,58 ms`, and a report whose bytes depend on the
// machine's region cannot be pinned by a golden. Column widths are computed from the content, so the
// layout is a function of the data and nothing else.

import InferlensCore

extension EvalResult {

    /// The whole report, newline-terminated — in the green half. The goldens in the spec are
    /// authored from the render rules, so this stub fails them all.
    public func rendered() -> String { "" }
}

// MARK: - Formatting

/// Whole nanoseconds out of a `Duration`, the same decomposition `LedgerCodec` uses to put them in.
/// Arithmetic, not a policy: no rounding decision, no unit choice, nothing a benchmark could be
/// skewed by.
func nanoseconds(_ duration: Duration) -> Int64 {
    let (seconds, attoseconds) = duration.components
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
}

/// `151582667` -> `"151.58 ms"`. Rounds half-up in integer arithmetic and never touches a formatter,
/// so the bytes are the same in every locale.
func milliseconds(_ duration: Duration) -> String {
    let hundredths = (nanoseconds(duration) + 5_000) / 10_000
    let whole = hundredths / 100
    let fraction = hundredths % 100
    return "\(whole).\(fraction < 10 ? "0" : "")\(fraction) ms"
}

