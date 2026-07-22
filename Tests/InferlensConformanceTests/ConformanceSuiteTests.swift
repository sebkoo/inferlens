// This target proves the suite two ways: it PASSES the conforming StubEngine, and — the part that
// matters — it FAILS a stub deliberately built to break one invariant. A suite that has never
// failed is not known to work; the negative is its proof of teeth. The full broken-variant matrix
// (unsorted, confidence > 1, lazy-load) is its own rung; this one ships a single variant.

import XCTest
import InferlensCore
import InferlensConformance

final class ConformanceSuiteTests: XCTestCase {
    // MARK: Positive — the conforming stub passes.

    func testConformingStubConforms() async throws {
        // No throw == conformance. If this ever throws, the stub or the contract regressed.
        try await assertConformsToContract(StubEngine())
    }

    // MARK: Negative — the suite catches a broken engine (proof of teeth).

    func testSuiteFailsOnUnsortedClassifications() async throws {
        // A stub returning ascending confidences violates "sorted by confidence, descending".
        // StubEngine reports its `returning:` verbatim, so this is a genuinely non-conforming
        // engine — and the suite must reject it.
        let broken = StubEngine(returning: [
            Classification(label: "low", confidence: 0.10),
            Classification(label: "high", confidence: 0.90),
        ])

        do {
            try await assertConformsToContract(broken)
            XCTFail("the suite must FAIL on unsorted classifications — otherwise its green is hollow")
        } catch let violation as ConformanceViolation {
            guard case .classificationsNotSortedByConfidenceDescending = violation else {
                return XCTFail("expected the sorted-descending violation, got \(violation)")
            }
            // Correct: the suite threw the specific violation for this invariant.
        }
    }

    /// The cancellation check's own teeth (ADR-0014, Decision 2). An engine that ignores
    /// `Task.isCancelled` and answers anyway is non-conforming, and the suite must say so with the
    /// violation that names the rule — otherwise the new check is a green nobody has made fail.
    ///
    /// This is the negative control the ROADMAP records the earlier gates as lacking, written with
    /// the check rather than after it.
    func testSuiteFailsOnAnEngineThatIgnoresCancellation() async throws {
        do {
            try await assertConformsToContract(UncancellableEngine())
            XCTFail("the suite must FAIL an engine that answers a cancelled call")
        } catch let violation as ConformanceViolation {
            guard case .cancelledClassifyReturnedAnOutcome = violation else {
                return XCTFail("expected the cancelled-classify violation, got \(violation)")
            }
        }
    }
}

/// Conforming in every respect except the one under test: it never checks `Task.isCancelled`, so it
/// answers a call it was told to abandon.
///
/// A separate type rather than a `StubEngine` switch, for the reason that file already gives: the
/// stub ships only conforming defaults, and the broken instances belong to this suite. It reports
/// `StubEngine`'s own conforming outputs and timing so the ONLY thing wrong with it is the
/// cancellation clause.
private actor UncancellableEngine: InferenceEngine {
    nonisolated let descriptor: ModelDescriptor = .stub

    func loadModel() async throws(InferenceError) {}

    func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        InferenceOutcome(
            classifications: StubEngine.conformingOutputs,
            timing: StubEngine.instantRun,
            backend: .coreML
        )
    }
}
