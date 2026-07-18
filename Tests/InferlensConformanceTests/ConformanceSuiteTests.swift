// Rung 06 proves the suite two ways: it PASSES the conforming StubEngine, and — the part that
// matters — it FAILS a stub deliberately built to break one invariant. A suite that has never
// failed is not known to work; the negative is its proof of teeth. The full broken-variant matrix
// (unsorted, confidence > 1, lazy-load) is rung 07; rung 06 ships one.

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
}
