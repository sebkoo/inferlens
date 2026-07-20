// The spec for the driver — the object that turns a photo into a state, a result and a sample.
//
// The claim under test is the same one the state-machine spec makes, one level up: this needs no
// model file, no engine module and no device capability. The engine here is a fake declared in this
// file, because `InferlensUITests` depends on `InferlensUI` + `InferlensCore` and NOT on
// `InferlensConformance` — the shared `StubEngine` lives there, and importing it would make the UI
// test target depend on the engine-conformance machinery to test a view model. The fake is nine
// lines and says exactly what each test needs it to say.
//
// What these tests do NOT read:
//   - they never assert a DURATION produced by the load bracket. The bracket is real wall-clock time
//     (`ContinuousClock`), so any threshold would be a flake waiting for a slow machine. What is
//     asserted instead is the thing the ratified cold/warm boundary actually decides: WHICH BUCKET a
//     sample lands in, and that exactly one cold sample exists per load.
//   - they do not test SwiftUI rendering. `ClassificationScreen` needs a photo library; the views it
//     composes are covered by the screenshot renderer, and the state machine underneath by
//     `InferenceStateTests`.
//   - they do not check that percentiles are correct. That is `LatencyRecorderTests`, in the module
//     that owns the arithmetic — here the summarizer is a spy, and what is asserted is what the
//     driver HANDS it (ADR-0008: this module cannot compute a summary, so it must not pretend to).

import InferlensCore
import UIKit
import XCTest

@testable import InferlensUI

// MARK: - Fakes

/// An engine that returns what a test told it to. Conforms to the contract's shape only — the real
/// conformance suite runs against real engines elsewhere.
private actor FakeEngine: InferenceEngine {
    nonisolated let descriptor = ModelDescriptor(
        name: "fake",
        precision: .fp32,
        inputSize: PixelSize(width: 224, height: 224)
    )

    private let loadError: InferenceError?
    private let classifyError: InferenceError?
    private let result: InferenceOutcome

    private(set) var loadCount = 0
    private(set) var classifyCount = 0

    init(
        loadError: InferenceError? = nil,
        classifyError: InferenceError? = nil,
        result: InferenceOutcome = FakeEngine.defaultOutcome
    ) {
        self.loadError = loadError
        self.classifyError = classifyError
        self.result = result
    }

    static let defaultOutcome = InferenceOutcome(
        classifications: [
            Classification(label: "tabby", confidence: 0.82),
            Classification(label: "tiger cat", confidence: 0.11),
            Classification(label: "lynx", confidence: 0.04),
        ],
        timing: RunTiming(preprocess: .milliseconds(3), infer: .milliseconds(9)),
        backend: .coreML
    )

    func loadModel() async throws(InferenceError) {
        loadCount += 1
        if let loadError { throw loadError }
    }

    func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        classifyCount += 1
        if let classifyError { throw classifyError }
        return result
    }
}

/// A summarizer that records what it was handed and returns a fixed answer. It computes nothing —
/// the point of the seam is that this module cannot.
///
/// `@MainActor`, NOT `@unchecked Sendable`. CLAUDE.md invariant 2 caps the whole codebase at one
/// `@unchecked Sendable` and reserves it for the LiteRT C-handle boundary, so a test spy may not
/// spend it — and does not need to: a `@MainActor` class is `Sendable`, and the driver calls the
/// summarizer synchronously on the main actor, which `MainActor.assumeIsolated` at the call site
/// states rather than assumes.
@MainActor
private final class SummarizerSpy {
    private(set) var receivedCounts: [Int] = []
    private(set) var lastSamples: [LatencySample] = []
    var answer: LatencySummary? = SummarizerSpy.fixedSummary

    static let fixedSummary = LatencySummary(
        cold: TimingBreakdown(
            preprocess: Percentiles(p50: .milliseconds(3), p95: .milliseconds(3)),
            infer: Percentiles(p50: .milliseconds(9), p95: .milliseconds(9)),
            total: Percentiles(p50: .milliseconds(112), p95: .milliseconds(112)),
            sampleCount: 1
        ),
        warm: nil
    )

    func summarize(_ samples: [LatencySample]) -> LatencySummary? {
        receivedCounts.append(samples.count)
        lastSamples = samples
        return answer
    }
}

// MARK: - Fixtures

private func buffer() throws -> ImageBuffer {
    try ImageBuffer(
        width: 2,
        height: 1,
        pixelFormat: .rgba8,
        bytes: [255, 0, 0, 255, 0, 0, 255, 255]
    )
}

// MARK: - Tests

@MainActor
final class ClassificationModelTests: XCTestCase {
    // MARK: The happy path

