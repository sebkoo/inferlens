// The engine-agnostic conformance suite. It runs any `InferenceEngine` through the
// contract's invariants and throws `ConformanceViolation` on the first breach. It imports only
// InferlensCore — no XCTest (it throws instead of asserting, so it stays framework-free) and no
// engine module (the Core ML and LiteRT test targets both import this to run the
// same checks). It never names or branches on a concrete engine: a check that needs to know
// which engine it holds belongs in that engine's own tests, not here.
//
// It asserts SHAPE, never latency MAGNITUDE. The steady-state check is a relative ratio (run 1
// vs run 2); the suite must not know that inference "should" take under some fixed wall-clock
// bound — the on-device benchmark owns that magnitude claim, on named hardware, and asserting
// it here would flake on a cold CI runner.
//
// The cancellation checks (ADR-0014) hold to the same rule harder: they read no clock at all, so
// unlike the steady-state ratio they need no CI scoping and never will. See the block above them.

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
    case cancelledClassifyReturnedAnOutcome
    case cancelledClassifyThrewTheWrongError(InferenceError)
    case cancellationWasSticky(InferenceError)
}

/// How much slower run 1's compute may be than run 2's before the suite calls `loadModel` a liar.
///
/// Deliberately LOOSE (4×). This runs on real hardware at rungs 10/15, where thermal throttling
/// and scheduler jitter perturb a single warm run; a tight ratio would flake on a cold CI runner
/// until someone deletes the test, and a deleted test catches nothing. 4× still catches the
/// failure it exists for — a lazy-load engine defers model warm-up into the first `classify`,
/// making run 1 many times run 2 (10×+), not 4×. Erred loose on purpose: a missed lazy-load is
/// still caught by the benchmark later; a flaky suite is deleted and catches nothing at all.
///
/// Even 4× proved too tight on shared, virtualized CI hardware (rung 31: a macos-26 runner measured
/// run 1 at 10.3× run 2 for Core ML — the first classify paid a model-compile cost the sim's lack of an
/// ANE does not remove). The resolution is SCOPE, not a wider number: the per-engine
/// `…SteadyStateTiming` tests pass `checkSteadyState: false` on CI and XCTSkip with the measured ratio,
/// so this value is untouched everywhere it actually runs (local pinned sim, and devices) — no
/// re-ratification (invariant 1).
let steadyStateMaxRatio = 4

/// Runs one engine through the contract. Returns the measured steady-state ratio (run 1's compute ÷
/// run 2's); throws the first `ConformanceViolation` found. `checkSteadyState` (default `true`) governs
/// ONLY whether a 4× breach THROWS — the ratio is always measured and returned. A caller on shared,
/// virtualized hardware (CI) passes `false` to scope OUT the timing gate while still exercising every
/// shape check; `steadyStateMaxRatio` is unchanged, so no biasable choice is re-ratified (invariant 1).
/// The per-engine `…SteadyStateTiming` tests own that decision and log the returned ratio when they skip.
@discardableResult
public func assertConformsToContract(
    _ engine: some InferenceEngine,
    checkSteadyState: Bool = true
) async throws -> Double {
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

    // The cancellation obligation. Structural, never timed — see the two functions below.
    try await assertCancelledBeforeComputeThrows(engine, image)
    try await assertCancellationIsNotSticky(engine, image)

    // The suite can't know the correct backend, only that it doesn't change across runs.
    // `==` because `Backend` IS `Equatable` in the contract — its doc names the two consumers
    // that compare backends as data. An earlier comment here claimed the opposite; it was
    // falsified when the contract gained the conformance, and a pattern-match helper survived it.
    guard first.backend == second.backend else {
        throw ConformanceViolation.backendChangedBetweenRuns
    }

    // Run 1's compute must not be materially slower than run 2's — a relative ratio, never an
    // absolute-time threshold. The ratio is measured unconditionally (a caller may log it); the THROW
    // is what `checkSteadyState` gates. The comparison stays in Duration space, exact; the returned
    // Double is for a human-readable message only.
    let secondSeconds = seconds(second.timing.compute)
    let ratio = secondSeconds > 0 ? seconds(first.timing.compute) / secondSeconds : 1
    if checkSteadyState, first.timing.compute > second.timing.compute * steadyStateMaxRatio {
        throw ConformanceViolation.notSteadyState(
            run1: first.timing.compute,
            run2: second.timing.compute,
            allowedRatio: steadyStateMaxRatio
        )
    }
    return ratio
}

