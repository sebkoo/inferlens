// InferlensBench — benchmark aggregation. It turns a session's raw `LatencySample`s (one per
// `classify`, each carrying the load the recorder observed) into the p50/p95 summary the README's
// Cold/Warm latency table and `make bench` report.
//
// Dependency direction (ADR-0001, amended 6 -> 7 modules): InferlensBench -> InferlensCore only.
// It imports no engine, no Conformance, no Foundation — `Duration` is stdlib and a `LatencySample`
// is a Core value type. Aggregation lives ABOVE the engines; it is never inside one, and Core stays
// zero-dependency value-types-only (a recorder is computation OVER those types, not a type).
//
// CLAUDE.md INVARIANT 1 — READ BEFORE EDITING. "No agent-authored timing code. `LatencyRecorder`
// and the measurement path are hand-written and hand-reviewed ... Never generate or auto-edit the
// timing path unreviewed." This file is the RED half of the rung-12 red->green pair: it declares the
// PUBLIC API and a NON-COMPUTING stub only. The maintainer hand-writes `summarize`'s body; the
// property spec in `LatencyRecorderTests` verifies it. Do NOT implement the aggregation here.

import InferlensCore

// MARK: - Summary (what the recorder produces)

/// p50 and p95 of one measured quantity across a set of runs.
///
/// Both are real observed durations, not interpolated. The convention the hand-written aggregation
/// must satisfy — pinned exactly by `LatencyRecorderTests` — is nearest-rank: sort ascending,
/// 1-indexed rank `ceil(p/100 * N)` clamped to `1...N`, take that sample. It always returns a run
/// that actually happened (no synthetic value between two runs), which is the honest thing to report
/// for a latency SLO, and `p50 <= p95` holds for any input.
public struct Percentiles: Sendable {
    public let p50: Duration
    public let p95: Duration
}

/// p50/p95 across the three timed quantities of one load class (cold or warm), plus how many runs
/// the statistics were computed over. The count travels with the percentiles on purpose: a p95 over
/// 3 runs and over 300 are different claims (it feeds `make bench`'s run-count field, and it is how
/// the spec proves the cold warm-up run was excluded from the warm count).
///
/// `RunTiming.compute` (preprocess + infer) is intentionally NOT a fourth field: for a warm run it
/// equals `total`, and the preprocess/infer split already exposes its parts, so aggregating it again
/// would double-report the same time rather than add signal. It is subsumed, not silently dropped.
public struct TimingBreakdown: Sendable {
    public let preprocess: Percentiles
    public let infer: Percentiles
    /// Whole-run total per `LatencySample.total`: cold totals include model load, warm totals do not.
    public let total: Percentiles
    public let sampleCount: Int
}

/// The aggregated latency of one benchmark session, split by load class. A bucket is `nil` when no
/// sample of that class was recorded (warm-only or cold-only input is valid); the README table reads
/// `cold?.total` and `warm?.total`. The cold run is the load-paying warm-up, so it never pools into
/// the warm statistics — cold and warm are computed independently.
public struct LatencySummary: Sendable {
    public let cold: TimingBreakdown?
    public let warm: TimingBreakdown?
}

// MARK: - Failure

/// The only error `summarize` throws.
public enum LatencyRecorderError: Error, Sendable {
    /// No samples at all — a percentile over zero runs is undefined, so the caller gets a typed error
    /// rather than a summary of nothing. Partial input is NOT this case: warm-only or cold-only input
    /// yields a summary with the absent bucket `nil`. Only a fully empty input throws.
    case noSamples

    /// Stub sentinel for the rung-12 RED half. The aggregation is hand-written by the maintainer
    /// (CLAUDE.md invariant 1); until it lands, `summarize` throws this so `LatencyRecorderTests` is
    /// red — that red is the proof the spec tests something real. Delete this case together with the
    /// stub body when the GREEN half (the real aggregation) lands.
    case notImplemented
}

// MARK: - Recorder

/// Aggregates a session's `LatencySample`s into a `LatencySummary`.
///
/// Contract (pinned by `LatencyRecorderTests`; hand-implemented per CLAUDE.md invariant 1):
/// - Samples partition by `LatencySample.isCold` into a cold bucket and a warm bucket; each bucket's
///   statistics are computed independently (never pooled). The first cold run — the load-paying
///   warm-up — is therefore excluded from the warm statistics.
/// - For each non-empty bucket, `preprocess`, `infer`, and whole-run `total` each get p50/p95 by the
///   nearest-rank convention documented on `Percentiles`. `total` is `LatencySample.total`, so cold
///   totals carry model load and warm totals do not.
/// - A bucket with no samples is `nil`. A fully empty input throws `.noSamples`.
public struct LatencyRecorder: Sendable {
    public init() {}

    public func summarize(_ samples: [LatencySample]) throws(LatencyRecorderError) -> LatencySummary {
        // HAND-WRITTEN BY THE MAINTAINER — CLAUDE.md invariant 1. This is the RED half's stub: it
        // compiles but must not compute. The maintainer replaces this body with the real aggregation
        // (`.noSamples` on empty; nearest-rank p50/p95 per bucket otherwise); `LatencyRecorderTests`
        // is the spec it must satisfy. Do NOT auto-generate the math here.
        throw .notImplemented
    }
}