    func testAFirstRunLoadsThenClassifiesAndEndsInSuccess() async throws {
        let engine = FakeEngine()
        let model = ClassificationModel(engine: engine)

        XCTAssertEqual(model.state, .idle)
        await model.classify(try buffer())

        XCTAssertEqual(model.state, .success(degraded: []))
        let observedLoadCount = await engine.loadCount
        XCTAssertEqual(observedLoadCount, 1)
        let observedClassifyCount = await engine.classifyCount
        XCTAssertEqual(observedClassifyCount, 1)
    }

    func testTheResultCarriesTheTopThreeAndTheBackendThatAnswered() async throws {
        let model = ClassificationModel(engine: FakeEngine())
        await model.classify(try buffer())

        XCTAssertEqual(model.topThree.map(\.label), ["tabby", "tiger cat", "lynx"])
        XCTAssertEqual(model.outcome?.backend, .coreML)
    }

    /// The screen shows three. An engine returning more must not push a fourth row onto it, and one
    /// returning fewer must not crash — `prefix` handles both, and this pins that it is used.
    func testTopThreeTruncatesAndNeverOverruns() async throws {
        let many = InferenceOutcome(
            classifications: (0 ..< 7).map {
                Classification(label: "label-\($0)", confidence: Float(7 - $0) / 7)
            },
            timing: RunTiming(preprocess: .milliseconds(1), infer: .milliseconds(1)),
            backend: .liteRT
        )
        let model = ClassificationModel(engine: FakeEngine(result: many))
        await model.classify(try buffer())

        XCTAssertEqual(model.topThree.count, 3)
        XCTAssertEqual(model.topThree.map(\.label), ["label-0", "label-1", "label-2"])
    }

    /// Degradations travel from the outcome into the state unchanged — the property that lets the
    /// screen and the ledger row describe the same run identically (invariant 3).
    func testDegradationsReachTheStateUnchanged() async throws {
        let degraded = InferenceOutcome(
            classifications: [Classification(label: "x", confidence: 0.5)],
            timing: RunTiming(preprocess: .milliseconds(1), infer: .milliseconds(1)),
            backend: .coreML,
            degradations: [.fellBack(from: .liteRT, to: .coreML)]
        )
        let model = ClassificationModel(engine: FakeEngine(result: degraded))
        await model.classify(try buffer())

        XCTAssertEqual(model.state, .success(degraded: [.fellBack(from: .liteRT, to: .coreML)]))
    }

    // MARK: Failure

    func testALoadFailureEndsInFailedWithTheContractsRetryability() async throws {
        let model = ClassificationModel(engine: FakeEngine(loadError: .modelLoadFailed))
        await model.classify(try buffer())

        // `.modelLoadFailed` is not retryable per `InferenceError.isRetryable`, read from Core
        // rather than re-derived — this asserts the driver did not invent its own mapping.
        XCTAssertEqual(model.state, .failed(retryable: false))
        XCTAssertNil(model.outcome)
    }

    func testAClassifyFailureIsRetryableWhenTheContractSaysSo() async throws {
        let model = ClassificationModel(engine: FakeEngine(classifyError: .inferenceFailed))
        await model.classify(try buffer())

        XCTAssertEqual(model.state, .failed(retryable: true))
    }

    /// A failed run must not leave the previous run's labels on screen underneath the error.
    func testAFailureClearsTheEarlierResult() async throws {
        let engine = FakeEngine()
        let model = ClassificationModel(engine: engine)
        await model.classify(try buffer())
        XCTAssertNotNil(model.outcome)

        let failing = ClassificationModel(engine: FakeEngine(classifyError: .inferenceFailed))
        await failing.classify(try buffer())
        XCTAssertNil(failing.outcome)
    }

    /// An undecodable photo is a failed RUN, not a silent no-op. This is the reason decoding happens
    /// after `.classifyBegan`: reported from `idle`, the machine would refuse the event and the
    /// screen would sit there saying nothing.
    func testAnUndecodablePhotoFailsThroughTheStateMachine() async {
        let engine = FakeEngine()
        let model = ClassificationModel(engine: engine)

        // A zero-sized image cannot produce a buffer.
        await model.classify(photo: UIImage())

        XCTAssertEqual(model.state, .failed(retryable: false))
        XCTAssertNil(model.outcome)
        // The engine was loaded but never asked to classify — the input never got that far.
        let observedClassifyCount = await engine.classifyCount
        XCTAssertEqual(observedClassifyCount, 0)
    }

    // MARK: Retry

    func testRetryRerunsTheSamePhoto() async throws {
        let engine = FakeEngine()
        let model = ClassificationModel(engine: engine)
        await model.classify(try buffer())
        await model.retry()

        let observedClassifyCount = await engine.classifyCount
        XCTAssertEqual(observedClassifyCount, 2)
        // One load for two runs: the second is warm.
        let observedLoadCount = await engine.loadCount
        XCTAssertEqual(observedLoadCount, 1)
    }

