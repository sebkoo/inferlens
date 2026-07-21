// The chain's spec: the conformance suite over the CHAIN as one more engine, the walk's hop
// derivation, the on-demand cold report, and the failure semantics — each a sentence from
// ADR-0010, asserted.
//
// The failing-on-cue engine is private and in-file, the `ClassificationModelTests.FakeEngine`
// precedent: the shared `StubEngine` deliberately has no failure switch (it exists to conform),
// and widening it for one consumer would put failure seams in a type every suite-running target
// imports. Healthy legs ARE the shared `StubEngine`.

import InferlensConformance
import InferlensCore
import InferlensFallback
import XCTest

final class FallbackEngineTests: XCTestCase {
    // MARK: - The chain is one more engine

    /// ADR-0010: "The conformance suite runs over the CHAIN, which passes via its real legs."
    /// The stub sits last and is never consulted — exactly the shipping shape.
    func testTheChainConformsToTheContractAsOneMoreEngine() async throws {
        let chain = FallbackEngine(legs: [
            .init(engine: StubEngine(answering: .liteRT), backend: .liteRT),
            .init(engine: RemoteStubEngine(), backend: .remote),
        ])
        try await assertConformsToContract(chain)
    }

    /// The one-line-swap claim, as a compile-and-run fact: a bare engine and the chain inhabit
    /// the same `any InferenceEngine` and drive the same call sites.
    func testABareEngineAndTheChainAreInterchangeableBehindTheProtocol() async throws {
        let engines: [any InferenceEngine] = [
            StubEngine(),
            FallbackEngine(legs: [.init(engine: StubEngine(), backend: .coreML)]),
        ]
        for engine in engines {
            try await engine.loadModel()
            let outcome = try await engine.classify(tinyBuffer())
            XCTAssertFalse(outcome.classifications.isEmpty)
        }
    }

    /// `classify` before a successful `loadModel()` is a driver error, refused as the
    /// non-retryable load failure it is — never a guessed walk.
    func testClassifyBeforeLoadIsRefusedAsAModelLoadFailure() async throws {
        let chain = FallbackEngine(legs: [.init(engine: StubEngine(), backend: .coreML)])
        do {
            _ = try await chain.classify(tinyBuffer())
            XCTFail("classify before loadModel must throw")
        } catch {
            XCTAssertEqual(error, .modelLoadFailed)
        }
    }

    // MARK: - The load walk

    /// A leg whose LOAD fails is excluded with a hop, and the hop is on EVERY subsequent
    /// outcome — a load exclusion is permanent for the loaded lifetime, not per-call.
    func testAFailedLoadExcludesTheLegAndTheHopIsOnEverySubsequentOutcome() async throws {
        let chain = FallbackEngine(legs: [
            .init(
                engine: FakeEngine(answering: .liteRT, loadError: .modelLoadFailed),
                backend: .liteRT
            ),
            .init(engine: StubEngine(answering: .coreML), backend: .coreML),
        ])
        try await chain.loadModel()

        for _ in 0..<2 {
            let outcome = try await chain.classify(tinyBuffer())
            XCTAssertEqual(outcome.backend, .coreML)
            XCTAssertEqual(outcome.degradations, [.fellBack(from: .liteRT, to: .coreML)])
            // The fallback loaded during loadModel()'s own walk, inside the driver's bracket —
            // no on-demand load exists for these runs.
            XCTAssertNil(outcome.onDemandLoad)
        }
    }

