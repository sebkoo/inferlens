// InferlensBench — benchmark aggregation. It turns a session's raw `LatencySample`s (one per
// `classify`, each carrying the load the recorder observed) into the p50/p95 summary the README's
// Cold/Warm latency table and `make bench` report.
//
// Dependency direction (ADR-0001, amended 6 -> 7 modules): InferlensBench -> InferlensCore only.
// It imports no engine, no Conformance, no Foundation — `Duration` is stdlib and a `LatencySample`
// is a Core value type. Aggregation lives ABOVE the engines; it is never inside one, and Core stays
// zero-dependency value-types-only (a recorder is computation OVER those types, not a type).
//
// CLAUDE.md INVARIANT 1 (split trust, third correction) — READ BEFORE EDITING. The measurement path,
// the per-engine brackets AND this aggregation, is AGENT-WRITTEN, HUMAN-DECIDED, HUMAN-REVIEWED. The
// biasable choices — the percentile definition, the cold/warm boundary, and the warm-up policy, where a
// hidden choice would skew the benchmark — are DECIDED by the maintainer and ratified in the green
// commit's message; each is marked (a)/(b)/(c) in a comment at the code below. No agent may introduce
// or change a biasable choice without an explicit recorded ratification. This file is NOT hand-written:
// no comment in it may claim that it is.

import InferlensCore

// MARK: - Summary (what the recorder produces)

// `Percentiles`, `TimingBreakdown` and `LatencySummary` are Core value types — see
// `InferlensCore/LatencySummary.swift`. They were defined here until the screen had to
// name a summary it must never compute: `InferlensUI` depends on Core alone, so the types moved down
// and the arithmetic stayed put (ADR-0008). Nothing about the aggregation changed with them — not
// the percentile definition, not the cold/warm boundary, not the warm-up policy. This file is still
// the only place in the repo where a percentile is computed, which is what invariant 1 requires.

// MARK: - Failure

/// The only error `summarize` throws.
public enum LatencyRecorderError: Error, Sendable {
    /// No samples at all — a percentile over zero runs is undefined, so the caller gets a typed error
    /// rather than a summary of nothing. Partial input is NOT this case: warm-only or cold-only input
    /// yields a summary with the absent bucket `nil`. Only a fully empty input throws.
    case noSamples
}

// MARK: - Recorder

/// Aggregates a session's `LatencySample`s into a `LatencySummary`.
///
/// Contract (pinned by `LatencyRecorderTests`; agent-written, maintainer-decided per CLAUDE.md
/// invariant 1 — the biasable choices below are ratified, not authored, by the agent):
/// - Samples partition by `LatencySample.isCold` into a cold bucket and a warm bucket; each bucket's
///   statistics are computed independently (never pooled). The cold run — the load-paying warm-up — is
///   therefore kept out of the warm statistics, but it is REPORTED in the cold bucket, not discarded.
/// - For each non-empty bucket, `preprocess`, `infer`, and whole-run `total` each get p50/p95 by the
///   nearest-rank convention documented on `Percentiles`. `total` is `LatencySample.total`, so cold
///   totals carry model load and warm totals do not.
/// - A bucket with no samples is `nil`. A fully empty input throws `.noSamples`.
public struct LatencyRecorder: Sendable {
    public init() {}

    public func summarize(_ samples: [LatencySample]) throws(LatencyRecorderError) -> LatencySummary {
        // (d) Plumbing — non-biasable. Empty input has no defined percentile, so it is a typed error,
        // not a summary of nothing.
        guard !samples.isEmpty else { throw .noSamples }

        // (b) Cold/warm boundary — MAINTAINER-DECIDED, ratified in this commit's message. A COLD sample
        // is the first run after a model load; its `total` carries the load cost (loadDuration + compute,
        // per `LatencySample.total`). Every later run on the loaded model is WARM (compute only). There is
        // exactly one cold sample per load and no run is counted twice: the two buckets partition the
        // input by `LatencySample.isCold`, so a sample lands in one bucket or the other, never both.
        //
        // (c) Warm-up discard — MAINTAINER-DECIDED, ratified in this commit's message. The recorder
        // discards NOTHING. The engine already runs one throwaway `Invoke` inside `loadModel` and never
        // records it; that is the only warm-up. The cold run is REPORTED in the cold bucket, not dropped —
        // cold start is a real, user-visible cost, and silently dropping slow early samples would flatter
        // the benchmark. There is no discard step, before or after this partition.
        let cold = samples.filter(\.isCold)
        let warm = samples.filter { !$0.isCold }

        return LatencySummary(
            cold: cold.isEmpty ? nil : breakdown(of: cold),
            warm: warm.isEmpty ? nil : breakdown(of: warm)
        )
    }

    /// p50/p95 of each timed quantity over one non-empty bucket. `total` is `LatencySample.total`, so a
    /// cold bucket's total carries model load and a warm bucket's does not (choice b).
    private func breakdown(of samples: [LatencySample]) -> TimingBreakdown {
        TimingBreakdown(
            preprocess: percentiles(of: samples.map(\.run.preprocess)),
            infer: percentiles(of: samples.map(\.run.infer)),
            total: percentiles(of: samples.map(\.total)),
            sampleCount: samples.count
        )
    }

    /// p50 and p95 by nearest-rank. Sorts a COPY (choice d — the caller's array is never mutated).
    private func percentiles(of durations: [Duration]) -> Percentiles {
        let sorted = durations.sorted()
        return Percentiles(p50: nearestRank(sorted, 50), p95: nearestRank(sorted, 95))
    }

    /// (a) Percentile definition — MAINTAINER-DECIDED, ratified in this commit's message. Nearest-rank in
    /// INTEGER arithmetic: `rank = ceil(p*N/100)` written as `(p*N + 99) / 100`, 1-indexed, clamped
    /// `1...N`. The integer form is deliberate — in binary floating point `ceil(0.95 * 20.0)` can land on
    /// 20.0 and silently report p95 == max, the exact bug the spec's teeth test (`testP95IsNearestRankNotMax`)
    /// guards against. The returned value is a latency some run ACTUALLY produced, never an interpolated
    /// number no run ever saw. `sorted` is non-empty here (an empty bucket is `nil` and never reaches this);
    /// for N == 1 both p50 and p95 resolve to rank 1, the single sample (choice d).
    private func nearestRank(_ sorted: [Duration], _ p: Int) -> Duration {
        let rank = min(max((p * sorted.count + 99) / 100, 1), sorted.count)
        return sorted[rank - 1]
    }
}