    func testRetryDoesNothingBeforeAnyPhoto() async {
        let engine = FakeEngine()
        let model = ClassificationModel(engine: engine)

        XCTAssertFalse(model.canRetry)
        await model.retry()

        XCTAssertEqual(model.state, .idle)
        let observedLoadCount = await engine.loadCount
        XCTAssertEqual(observedLoadCount, 0)
    }

    // MARK: The cold/warm boundary (CLAUDE.md invariant 1, ratified choice (b))

    /// Exactly one cold sample per load, every later run warm. This is the ratified sentence, and it
    /// is asserted as bucket membership rather than as a duration — see the file header.
    func testTheFirstRunAfterALoadIsColdAndEveryLaterRunIsWarm() async throws {
        let model = ClassificationModel(engine: FakeEngine())
        await model.classify(try buffer())
        await model.classify(try buffer())
        await model.classify(try buffer())

        XCTAssertEqual(model.samples.count, 3)
        XCTAssertEqual(model.samples.map(\.isCold), [true, false, false])
    }

    /// Nothing is discarded (ratified choice (c)): three runs produce three samples, cold included.
    func testTheColdRunIsRecordedNotDropped() async throws {
        let model = ClassificationModel(engine: FakeEngine())
        await model.classify(try buffer())
        await model.classify(try buffer())

        XCTAssertEqual(model.samples.count, 2)
        XCTAssertTrue(model.samples[0].isCold)
    }

    /// A cold sample's `total` carries the load; a warm one's does not. Asserted as a RELATION
    /// between the two, which holds on any machine, rather than against a fixed number.
    func testAColdTotalIncludesLoadAndAWarmTotalDoesNot() async throws {
        let model = ClassificationModel(engine: FakeEngine())
        await model.classify(try buffer())
        await model.classify(try buffer())

        let cold = model.samples[0]
        let warm = model.samples[1]
        XCTAssertEqual(warm.total, warm.run.compute)
        XCTAssertGreaterThan(cold.total, cold.run.compute)
    }

    /// A failed load records no sample at all — there was no run to measure.
    func testAFailedLoadRecordsNothing() async throws {
        let model = ClassificationModel(engine: FakeEngine(loadError: .modelLoadFailed))
        await model.classify(try buffer())

        XCTAssertTrue(model.samples.isEmpty)
        XCTAssertNil(model.readout)
    }

    // MARK: The summary seam (ADR-0008)

    func testWithNoSummarizerThereIsNoReadoutAtAll() async throws {
        let model = ClassificationModel(engine: FakeEngine())
        await model.classify(try buffer())

        // Not an empty readout, not a row of dashes: nothing. A number nothing produces is
        // decoration, and the screen draws no latency block when there is none.
        XCTAssertNil(model.readout)
    }

    func testEveryRunHandsTheWholeSampleSetToTheSummarizer() async throws {
        let spy = SummarizerSpy()
        let model = ClassificationModel(
            engine: FakeEngine(),
            latency: LatencySource(device: "Simulator (iPhone17,1)", os: "iOS 26.1") { samples in
                MainActor.assumeIsolated { spy.summarize(samples) }
            }
        )

        await model.classify(try buffer())
        await model.classify(try buffer())

        // The recorder partitions cold from warm itself and is the only thing that may, so the
        // driver hands it everything each time rather than pre-bucketing.
        XCTAssertEqual(spy.receivedCounts, [1, 2])
        XCTAssertEqual(spy.lastSamples.map(\.isCold), [true, false])
    }

    func testTheReadoutCarriesTheDeviceAndOsThatProducedIt() async throws {
        let spy = SummarizerSpy()
        let model = ClassificationModel(
            engine: FakeEngine(),
            latency: LatencySource(device: "Simulator (iPhone17,1)", os: "iOS 26.1") { samples in
                MainActor.assumeIsolated { spy.summarize(samples) }
            }
        )
        await model.classify(try buffer())

        // CLAUDE.md invariant 7: no latency figure exists without the hardware and OS behind it.
        let readout = try XCTUnwrap(model.readout)
        XCTAssertEqual(readout.device, "Simulator (iPhone17,1)")
        XCTAssertEqual(readout.os, "iOS 26.1")
        XCTAssertEqual(readout.summary, SummarizerSpy.fixedSummary)
    }

    /// A summarizer that cannot answer — the recorder throws on empty input — leaves the readout
    /// absent rather than showing a half-built one.
    func testASummarizerReturningNothingLeavesNoReadout() async throws {
        let spy = SummarizerSpy()
        spy.answer = nil
        let model = ClassificationModel(
            engine: FakeEngine(),
            latency: LatencySource(device: "d", os: "iOS 26.1") { samples in
                MainActor.assumeIsolated { spy.summarize(samples) }
            }
        )
        await model.classify(try buffer())

        XCTAssertNil(model.readout)
    }
}
