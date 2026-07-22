// InferlensEval — the loop's sixth clause as code: `export → offline eval → choose next
// model/backend`. It reads the NDJSON `LedgerExport` writes and answers one question — which backend
// should the next run use — or REFUSES to answer it.
//
// THIS IS THE RED HALF of a spec-first red -> green pair. It carries the failing spec and a
// non-computing stub ONLY; the parse, the grouping, the threshold logic and the renderer land in the
// green half of the same push. The pair proves ORDER — that the spec preceded the implementation —
// not authorship (CLAUDE.md Process, the spec-first RED exception).
//
// Dependency direction (ADR-0001, amended 9 -> 10 modules): InferlensEval -> InferlensBench ->
// InferlensCore, plus Foundation. It is the graph's FIRST library -> library arrow and it is the
// point rather than a compromise: CLAUDE.md invariant 1 makes the percentile definition, the
// cold/warm boundary and the warm-up policy maintainer-ratified choices, and `LatencySummary.swift`
// records the consequence — `LatencyRecorder` is the only place any percentile is computed in this
// repo. So this module must not reproduce, describe or approximate them; the green half rebuilds a
// `LatencySample` from each row's own columns and calls `LatencyRecorder.summarize`, and the spec
// asserts that as an IDENTITY rather than as an intention (ADR-0015, Decisions 2 and 4).

import Foundation
import InferlensBench
import InferlensCore

// MARK: - Refusals

/// Why a file was refused. Every case names the 1-based LINE, because an eval that says "malformed
/// input" about a 500-row export has told the reader nothing they can act on.
///
/// A malformed row is REFUSED, never repaired and never partially read — the whole file is refused,
/// not the row, because a report over "the rows that happened to parse" is a statistic about an
/// unknown subset. That is the `RemoteEngine` validation precedent: a response this build cannot
/// fully understand is not a response.
public enum EvalError: Error, Sendable, Equatable {
    /// The RED half's stub. It is deleted by the green half; nothing in the spec expects it.
    case notImplemented
    /// The input held no rows at all.
    case noRows
    /// The line is not a single JSON object — NDJSON's one structural rule.
    case notJSONObject(line: Int)
    /// A key the contract requires is absent.
    case missingKey(line: Int, key: String)
    /// A key this build does not know. THIS is where an export from a future writer is refused: the
    /// NDJSON carries no version field to gate on (ADR-0015, Decision 5), so the key set IS the
    /// contract.
    case unknownKey(line: Int, key: String)
    /// A value of the wrong type, or outside the domain the contract fixes. `path` is dotted with
    /// bracketed indices — `signals[1].verdict` — so the reader is sent to the value, not the row.
    case badValue(line: Int, path: String)
    /// `load_ns` is present exactly when `is_cold` is 1 and absent otherwise.
    case loadTimingMismatch(line: Int, isCold: Bool)
}

// MARK: - Entry point

public enum LedgerEval {

    /// Parse, group, summarize and decide — in the green half. One synchronous pass, no clock read
    /// anywhere: every number in the result comes from the rows' own columns, which is what makes
    /// the whole of this module testable on shared CI hardware.
    public static func evaluate(ndjson: String) throws(EvalError) -> EvalResult {
        throw .notImplemented
    }
}
