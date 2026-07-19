// The RED half of the rung-12 red->green pair. These property tests ARE the spec for the
// `LatencyRecorder` aggregation (CLAUDE.md invariant 1, third correction: the agent writes the spec
// AND the aggregation; the maintainer decides and ratifies the biasable choices, documented at the
// code). They must FAIL against the non-computing stub — that failure is the proof the spec tests
// something real. Once the agent-written, maintainer-decided `summarize` lands (the green half),
// these go green unchanged.
//
// The percentile convention these tests pin — nearest-rank: sort ascending, 1-indexed rank
// `ceil(p/100 * N)` clamped to `1...N`, take that sample. Chosen because it returns a run that
// actually happened (no value interpolated between two runs), which is the honest number for a
// latency SLO, and it is unambiguous for the small N a benchmark session produces. It is pinned HERE,
// as exact input -> exact output; if the maintainer prefers linear interpolation instead, that is a
// contract change to settle at this review gate — the exact-value expectations below move in lockstep.
//
// The exact-value test is the load-bearing one: ordering alone (p50 <= p95) also passes on a
// degenerate all-zeros implementation, so it cannot be the only guard. The known-answer test is what
// forces a correct aggregation.

import XCTest
import InferlensBench
import InferlensCore

final class LatencyRecorderTests: XCTestCase {

    // MARK: - Sample builders (fixed durations -> exact, interpolation-free expectations)

    private func warm(preprocessMs: Int, inferMs: Int) -> LatencySample {
        LatencySample(
            load: .warm,
            run: RunTiming(preprocess: .milliseconds(preprocessMs), infer: .milliseconds(inferMs))
        )
    }

    private func cold(loadMs: Int, preprocessMs: Int, inferMs: Int) -> LatencySample {
        LatencySample(
            load: .cold(.milliseconds(loadMs)),
            run: RunTiming(preprocess: .milliseconds(preprocessMs), infer: .milliseconds(inferMs))
        )
    }

    // MARK: - The teeth: a known sample set maps to known percentiles, exactly

    func testPercentilesOnKnownWarmSetMatchExactAnswers() throws {
        // Four warm runs where preprocess = i ms, infer = 10i ms, total = 11i ms (i = 1...4). Fed in a
        // fixed scrambled order so a non-sorting implementation cannot pass by reading raw positions.
        // Nearest-rank, N=4: p50 -> rank ceil(0.50*4)=2 -> 2nd smallest; p95 -> rank ceil(0.95*4)=4 -> 4th.
        let order = [3, 1, 4, 2]
        let samples = order.map { warm(preprocessMs: $0, inferMs: 10 * $0) }

        let summary = try LatencyRecorder().summarize(samples)

        XCTAssertNil(summary.cold, "no cold run was recorded")
        let w = try XCTUnwrap(summary.warm, "every run is warm, so the warm bucket exists")
        XCTAssertEqual(w.sampleCount, 4)
        XCTAssertEqual(w.preprocess.p50, .milliseconds(2))
        XCTAssertEqual(w.preprocess.p95, .milliseconds(4))
        XCTAssertEqual(w.infer.p50, .milliseconds(20))
        XCTAssertEqual(w.infer.p95, .milliseconds(40))
        XCTAssertEqual(w.total.p50, .milliseconds(22))
        XCTAssertEqual(w.total.p95, .milliseconds(44))
    }

    func testP95IsNearestRankNotMax() throws {
        // 20 warm runs, preprocess = infer = i ms (i = 1...20), fed in a FIXED scrambled order (a
        // literal permutation of 1...20 — deterministic, no unseeded shuffle). Nearest-rank, N=20:
        //   p50 -> rank ceil(0.50*20)=10 -> 10ms; p95 -> rank ceil(0.95*20)=19 -> 19ms.
        // 19ms is NOT the maximum (20ms). A "p95 == max" implementation returns 20 here and fails —
        // this closes the gap that every other exact case has p95 sitting at the max rank.
        let order = [7, 14, 1, 19, 6, 12, 20, 3, 9, 16, 2, 11, 18, 5, 15, 8, 13, 4, 17, 10]
        let samples = order.map { warm(preprocessMs: $0, inferMs: $0) }

        let w = try XCTUnwrap(try LatencyRecorder().summarize(samples).warm)
        XCTAssertEqual(w.sampleCount, 20)
        XCTAssertEqual(w.infer.p50, .milliseconds(10))
        XCTAssertEqual(w.infer.p95, .milliseconds(19), "nearest-rank p95 is the 19th of 20, not the max (20)")
    }

