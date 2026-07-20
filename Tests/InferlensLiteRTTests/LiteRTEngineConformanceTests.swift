// The LiteRT engine's payoff: the contract, run against a REAL TensorFlow Lite engine — not the stub,
// and the SAME `assertConformsToContract` the Core ML engine passes. A green result here means the
// contract survived a second reality: preprocess separated cleanly from infer, `loadModel` warmed, the
// outcome's shape held. This is the moment Core ML AND TensorFlow Lite conform to one contract — the
// two-engine race becomes real, not planned.
//
// Simulator caveat (also in the commit body): the sim runs TFLite on CPU, so latency magnitude is
// unrepresentative and the steady-state check passes without a device's thermal behavior. Green here
// proves SHAPE-conformance; the real latency table is a device-bench claim, not a sim one.

import XCTest
import InferlensCore
import InferlensConformance
import InferlensLiteRT

final class LiteRTEngineConformanceTests: XCTestCase {

    /// The fetched model (git-ignored; `make bootstrap`, ADR-0002) lives at `<repo>/Vendor/Models`.
    /// Located from this source file's own path — the iOS simulator shares the host filesystem, so an
    /// absolute host path resolves at runtime. A missing file means bootstrap did not run: skip with a
    /// pointer, rather than fail with a cryptic error from inside TFLite.
    private func modelURL() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/InferlensLiteRTTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <repo>
        let url = repoRoot.appendingPathComponent("Vendor/Models/mobilenet_v2_1.0_224.tflite")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("model not fetched — run `make bootstrap` (Vendor/Models is git-ignored; ADR-0002). expected at \(url.path)")
        }
        return url
    }

    // MARK: - The contract, validated against reality.

    func testLiteRTEngineConformsToContract() async throws {
        let engine = LiteRTEngine(modelURL: try modelURL())
        try await assertConformsToContract(engine)
    }

    // MARK: - Engine-specific claims the engine-agnostic suite cannot make.

    /// The suite checks shape but never inspects labels or the backend. Here we assert a REAL classifier
    /// answered as LiteRT: an ImageNet-scale label set, all in range, sorted, with both timed phases
    /// actually measured.
    func testRealPredictionIsSortedInRangeAndLiteRT() async throws {
        let engine = LiteRTEngine(modelURL: try modelURL())
        try await engine.loadModel()

        let outcome = try await engine.classify(gradientImage(width: 320, height: 240, pixelFormat: .rgba8))

        XCTAssertGreaterThanOrEqual(outcome.classifications.count, 1000, "MobileNetV2 is ImageNet-scale (1001 incl. background)")
        let confidences = outcome.classifications.map(\.confidence)
        XCTAssertEqual(confidences, confidences.sorted(by: >), "sorted by confidence, descending")
        XCTAssertTrue(confidences.allSatisfy { (0...1).contains($0) }, "every confidence in 0...1 (post-softmax)")
        XCTAssertFalse(outcome.isDegraded, "a plain LiteRT run is not degraded")
        guard case .liteRT = outcome.backend else {
            return XCTFail("backend must name the engine that answered (.liteRT)")
        }
        // Both phases were measured, so both are positive on a real run — the split is real, not zeros.
        XCTAssertGreaterThan(outcome.timing.preprocess, .zero, "preprocess is measured")
        XCTAssertGreaterThan(outcome.timing.infer, .zero, "infer is measured")
    }

    /// Non-square input in both pixel formats exercises the resize AND the RGBA/BGRA channel pick — the
    /// preprocessing the engine owns.
    func testAcceptsNonSquareInputInBothPixelFormats() async throws {
        let engine = LiteRTEngine(modelURL: try modelURL())
        try await engine.loadModel()

        for format in [PixelFormat.rgba8, .bgra8] {
            let outcome = try await engine.classify(gradientImage(width: 200, height: 350, pixelFormat: format))
            XCTAssertGreaterThanOrEqual(outcome.classifications.count, 1000)
            XCTAssertTrue(outcome.classifications.allSatisfy { (0...1).contains($0.confidence) })
        }
    }

    /// `descriptor` is a `nonisolated let`, readable without `await` or a load — so this test needs no
    /// model file and no bootstrap.
    func testDescriptorReadableWithoutLoading() {
        let engine = LiteRTEngine(modelURL: URL(fileURLWithPath: "/does-not-exist.tflite"))
        XCTAssertEqual(engine.descriptor.name, "MobileNetV2 (Google, FP32)")
        XCTAssertEqual(engine.descriptor.inputSize.width, 224)
        XCTAssertEqual(engine.descriptor.inputSize.height, 224)
        guard case .fp32 = engine.descriptor.precision else {
            return XCTFail("Google's MobileNetV2 is FP32")
        }
    }

    /// Gate-3 proof (ADR-0005): a load failure must be a typed throw AND leave the engine safe to
    /// deallocate. `loadModel`'s error paths free exactly the handles they created and NEVER populate
    /// `ready`, so after a failed load `deinit` (with `ready == nil`) frees nothing — no handle is freed
    /// on the error path and again in `deinit`. Under AddressSanitizer this run surfaces any
    /// double-free / use-after-free in the failure path; a clean pass is the single-free proof.
    func testLoadFailsCleanlyOnBadModelBytes() async throws {
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferlens-bad-\(UUID().uuidString).tflite")
        try Data([0x00, 0x01, 0x02, 0x03, 0xff, 0xfe, 0x42, 0x00]).write(to: badURL)
        defer { try? FileManager.default.removeItem(at: badURL) }

        let engine = LiteRTEngine(modelURL: badURL)
        do {
            try await engine.loadModel()
            XCTFail("loadModel must throw on a non-.tflite file")
        } catch {
            guard case .modelLoadFailed = error else {
                return XCTFail("expected .modelLoadFailed, got \(error)")
            }
            XCTAssertFalse(error.isRetryable, "a bad model is a non-retryable load failure")
        }

        // classify after a failed load is a typed failure, not a trap.
        let blank = try ImageBuffer(width: 224, height: 224, pixelFormat: .rgba8, bytes: [UInt8](repeating: 0, count: 224 * 224 * 4))
        do {
            _ = try await engine.classify(blank)
            XCTFail("classify after a failed load must throw")
        } catch {
            guard case .modelLoadFailed = error else {
                return XCTFail("expected .modelLoadFailed, got \(error)")
            }
        }
        // engine deallocates here (ready == nil) — deinit frees nothing; ASan verifies no bad free.
    }

    // MARK: - Helpers

    /// A well-formed image filled with a gradient so preprocessing has real bytes to resize.
    private func gradientImage(width: Int, height: Int, pixelFormat: PixelFormat) throws -> ImageBuffer {
        let count = width * height * pixelFormat.bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8(i % 256) }
        return try ImageBuffer(width: width, height: height, pixelFormat: pixelFormat, bytes: bytes)
    }
}