/// `Duration` → seconds as a `Double`, for the steady-state ratio's message only (the gate itself
/// compares in exact Duration space above). `components` is `(seconds, attoseconds)`.
private func seconds(_ duration: Duration) -> Double {
    let (whole, attoseconds) = duration.components
    return Double(whole) + Double(attoseconds) * 1e-18
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

// MARK: - The cancellation obligation (ADR-0014, Decision 2)
//
// STRUCTURAL, NEVER TIMED. Neither check below reads a clock, a duration or a wall-time bound, so
// both return the same verdict on a pinned local simulator and on a shared, virtualized CI runner.
// That shape is the rung-31 lesson applied before the fact rather than after it: a single-run timing
// judgement on shared hardware is weather, and `steadyStateMaxRatio` already had to be scoped out of
// CI for exactly that reason. These do not need scoping and never will.
//
// WHAT THEY DO NOT READ. They cannot prove an engine refrains from abandoning a compute that has
// already finished — the other half of the contract's clause. Pinning that would mean cancelling a
// task at one exact instant, which is a timing race and would be the `steadyStateMaxRatio` mistake in
// a new costume. That half is enforced by construction instead: no engine has a checkpoint after its
// compute (ADR-0014, Decision 3), so there is no site at which one could break it. What B pins is the
// observable consequence — a cancelled attempt leaves nothing behind on the engine.

/// A `classify` entered inside an already-cancelled task must throw `.cancelled` and return no
/// outcome.
///
/// The spin on `Task.yield()` is what makes this deterministic rather than a race: the engine is not
/// called until this task has observed its own cancellation, so there is no window in which
/// `classify` could start before `cancel()` lands and legitimately return a result. No sleep, no
/// deadline, no clock.
private func assertCancelledBeforeComputeThrows(
    _ engine: some InferenceEngine,
    _ image: ImageBuffer
) async throws {
    let task = Task { () async -> Result<InferenceOutcome, InferenceError> in
        while !Task.isCancelled { await Task.yield() }
        // `do throws(InferenceError)`, spelled out: through a generic `some InferenceEngine` the
        // compiler does not infer the typed throw, and an untyped catch would widen `error` to
        // `any Error` and lose the very case being asserted.
        do throws(InferenceError) {
            return .success(try await engine.classify(image))
        } catch {
            return .failure(error)
        }
    }
    task.cancel()

    switch await task.value {
    case .success:
        throw ConformanceViolation.cancelledClassifyReturnedAnOutcome
    case .failure(.cancelled):
        break
    case .failure(let error):
        throw ConformanceViolation.cancelledClassifyThrewTheWrongError(error)
    }
}

/// Cancellation is per-call, not a mode the engine enters: after a cancelled attempt, the SAME
/// engine instance must still answer an uncancelled `classify` with a conforming outcome.
///
/// This runs immediately after the check above, on the same engine, which is what gives it its
/// teeth — an engine that latched a cancelled flag, left a half-written tensor, or dropped its
/// loaded state fails here rather than silently in an app.
private func assertCancellationIsNotSticky(
    _ engine: some InferenceEngine,
    _ image: ImageBuffer
) async throws {
    let outcome: InferenceOutcome
    do throws(InferenceError) {
        outcome = try await engine.classify(image)
    } catch {
        throw ConformanceViolation.cancellationWasSticky(error)
    }
    // Outside the `do` on purpose: a shape violation must surface as itself, not be relabelled as a
    // stickiness violation by a catch that was only meant to see the engine's error.
    try assertOutcomeShape(outcome)
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
        (.cancelled, true),
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