    // MARK: - Ordering, always (on a seeded-random set)

    func testP50NeverExceedsP95OnASeededRandomSet() throws {
        // A deterministic pseudo-random session (one cold load + 39 warm runs) with widely varied
        // durations, so p50 and p95 genuinely differ. For every present bucket and every quantity,
        // p50 <= p95 must hold. Seeded, so the case is fixed and reproducible.
        var rng = SplitMix64(seed: 0xB0BA_CAFE_F00D_1234)
        var samples = [cold(
            loadMs: Int.random(in: 100...900, using: &rng),
            preprocessMs: Int.random(in: 1...200, using: &rng),
            inferMs: Int.random(in: 1...200, using: &rng)
        )]
        for _ in 0..<39 {
            samples.append(warm(
                preprocessMs: Int.random(in: 1...200, using: &rng),
                inferMs: Int.random(in: 1...200, using: &rng)
            ))
        }

        let summary = try LatencyRecorder().summarize(samples)

        for breakdown in [summary.cold, summary.warm].compactMap({ $0 }) {
            for quantity in [breakdown.preprocess, breakdown.infer, breakdown.total] {
                XCTAssertLessThanOrEqual(quantity.p50, quantity.p95)
            }
        }
    }

    // MARK: - Warm-up discard: the cold run is excluded from the warm statistics

    func testColdRunIsExcludedFromWarmStatistics() throws {
        // "Warm-up discard" here means exactly the cold/warm split: the first cold (load-paying)
        // run is the warm-up, and it never enters the warm statistics. One extreme cold run plus three
        // warm runs — if the cold run leaked in, warm.sampleCount would be 4 and warm p95 would be 999.
        let samples = [
            cold(loadMs: 1000, preprocessMs: 999, inferMs: 999),
            warm(preprocessMs: 1, inferMs: 10),
            warm(preprocessMs: 2, inferMs: 20),
            warm(preprocessMs: 3, inferMs: 30),
        ]

        let summary = try LatencyRecorder().summarize(samples)

        let w = try XCTUnwrap(summary.warm)
        XCTAssertEqual(w.sampleCount, 3, "the cold warm-up run is not counted among the warm runs")
        // Warm stats over [1,2,3] / [10,20,30]: p50 -> rank ceil(1.5)=2, p95 -> rank ceil(2.85)=3.
        XCTAssertEqual(w.preprocess.p50, .milliseconds(2))
        XCTAssertEqual(w.preprocess.p95, .milliseconds(3))
        XCTAssertEqual(w.infer.p95, .milliseconds(30), "the cold run's 999ms never enters warm stats")
    }

    // MARK: - Cold and warm are independent, not pooled

    func testColdAndWarmAreSeparatedNotPooled() throws {
        // Warm infer = [10,20,30,40,50] -> warm p50 (rank ceil(2.5)=3) = 30ms. Pooling the one small
        // cold run (infer 5ms) into a single set [5,10,20,30,40,50] would move p50 to rank
        // ceil(3.0)=3 -> 20ms. The split must keep warm p50 at 30 and compute cold from the cold run.
        let samples =
            [cold(loadMs: 100, preprocessMs: 1, inferMs: 5)]
                + (1...5).map { warm(preprocessMs: $0, inferMs: 10 * $0) }

        let summary = try LatencyRecorder().summarize(samples)

        let w = try XCTUnwrap(summary.warm)
        let c = try XCTUnwrap(summary.cold)
        XCTAssertEqual(w.infer.p50, .milliseconds(30), "warm p50 is over warm runs only (pooled would be 20)")
        XCTAssertEqual(c.infer.p50, .milliseconds(5), "cold p50 is over the cold run alone")
        XCTAssertEqual(w.sampleCount, 5)
        XCTAssertEqual(c.sampleCount, 1)
    }

