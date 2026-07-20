// The aggregated shape of a benchmark session — the p50/p95 vocabulary, as value types.
//
// Zero imports, like the rest of Core: `Duration` is stdlib.
//
// WHY THESE LIVE HERE AND THE ARITHMETIC DOES NOT (ADR-0008). `LatencyRecorder` computes
// them, in InferlensBench, and that is the only place any percentile is computed in this repo —
// CLAUDE.md invariant 1 makes the percentile definition, the cold/warm boundary and the warm-up
// policy maintainer-ratified choices, and a second implementation of any of them would be a second
// definition of the benchmark rather than duplicated code. The types moved here so that
// `InferlensUI` — which depends on Core alone — can NAME a summary handed to it without being able
// to produce one. The screen displays the number; Bench is the only module that can make one.
//
// The criterion is the one `LatencyRecorder`'s header already states: a recorder is computation
// OVER Core's timing types, not a type. `LatencySample` and `LoadTiming` are likewise named by no
// protocol requirement in this module and sit here because they are the vocabulary a run is
// described in; the summary of a set of samples belongs beside the samples.
//
// The initializers are public because Bench has to construct them from outside. So the boundary is
// documented, not enforced: nothing in the type system stops a view from fabricating a
// `LatencySummary`. Named in ADR-0008 rather than left to be discovered.

// MARK: - Percentiles

/// p50 and p95 of one measured quantity across a set of runs.
///
/// Both are real observed durations, not interpolated. The convention the aggregation satisfies —
/// pinned exactly by `LatencyRecorderTests` and ratified as choice (a) at
/// `LatencyRecorder.nearestRank` — is nearest-rank: sort ascending, 1-indexed rank
/// `ceil(p/100 * N)` clamped to `1...N`, take that sample. It always returns a run that actually
/// happened (no synthetic value between two runs), which is the honest thing to report for a latency
/// SLO, and `p50 <= p95` holds for any input.
///
/// This doc describes the choice; it does not make it. The ratification lives at the code that
/// implements it, and moving these types did not touch it.
public struct Percentiles: Sendable, Equatable {
    public let p50: Duration
    public let p95: Duration

    public init(p50: Duration, p95: Duration) {
        self.p50 = p50
        self.p95 = p95
    }
}

// MARK: - One load class

/// p50/p95 across the three timed quantities of one load class (cold or warm), plus how many runs
/// the statistics were computed over. The count travels with the percentiles on purpose: a p95 over
/// 3 runs and over 300 are different claims (it feeds `make bench`'s run-count field, it is how the
/// spec proves the cold warm-up run was excluded from the warm count, and it is why the screen can
/// mark a readout as thin evidence instead of quoting three runs as if they were three hundred).
///
/// `RunTiming.compute` (preprocess + infer) is intentionally NOT a fourth field: for a warm run it
/// equals `total`, and the preprocess/infer split already exposes its parts, so aggregating it again
/// would double-report the same time rather than add signal. It is subsumed, not silently dropped.
public struct TimingBreakdown: Sendable, Equatable {
    public let preprocess: Percentiles
    public let infer: Percentiles
    /// Whole-run total per `LatencySample.total`: cold totals include model load, warm totals do not.
    public let total: Percentiles
    public let sampleCount: Int

    public init(preprocess: Percentiles, infer: Percentiles, total: Percentiles, sampleCount: Int) {
        self.preprocess = preprocess
        self.infer = infer
        self.total = total
        self.sampleCount = sampleCount
    }
}

// MARK: - A session

/// The aggregated latency of one benchmark session, split by load class. A bucket is `nil` when no
/// sample of that class was recorded (warm-only or cold-only input is valid); the README table reads
/// `cold?.total` and `warm?.total`. The cold run is the load-paying warm-up, so it never pools into
/// the warm statistics — cold and warm are computed independently.
public struct LatencySummary: Sendable, Equatable {
    public let cold: TimingBreakdown?
    public let warm: TimingBreakdown?

    public init(cold: TimingBreakdown?, warm: TimingBreakdown?) {
        self.cold = cold
        self.warm = warm
    }
}
