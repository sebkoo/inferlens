// InferlensConformance — test support, not a shipped module. It is not a package product;
// only test targets depend on it.
//
// StubEngine is a deterministic, in-memory `InferenceEngine` with no model and no framework —
// no Core ML, no TFLite, not even Foundation: only InferlensCore and the standard library. It
// is the first type to implement the contract, and the engine that the engine-agnostic
// `assertConformsToContract` runs against.
//
// It conforms BY CONSTRUCTION: it reports exactly what it was configured with. That is the seam
// the broken-variant suite uses to build the misbehaving instances (unsorted classifications, confidence > 1, a
// run-1-slower-than-run-2 "lazy load"). This file ships only CONFORMING defaults; the broken
// instances belong to that suite.

import InferlensCore

/// A deterministic in-memory engine: same construction → same outputs, no clock, no model.
///
/// An `actor` because the contract is a `Sendable` reference that owns loaded state; here the
/// "state" is trivial (a loaded flag and a call counter), which is why the stub crosses no
/// unsafe boundary and needs no `@unchecked Sendable`.
public actor StubEngine: InferenceEngine {
    /// `nonisolated` so it satisfies the protocol's synchronous getter and a test can read it
    /// without `await` or `loadModel()` — safe because `ModelDescriptor` is a `Sendable` value.
    public nonisolated let descriptor: ModelDescriptor

    private let outputs: [Classification]
    private let steadyRun: RunTiming
    private let firstRun: RunTiming?
    private let answering: Backend
    private let reasons: [DegradationReason]
    private var classifyCount = 0
    private var isLoaded = false

    /// Everything the stub reports is fixed at construction — the seam a test uses to drive a
    /// specific scenario. The defaults are a single conforming outcome.
    ///
    /// - Parameter firstRun: when set, the first `classify` reports it and later calls report
    ///   `run`. The conforming default leaves it `nil` (run 1 == run 2); the broken-variant suite sets it to a
    ///   slower timing to build the lazy-load variant the steady-state check must catch.
    public init(
        descriptor: ModelDescriptor = .stub,
        returning outputs: [Classification] = StubEngine.conformingOutputs,
        run steadyRun: RunTiming = StubEngine.instantRun,
        firstRun: RunTiming? = nil,
        answering: Backend = .coreML,
        degradations: [DegradationReason] = []
    ) {
        self.descriptor = descriptor
        self.outputs = outputs
        self.steadyRun = steadyRun
        self.firstRun = firstRun
        self.answering = answering
        self.reasons = degradations
    }

    /// Nothing to load, so steady-state is reached the instant this returns — the stub honors
    /// the obligation trivially. Whether a *real* engine can (Core ML fusing warm-up into the
    /// first `predict`) is the Core ML engine's question, not this stub's.
    public func loadModel() async throws(InferenceError) {
        isLoaded = true
    }

    /// Reports the configured outcome, ignoring the image so the result is deterministic. The
    /// only per-call variation is the lazy-load seam: with `firstRun` set, run 1's timing
    /// differs from run 2's — a profile the conforming default never produces.
    ///
    /// The cancellation checkpoint is here for the same reason every other invariant is: the stub
    /// conforms BY CONSTRUCTION, so the suite's cancellation checks must be satisfiable by an engine
    /// that does nothing. It also leaves `classifyCount` untouched on the cancelled path, which is
    /// what makes "cancellation is not sticky" observable rather than merely asserted.
    public func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        guard !Task.isCancelled else { throw .cancelled }

        let timing = (classifyCount == 0 ? firstRun : nil) ?? steadyRun
        classifyCount += 1
        return InferenceOutcome(
            classifications: outputs,
            timing: timing,
            backend: answering,
            degradations: reasons
        )
    }
}

public extension StubEngine {
    /// A single conforming outcome: sorted by confidence descending, every confidence in `0...1`.
    static let conformingOutputs: [Classification] = [
        Classification(label: "tabby cat", confidence: 0.82),
        Classification(label: "tiger cat", confidence: 0.11),
        Classification(label: "lynx", confidence: 0.04),
    ]

    /// Fixed, nonzero, clock-free timing: run 1 == run 2 (the steady-state obligation) and
    /// `compute` is measurably greater than zero for the conformance suite's timing axis.
    static let instantRun = RunTiming(preprocess: .milliseconds(1), infer: .milliseconds(2))
}

public extension ModelDescriptor {
    /// A MobileNet-shaped descriptor so the stub can stand in for a real model.
    static let stub = ModelDescriptor(
        name: "stub",
        precision: .fp16,
        inputSize: PixelSize(width: 224, height: 224)
    )
}
