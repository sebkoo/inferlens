// The engine-agnostic conformance suite. It runs any `InferenceEngine` through the rung-03
// contract's invariants and throws `ConformanceViolation` on the first breach. It imports only
// InferlensCore — no XCTest (it throws instead of asserting, so it stays framework-free) and no
// engine module (rung 10's Core ML tests and rung 15's LiteRT tests both import this to run the
// same checks). It never names or branches on a concrete engine: a check that needs to know
// which engine it holds belongs in that engine's own tests, not here.
//
// It asserts SHAPE, never latency MAGNITUDE. The steady-state check is a relative ratio (run 1
// vs run 2); the suite must not know that inference "should" take under some fixed wall-clock
// bound — the benchmark at rung 32 owns that magnitude claim, on named hardware, and asserting
// it here would flake on a cold CI runner.

import InferlensCore

/// The reason an engine failed the contract. Each case names the invariant, so a failing test
/// reads as the rule that broke rather than a line number.
public enum ConformanceViolation: Error {
    case classificationsNotSortedByConfidenceDescending([Float])
    case confidenceOutOfRange(Float)
    case backendChangedBetweenRuns
    case notSteadyState(run1: Duration, run2: Duration, allowedRatio: Int)
    case mismatchedBufferDidNotThrow
    case retryabilityMismatch(InferenceError)
}

/// How much slower run 1's compute may be than run 2's before the suite calls `loadModel` a liar.
///
/// Deliberately LOOSE (4×). This runs on real hardware at rungs 10/15, where thermal throttling
/// and scheduler jitter perturb a single warm run; a tight ratio would flake on a cold CI runner
/// until someone deletes the test, and a deleted test catches nothing. 4× still catches the
/// failure it exists for — a lazy-load engine defers model warm-up into the first `classify`,
/// making run 1 many times run 2 (10×+), not 4×. Erred loose on purpose: a missed lazy-load is
/// still caught by the benchmark later; a flaky suite is deleted and catches nothing at all.
let steadyStateMaxRatio = 4

/// Runs one engine through the rung-03 contract. Returns normally iff the engine conformed on
/// this run; otherwise throws the first `ConformanceViolation` found.
public func assertConformsToContract(_ engine: some InferenceEngine) async throws {
    // Construction and taxonomy invariants — independent of the engine's outputs.
    try assertMismatchedBufferThrows()
    try assertRetryabilityIsAsDocumented()

    // Steady-state precondition: load must reach steady speed before returning.
    try await engine.loadModel()
    let image = try conformingImage(for: engine.descriptor)

    let first = try await engine.classify(image)
    try assertOutcomeShape(first)

    let second = try await engine.classify(image)
    try assertOutcomeShape(second)

    // The suite can't know the correct backend, only that it doesn't change across runs.
    guard sameBackend(first.backend, second.backend) else {
        throw ConformanceViolation.backendChangedBetweenRuns
    }

    // Run 1's compute must not be materially slower than run 2's — a relative ratio, never an
    // absolute-time threshold.
    if first.timing.compute > second.timing.compute * steadyStateMaxRatio {
        throw ConformanceViolation.notSteadyState(
            run1: first.timing.compute,
            run2: second.timing.compute,
            allowedRatio: steadyStateMaxRatio
        )
    }
}

// MARK: - Invariants

private func assertOutcomeShape(_ outcome: InferenceOutcome) throws {
    let confidences = outcome.classifications.map(\.confidence)
    guard confidences == confidences.sorted(by: >) else {
        throw ConformanceViolation.classificationsNotSortedByConfidenceDescending(confidences)
    }
    for confidence in confidences where !(0...1).contains(confidence) {
        throw ConformanceViolation.confidenceOutOfRange(confidence)
    }
}

/// A mismatched-byte-count buffer must throw `.unsupportedInput` at construction, so a malformed
/// image never reaches an engine. Enforced at `ImageBuffer.init`, checked here without the engine.
private func assertMismatchedBufferThrows() throws {
    var threwUnsupportedInput = false
    do {
        // 2×2 RGBA needs 16 bytes; 3 is wrong on purpose.
        _ = try ImageBuffer(width: 2, height: 2, pixelFormat: .rgba8, bytes: [0, 0, 0])
    } catch {
        if case .unsupportedInput = error { threwUnsupportedInput = true }
    }
    guard threwUnsupportedInput else { throw ConformanceViolation.mismatchedBufferDidNotThrow }
}

/// `InferenceError.isRetryable` maps as the contract documents — retryable failures are transient
/// (OOM, a failed inference, an unavailable backend); the rest are not.
private func assertRetryabilityIsAsDocumented() throws {
    let documented: [(InferenceError, Bool)] = [
        (.outOfMemory, true),
        (.inferenceFailed, true),
        (.backendUnavailable, true),
        (.modelLoadFailed, false),
        (.unsupportedInput, false),
    ]
    for (error, expected) in documented where error.isRetryable != expected {
        throw ConformanceViolation.retryabilityMismatch(error)
    }
}

// MARK: - Helpers

/// A valid buffer sized to the engine's declared input, so a real engine gets a well-formed image
/// (the stub ignores content). The suite never inspects the labels, only their shape.
private func conformingImage(for descriptor: ModelDescriptor) throws -> ImageBuffer {
    let width = descriptor.inputSize.width
    let height = descriptor.inputSize.height
    let count = width * height * PixelFormat.rgba8.bytesPerPixel
    return try ImageBuffer(
        width: width,
        height: height,
        pixelFormat: .rgba8,
        bytes: [UInt8](repeating: 0, count: count)
    )
}

/// `Backend` is intentionally not `Equatable` in the contract, so compare by pattern-match.
private func sameBackend(_ lhs: Backend, _ rhs: Backend) -> Bool {
    switch (lhs, rhs) {
    case (.coreML, .coreML), (.liteRT, .liteRT), (.remote, .remote): true
    default: false
    }
}