    /// All legs failing to LOAD throws the LAST leg's error — here the stub's, so a total load
    /// failure surfaces `.backendUnavailable` (the named cost recorded in ADR-0010).
    func testAllLegsFailingToLoadThrowsTheLastLegsError() async throws {
        let chain = FallbackEngine(legs: [
            .init(
                engine: FakeEngine(answering: .liteRT, loadError: .modelLoadFailed),
                backend: .liteRT
            ),
            .init(engine: RemoteStubEngine(), backend: .remote),
        ])
        do {
            try await chain.loadModel()
            XCTFail("a chain whose every leg fails to load must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
    }

    // MARK: - The per-call step-down

    /// A per-call failure walks on: the fallback leg is loaded ON DEMAND, the outcome carries
    /// the adjacent hop AND the emergency load (ADR-0010 Decision 2: a step-down run is the
    /// fallback backend's cold run) — and the next call, with the primary healthy again, is
    /// clean: per-call hops are per-call, and the healed leg answers because it stayed loaded.
    func testAPerCallStepDownReportsTheHopAndTheOnDemandLoadThenHeals() async throws {
        let primary = FakeEngine(answering: .liteRT, classifyError: .inferenceFailed)
        let chain = FallbackEngine(legs: [
            .init(engine: primary, backend: .liteRT),
            .init(engine: StubEngine(answering: .coreML), backend: .coreML),
        ])
        try await chain.loadModel()

        let steppedDown = try await chain.classify(tinyBuffer())
        XCTAssertEqual(steppedDown.backend, .coreML)
        XCTAssertEqual(steppedDown.degradations, [.fellBack(from: .liteRT, to: .coreML)])
        XCTAssertNotNil(steppedDown.onDemandLoad, "the emergency load must be reported")

        await primary.setClassifyError(nil)
        let healed = try await chain.classify(tinyBuffer())
        XCTAssertEqual(healed.backend, .liteRT)
        XCTAssertEqual(healed.degradations, [])
        XCTAssertNil(healed.onDemandLoad)
    }

    /// Hops are the adjacent pairs in walk order — the exact ordinal-ordered shape the ledger's
    /// `run_degradations` rows store (LiteRT -> CoreML, then CoreML -> remote).
    func testHopsAreTheAdjacentPairsInWalkOrder() async throws {
        let chain = FallbackEngine(legs: [
            .init(
                engine: FakeEngine(answering: .liteRT, classifyError: .inferenceFailed),
                backend: .liteRT
            ),
            .init(
                engine: FakeEngine(answering: .coreML, classifyError: .inferenceFailed),
                backend: .coreML
            ),
            .init(engine: StubEngine(answering: .remote), backend: .remote),
        ])
        try await chain.loadModel()

        let outcome = try await chain.classify(tinyBuffer())
        XCTAssertEqual(outcome.backend, .remote)
        XCTAssertEqual(outcome.degradations, [
            .fellBack(from: .liteRT, to: .coreML),
            .fellBack(from: .coreML, to: .remote),
        ])
    }

    /// Every leg failing the CALL throws the LAST leg's error, and — ADR-0010's failure
    /// semantics — the failed walk's hops die with the throw: a later success carries none.
    func testAllLegsFailingTheCallThrowsTheLastErrorAndLeaksNoHops() async throws {
        let primary = FakeEngine(answering: .liteRT, classifyError: .inferenceFailed)
        let chain = FallbackEngine(legs: [
            .init(engine: primary, backend: .liteRT),
            .init(
                engine: FakeEngine(answering: .coreML, classifyError: .outOfMemory),
                backend: .coreML
            ),
        ])
        try await chain.loadModel()

        do {
            _ = try await chain.classify(tinyBuffer())
            XCTFail("a walk with no answering leg must throw")
        } catch {
            XCTAssertEqual(error, .outOfMemory, "the LAST leg's error, not the first")
        }

        await primary.setClassifyError(nil)
        let recovered = try await chain.classify(tinyBuffer())
        XCTAssertEqual(recovered.backend, .liteRT)
        XCTAssertEqual(recovered.degradations, [], "a failed walk's hops must not leak forward")
    }

    // MARK: - The remote stub's teeth

    /// ADR-0010 Decision 1: `loadModel` throws primarily, and `classify` throws as
    /// defense-in-depth — asserted separately, because the chain's walk only ever exercises the
    /// load path.
    func testTheRemoteStubThrowsFromBothEntryPoints() async throws {
        let stub = RemoteStubEngine()
        do {
            try await stub.loadModel()
            XCTFail("the stub's loadModel must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
        do {
            _ = try await stub.classify(tinyBuffer())
            XCTFail("the stub's classify must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
    }
}

// MARK: - The failing-on-cue leg

/// Fails exactly where told to, and can be healed mid-test — the seam the walk tests drive.
/// Private and in-file by the same reasoning as `ClassificationModelTests.FakeEngine`.
private actor FakeEngine: InferenceEngine {
    nonisolated let descriptor: ModelDescriptor = .stub

    private let answering: Backend
    private let loadError: InferenceError?
    private var classifyError: InferenceError?

    init(
        answering: Backend,
        loadError: InferenceError? = nil,
        classifyError: InferenceError? = nil
    ) {
        self.answering = answering
        self.loadError = loadError
        self.classifyError = classifyError
    }

    func setClassifyError(_ error: InferenceError?) {
        classifyError = error
    }

    func loadModel() async throws(InferenceError) {
        if let loadError { throw loadError }
    }

    func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        if let classifyError { throw classifyError }
        return InferenceOutcome(
            classifications: StubEngine.conformingOutputs,
            timing: StubEngine.instantRun,
            backend: answering
        )
    }
}

/// A minimal well-formed buffer: the stub legs ignore content, and the chain never inspects it.
/// Typed throws on purpose — an untyped helper inside a `do` block would widen the chain's
/// `throws(InferenceError)` to `any Error` and break the typed `catch` the tests rely on.
private func tinyBuffer() throws(InferenceError) -> ImageBuffer {
    try ImageBuffer(
        width: 2, height: 2, pixelFormat: .rgba8, bytes: [UInt8](repeating: 0, count: 16)
    )
}
