// The chain's spec: the conformance suite over the CHAIN as one more engine, the walk's hop
// derivation, the on-demand cold report, and the failure semantics — each a sentence from
// ADR-0010, asserted.
//
// The failing-on-cue engine is private and in-file, the `ClassificationModelTests.FakeEngine`
// precedent: the shared `StubEngine` deliberately has no failure switch (it exists to conform),
// and widening it for one consumer would put failure seams in a type every suite-running target
// imports. Healthy legs ARE the shared `StubEngine`.
//
// The remote leg here is that same in-file fake, never the real `RemoteEngine` — this target does
// not import InferlensRemote, because the claim under test is that the chain works over ANY legs
// arriving as `any InferenceEngine`, and a test that named a concrete engine would weaken it. The
// chain WITH the real remote leg is specified from the other side, in InferlensRemoteTests
// (ADR-0013, Decision 6).

import InferlensConformance
import InferlensCore
import InferlensFallback
import XCTest

final class FallbackEngineTests: XCTestCase {
    // MARK: - The chain is one more engine

    /// ADR-0010: "The conformance suite runs over the CHAIN, which passes via its real legs."
    /// The unavailable leg sits last and is never consulted — exactly the shipping shape.
    func testTheChainConformsToTheContractAsOneMoreEngine() async throws {
        let chain = FallbackEngine(legs: [
            .init(engine: StubEngine(answering: .liteRT), backend: .liteRT),
            .init(
                engine: FakeEngine(answering: .remote, loadError: .backendUnavailable),
                backend: .remote
            ),
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

    /// All legs failing to LOAD throws the LAST leg's error — here the remote leg's, so a total
    /// load failure surfaces `.backendUnavailable` (the named cost recorded in ADR-0010).
    func testAllLegsFailingToLoadThrowsTheLastLegsError() async throws {
        let chain = FallbackEngine(legs: [
            .init(
                engine: FakeEngine(answering: .liteRT, loadError: .modelLoadFailed),
                backend: .liteRT
            ),
            .init(
                engine: FakeEngine(answering: .remote, loadError: .backendUnavailable),
                backend: .remote
            ),
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

    // MARK: - Cancellation is not a leg failure (ADR-0014)

    /// The rule the chain owes the contract: a cancelled leg has NOT failed, so the walk stops
    /// instead of stepping down. Without it, a person's new photo would make the chain try every
    /// remaining backend — and the outcome would carry a `.fellBack` hop for a hop that never
    /// happened, putting a fabricated degradation on screen.
    func testACancelledLegStopsTheWalkInsteadOfSteppingDown() async throws {
        let fallbackLeg = FakeEngine(answering: .coreML)
        let chain = FallbackEngine(legs: [
            .init(engine: FakeEngine(answering: .liteRT, classifyError: .cancelled), backend: .liteRT),
            .init(engine: fallbackLeg, backend: .coreML),
        ])
        try await chain.loadModel()

        do {
            _ = try await chain.classify(tinyBuffer())
            XCTFail("a cancelled leg must not be answered around")
        } catch {
            XCTAssertEqual(error, .cancelled, "propagated as itself, never as a walk failure")
        }

        let consulted = await fallbackLeg.classifyCount
        XCTAssertEqual(consulted, 0, "the leg below must never be asked")
    }

    /// The chain's OWN boundary — the checkpoint no engine can hold, because the walk is the thing
    /// being stopped. Cancelled before the walk starts, no leg is consulted at all.
    ///
    /// Structural, not timed: the spin on `Task.yield()` guarantees the chain is entered with
    /// cancellation already observable, so there is no race between `cancel()` and the task starting.
    func testACancelledWalkConsultsNoLegAtAll() async throws {
        let primary = FakeEngine(answering: .liteRT)
        let chain = FallbackEngine(legs: [.init(engine: primary, backend: .liteRT)])
        try await chain.loadModel()

        let task = Task { () async -> Result<InferenceOutcome, InferenceError> in
            while !Task.isCancelled { await Task.yield() }
            do throws(InferenceError) {
                return .success(try await chain.classify(tinyBuffer()))
            } catch {
                return .failure(error)
            }
        }
        task.cancel()

        switch await task.value {
        case .success:
            XCTFail("a cancelled walk must not answer")
        case .failure(let error):
            XCTAssertEqual(error, .cancelled)
        }

        let consulted = await primary.classifyCount
        XCTAssertEqual(consulted, 0)
    }

    /// A cancelled walk leaves the chain exactly as it found it: the leg is not excluded, no hop is
    /// remembered, and the next walk answers from the top with a clean outcome.
    func testACancelledWalkLeavesTheChainUnchanged() async throws {
        let primary = FakeEngine(answering: .liteRT, classifyError: .cancelled)
        let chain = FallbackEngine(legs: [
            .init(engine: primary, backend: .liteRT),
            .init(engine: FakeEngine(answering: .coreML), backend: .coreML),
        ])
        try await chain.loadModel()

        do {
            _ = try await chain.classify(tinyBuffer())
            XCTFail("the cancelled walk must throw")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }

        await primary.setClassifyError(nil)
        let recovered = try await chain.classify(tinyBuffer())
        XCTAssertEqual(recovered.backend, .liteRT, "the leg was never excluded")
        XCTAssertEqual(recovered.degradations, [], "and no hop was fabricated for it")
    }

    // The remote leg's own teeth used to be asserted here, against `RemoteStubEngine`. That type
    // is gone (ADR-0013, Decision 3) and the assertions moved with the leg, to
    // `RemoteEngineTests.testAnUnconfiguredEngineThrowsFromLoadModel` and its `classify` pair —
    // same two claims, now made about the engine that actually ships in that position.
}

// MARK: - The failing-on-cue leg

/// Fails exactly where told to, and can be healed mid-test — the seam the walk tests drive.
/// Private and in-file by the same reasoning as `ClassificationModelTests.FakeEngine`.
private actor FakeEngine: InferenceEngine {
    nonisolated let descriptor: ModelDescriptor = .stub

    private let answering: Backend
    private let loadError: InferenceError?
    private var classifyError: InferenceError?

    /// How many times the walk actually reached this leg. What proves a leg was NOT consulted —
    /// the whole claim of the cancellation tests, which is about a step-down that must not happen.
    private(set) var classifyCount = 0

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
        classifyCount += 1
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