    // MARK: - total carries load for cold, not for warm (LatencySample.total semantics)

    func testColdTotalIncludesLoadWarmTotalExcludesIt() throws {
        // Verified against Core: LatencySample.total = load + preprocess + infer when cold, and
        // preprocess + infer when warm. So cold total = 100 + 1 + 5 = 106ms; warm total = 1 + 5 = 6ms.
        let samples = [
            cold(loadMs: 100, preprocessMs: 1, inferMs: 5),
            warm(preprocessMs: 1, inferMs: 5),
        ]

        let summary = try LatencyRecorder().summarize(samples)

        let c = try XCTUnwrap(summary.cold)
        let w = try XCTUnwrap(summary.warm)
        XCTAssertEqual(c.total.p50, .milliseconds(106), "cold total carries model load")
        XCTAssertEqual(w.total.p50, .milliseconds(6), "warm total is preprocess + infer, no load")
    }

    // MARK: - Monotonicity: a strictly slower sample cannot lower p95

    func testAddingASlowerSampleCannotLowerP95() throws {
        let base = (1...5).map { warm(preprocessMs: $0, inferMs: 10 * $0) }
        let recorder = LatencyRecorder()

        let before = try recorder.summarize(base)
        let after = try recorder.summarize(base + [warm(preprocessMs: 100, inferMs: 1000)])

        let p95Before = try XCTUnwrap(before.warm).infer.p95
        let p95After = try XCTUnwrap(after.warm).infer.p95
        XCTAssertGreaterThanOrEqual(p95After, p95Before, "adding a slower run cannot lower warm infer p95")
    }

    // MARK: - Edge cases: the contract for empty and single-sample (partial) input

    func testEmptyInputThrowsNoSamples() {
        XCTAssertThrowsError(try LatencyRecorder().summarize([])) { error in
            guard let recorderError = error as? LatencyRecorderError, case .noSamples = recorderError else {
                return XCTFail("empty input must throw .noSamples; got \(error)")
            }
        }
    }

    func testWarmOnlyInputLeavesColdNil() throws {
        // Partial input, one direction: warm runs only -> cold bucket absent, p50 == p95 on one run.
        let summary = try LatencyRecorder().summarize([warm(preprocessMs: 7, inferMs: 13)])

        XCTAssertNil(summary.cold)
        let w = try XCTUnwrap(summary.warm)
        XCTAssertEqual(w.sampleCount, 1)
        XCTAssertEqual(w.preprocess.p50, .milliseconds(7))
        XCTAssertEqual(w.preprocess.p95, .milliseconds(7))
        XCTAssertEqual(w.infer.p50, .milliseconds(13))
        XCTAssertEqual(w.infer.p95, .milliseconds(13))
        XCTAssertEqual(w.total.p50, .milliseconds(20))
        XCTAssertEqual(w.total.p95, .milliseconds(20))
    }

    func testColdOnlyInputLeavesWarmNil() throws {
        // Partial input, the other direction: a cold run only -> warm bucket absent, cold populated.
        let summary = try LatencyRecorder().summarize([cold(loadMs: 50, preprocessMs: 3, inferMs: 4)])

        XCTAssertNil(summary.warm)
        let c = try XCTUnwrap(summary.cold)
        XCTAssertEqual(c.sampleCount, 1)
        XCTAssertEqual(c.preprocess.p50, .milliseconds(3))
        XCTAssertEqual(c.preprocess.p95, .milliseconds(3))
        XCTAssertEqual(c.total.p50, .milliseconds(57), "50 + 3 + 4, load included")
        XCTAssertEqual(c.total.p95, .milliseconds(57))
    }
}

// A deterministic RandomNumberGenerator so the "randomized" ordering test is fixed and reproducible
// (SplitMix64). Test-only; not part of any measurement path.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
