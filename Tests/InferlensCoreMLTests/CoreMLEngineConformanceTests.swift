// Rung 10's payoff: the rung-03 contract, run against a REAL Core ML engine — not the stub. This
// imports InferlensConformance and calls the SAME `assertConformsToContract` the stub passes, so a
// green result here means the contract survived reality: preprocess separated cleanly from infer,
// `loadModel` warmed, the outcome's shape held. The suite lives one module away and names no engine;
// this file is where a concrete engine meets it.
//
// Simulator caveat (also stated in the commit body): the sim has no Neural Engine, so the
// steady-state / ANE-warm-up half of the contract passes TRIVIALLY here — nothing to warm, so run 1
// ≈ run 2 — and latency magnitude is unrepresentative. Green here proves SHAPE-conformance; ANE
// warm-up and the real latency table are a device-bench claim, not a simulator one.

import XCTest
import InferlensCore
import InferlensConformance
import InferlensCoreML

final class CoreMLEngineConformanceTests: XCTestCase {

    /// The fetched model (git-ignored; `make bootstrap`, ADR-0002) lives at `<repo>/Vendor/Models`.
    /// It is located from this source file's own path — the iOS simulator shares the host
    /// filesystem, so an absolute host path resolves at runtime. A missing file means bootstrap did
    /// not run: skip with a pointer, rather than fail with a cryptic error from inside Core ML.
    private func modelURL() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/InferlensCoreMLTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <repo>
        let url = repoRoot.appendingPathComponent("Vendor/Models/MobileNetV2FP16.mlmodel")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("model not fetched — run `make bootstrap` (Vendor/Models is git-ignored; ADR-0002). expected at \(url.path)")
        }
        return url
    }

    // MARK: - The contract, validated against reality.

    func testCoreMLEngineConformsToContract() async throws {
        let engine = CoreMLEngine(modelURL: try modelURL())
        try await assertConformsToContract(engine)
    }

    // MARK: - Engine-specific claims the engine-agnostic suite cannot make.

    /// The suite checks shape but never inspects labels (it cannot know the right ones). Here we
    /// assert a REAL classifier answered: an ImageNet-scale label set, all in range, sorted, and
    /// answering as Core ML with both timed phases actually measured.
    func testRealPredictionIsSortedInRangeAndCoreML() async throws {
        let engine = CoreMLEngine(modelURL: try modelURL())
        try await engine.loadModel()

        let outcome = try await engine.classify(gradientImage(width: 320, height: 240, pixelFormat: .rgba8))

        XCTAssertGreaterThanOrEqual(outcome.classifications.count, 1000, "MobileNetV2 is ImageNet-1k; every class maps from classLabelProbs")
        let confidences = outcome.classifications.map(\.confidence)
        XCTAssertEqual(confidences, confidences.sorted(by: >), "sorted by confidence, descending")
        XCTAssertTrue(confidences.allSatisfy { (0...1).contains($0) }, "every confidence in 0...1")
        XCTAssertFalse(outcome.isDegraded, "a plain Core ML run is not degraded")
        guard case .coreML = outcome.backend else {
            return XCTFail("backend must name the engine that answered (.coreML)")
        }
        // Both phases were measured, so both are positive on a real run — the split is real, not zeros.
        XCTAssertGreaterThan(outcome.timing.preprocess, .zero, "preprocess is measured")
        XCTAssertGreaterThan(outcome.timing.infer, .zero, "infer is measured")
    }

    /// Non-square input in both pixel formats exercises the resize AND the RGBA→BGRA permute — the
    /// preprocessing the engine owns (the reason it drives MLModel and not Vision).
    func testAcceptsNonSquareInputInBothPixelFormats() async throws {
        let engine = CoreMLEngine(modelURL: try modelURL())
        try await engine.loadModel()

        for format in [PixelFormat.rgba8, .bgra8] {
            let outcome = try await engine.classify(gradientImage(width: 200, height: 350, pixelFormat: format))
            XCTAssertGreaterThanOrEqual(outcome.classifications.count, 1000)
            XCTAssertTrue(outcome.classifications.allSatisfy { (0...1).contains($0.confidence) })
        }
    }

    func testDescriptorReadableWithoutLoading() throws {
        let engine = CoreMLEngine(modelURL: try modelURL())
        XCTAssertEqual(engine.descriptor.name, "MobileNetV2 (Apple, FP16)")
        XCTAssertEqual(engine.descriptor.inputSize.width, 224)
        XCTAssertEqual(engine.descriptor.inputSize.height, 224)
        // Precision is a plain contract enum; pattern-match (the codebase does not lean on Equatable).
        guard case .fp16 = engine.descriptor.precision else {
            return XCTFail("Apple's MobileNetV2 is FP16")
        }
    }

    // MARK: - Helpers

    /// A well-formed image of a given size/format, filled with a gradient so preprocessing has real
    /// bytes to resize (not a degenerate constant image).
    private func gradientImage(width: Int, height: Int, pixelFormat: PixelFormat) throws -> ImageBuffer {
        let count = width * height * pixelFormat.bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8(i % 256) }
        return try ImageBuffer(width: width, height: height, pixelFormat: pixelFormat, bytes: bytes)
    }
}
