// The thumbs signal's vocabulary: what a person said about one run's answer.
//
// Zero imports, like the rest of Core. It lives HERE — not in InferlensUI, which emits it, and
// not in InferlensStore, which persists it — because those two modules may only meet through
// Core's types (ADR-0001), the same reason the latency summary types moved here (ADR-0008). The
// thesis names this step: `capture signal (thumbs)` is the clause between the ledger and the
// export.

/// One thumbs judgement on one run's answer: the person said it was right, or said it was wrong.
///
/// Two cases and no third. "No signal yet" is the ABSENCE of a signal row for the run — the
/// signal table is append-only and a run starts with none — never a case of this enum: a `.none`
/// case here would let a writer record "nothing", which a reader could not tell apart from not
/// having recorded at all.
///
/// `Equatable` because consumers compare verdicts as data, not as control flow — the screen
/// highlights the thumb that matches, a test asserts the verdict that arrived — the same
/// reasoning `Backend` records for itself.
public enum SignalVerdict: Sendable, Equatable {
    /// The answer was right.
    case up
    /// The answer was wrong.
    case down
}
