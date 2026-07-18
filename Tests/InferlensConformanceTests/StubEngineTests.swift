// Rung 05 tests the stub directly — that it is a well-formed, deterministic, conforming engine.
// Rung 06 adds the engine-agnostic `assertConformsToContract` and runs it against this stub;
// rung 07 adds the broken variants. These tests are the narrower claim: the stub itself behaves.

import XCTest
import InferlensCore
import InferlensConformance

final class StubEngineTests: XCTestCase {
    /// A minimal valid buffer: 2×2 RGBA = 16 bytes.
    private func anImage() throws -> ImageBuffer {
        try ImageBuffer(
            width: 2,
            height: 2,
            pixelFormat: .rgba8,
            bytes: [UInt8](repeating: 0, count: 16)
        )
    }

    func testConformingOutputIsSortedDescendingAndInRange() async throws {
        let engine = StubEngine()
        try await engine.loadModel()
        let outcome = try await engine.classify(anImage())

        let confidences = outcome.classifications.map(\.confidence)
        XCTAssertEqual(confidences, confidences.sorted(by: >), "classifications must be sorted by confidence, descending")
        XCTAssertTrue(outcome.classifications.allSatisfy { (0...1).contains($0.confidence) }, "every confidence in 0...1")
        XCTAssertFalse(outcome.isDegraded, "the conforming stub reports no degradation")

        // Backend is not Equatable in the contract, so pattern-match rather than compare.
        guard case .coreML = outcome.backend else {
            return XCTFail("stub answers as the backend it was constructed with (.coreML)")
        }
    }

    func testDeterministicSameInputSameOutput() async throws {
        let engine = StubEngine()
        try await engine.loadModel()
        let image = try anImage()

        let first = try await engine.classify(image)
        let second = try await engine.classify(image)

        XCTAssertEqual(first.classifications.map(\.label), second.classifications.map(\.label))
        XCTAssertEqual(first.classifications.map(\.confidence), second.classifications.map(\.confidence))
    }

    func testSteadyStateRunOneNotSlowerThanRunTwo() async throws {
        // The obligation: loadModel reaches steady-state, so run 1's compute is not materially
        // slower than run 2's. The conforming stub (firstRun == nil) satisfies it exactly.
        let engine = StubEngine()
        try await engine.loadModel()
        let image = try anImage()

        let run1 = try await engine.classify(image).timing.compute
        let run2 = try await engine.classify(image).timing.compute
        XCTAssertEqual(run1, run2, "the conforming stub is at steady-state from the first call")
    }

    func testDescriptorReadableWithoutLoading() throws {
        // A Sendable `let`: readable synchronously, no await, no loadModel required.
        let engine = StubEngine()
        XCTAssertEqual(engine.descriptor.name, "stub")
        XCTAssertEqual(engine.descriptor.inputSize.width, 224)
        XCTAssertEqual(engine.descriptor.inputSize.height, 224)
    }
}
