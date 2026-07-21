// The remote leg's spec: the wire contract as it actually crosses a socket, the three failure
// paths, the unconfigured state, and the chain with a REAL remote leg in third position — each a
// sentence from ADR-0013, asserted against the loopback server rather than against a mock.
//
// Every test stands up its own server. Startup is cheap, and a shared instance would let the
// held-open `/slow` connection become the reason some unrelated test flaked.

import InferlensConformance
import InferlensCore
import InferlensFallback
import InferlensRemote
import XCTest

final class RemoteEngineTests: XCTestCase {
    /// 224 * 224 * 3 * 4 — the exact body the contract specifies (ADR-0013, Decision 1). Written
    /// as the arithmetic so a changed input size fails here rather than silently agreeing.
    private static let contractBodyByteCount = 224 * 224 * 3 * 4

    // MARK: - The wire contract

    /// What crosses is what ADR-0013 says crosses, and what comes back is mapped as it says. This
    /// is the only test that inspects the REQUEST — a contract proven only from the response side
    /// is half a contract.
    func testTheWireContractRoundTripsOverARealSocket() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let engine = RemoteEngine(
            endpoint: URL(string: "http://127.0.0.1:\(port)/classify")!,
            labels: LabelTable(["class zero", "class one"] + (2...700).map { "label \($0)" })
        )
        try await engine.loadModel()
        let outcome = try await engine.classify(try Self.image())

        XCTAssertEqual(outcome.backend, .remote)
        XCTAssertEqual(outcome.degradations, [], "answering over the network is not a degradation")
        XCTAssertNil(outcome.onDemandLoad, "a plain engine never sets the chain's channel")

        // The response is mapped through the SAME table shape the other two legs use: index in,
        // word out, index kept beside it.
        XCTAssertEqual(outcome.classifications.count, LoopbackServer.cannedTop.count)
        XCTAssertEqual(outcome.classifications.first?.index, 653)
        XCTAssertEqual(outcome.classifications.first?.confidence, 0.81)
        XCTAssertEqual(outcome.classifications.first?.label, "label 653")

        let recorded = await server.lastRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.path, "/classify")
        XCTAssertEqual(request.contentType, "application/octet-stream")
        XCTAssertEqual(request.inputDescription, "224x224x3;float32;rgb;[-1,1];little-endian")
        XCTAssertEqual(
            request.bodyByteCount, Self.contractBodyByteCount,
            "the client preprocesses and sends the tensor — that is what keeps `preprocess` and "
                + "`infer` separable (ADR-0013, Decision 1)"
        )
    }

    /// Both phases are measured and neither is empty. The bracket's boundary is the claim: request
    /// building is in `preprocess`, the round trip alone is `infer`.
    func testBothTimingPhasesAreMeasured() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let engine = RemoteEngine(endpoint: URL(string: "http://127.0.0.1:\(port)/classify")!)
        try await engine.loadModel()
        let outcome = try await engine.classify(try Self.image())

        XCTAssertGreaterThan(outcome.timing.preprocess, .zero)
        XCTAssertGreaterThan(outcome.timing.infer, .zero)
    }

    /// With no table, every class falls back to `"class N"` — this leg degrades to exactly what
    /// the other two do, which is what makes one vocabulary a claim rather than a coincidence.
    func testWithNoLabelTableTheFallbackIsClassN() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let engine = RemoteEngine(endpoint: URL(string: "http://127.0.0.1:\(port)/classify")!)
        try await engine.loadModel()
        let outcome = try await engine.classify(try Self.image())

        XCTAssertEqual(outcome.classifications.first?.label, "class 653")
    }

    // MARK: - The failure paths, each against a live socket

    /// A REAL timeout: the server accepts, reads the whole body, and never answers. Nothing here
    /// injects an error — URLSession's own `timeoutIntervalForRequest` ends it.
    ///
    /// The elapsed-time assertion is the part that matters. Without it this test would pass
    /// identically if the engine had failed instantly for some unrelated reason, and "the timeout
    /// works" would be a green about the wrong thing — the recurring defect docs/ROADMAP.md names.
    func testATimeoutAgainstALiveSocketThrowsBackendUnavailable() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let timeout = Duration.milliseconds(750)
        let engine = RemoteEngine(
            endpoint: URL(string: "http://127.0.0.1:\(port)/slow")!, timeout: timeout
        )
        try await engine.loadModel()

        let clock = ContinuousClock()
        let began = clock.now
        do {
            _ = try await engine.classify(try Self.image())
            XCTFail("a request the server never answers must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
            XCTAssertTrue(error.isRetryable, "a timeout is transient by definition")
        }
        let elapsed = clock.now - began

        XCTAssertGreaterThanOrEqual(
            elapsed, timeout / 2,
            "it must have WAITED — an instant failure would pass an assertion that only checks "
                + "the error, and would prove nothing about the timeout"
        )
    }

    /// A `500` is a failure, not a degraded success: no result came back, so there is nothing to
    /// carry a reason (ADR-0013, Decision 4).
    func testAServerErrorThrowsBackendUnavailable() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let engine = RemoteEngine(endpoint: URL(string: "http://127.0.0.1:\(port)/boom")!)
        try await engine.loadModel()

        do {
            _ = try await engine.classify(try Self.image())
            XCTFail("a 500 must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
    }

    /// A confidence outside `0...1` is REFUSED, never clamped. Clamping would put a number nobody
    /// produced into the ledger — the same fabrication ADR-0010 banned when it refused a canned
    /// success. This is the assertion behind the "validates rather than repairs" comment at the
    /// code; the comment without this test would be a claim.
    func testAnOutOfRangeConfidenceIsRefusedRatherThanClamped() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let engine = RemoteEngine(endpoint: URL(string: "http://127.0.0.1:\(port)/liar")!)
        try await engine.loadModel()

        do {
            let outcome = try await engine.classify(try Self.image())
            XCTFail("a confidence of \(outcome.classifications.first?.confidence ?? 0) must be refused")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
    }

    /// A connection to a port nothing is listening on. The server is started and stopped so the
    /// port is one the kernel really did hand out, rather than a number guessed to be free.
    func testARefusedConnectionThrowsBackendUnavailable() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        await server.stop()

        let engine = RemoteEngine(
            endpoint: URL(string: "http://127.0.0.1:\(port)/classify")!,
            timeout: .seconds(2)
        )
        try await engine.loadModel()

        do {
            _ = try await engine.classify(try Self.image())
            XCTFail("a connection to a dead port must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
    }

    // MARK: - The unconfigured state (what the shipped app composes)

    /// ADR-0013, Decision 3: with no endpoint the engine is byte-for-byte the stub it replaced —
    /// `loadModel()` throws, because an engine that can never infer must not let load succeed.
    /// This is the test that used to read "the remote stub's teeth".
    func testAnUnconfiguredEngineThrowsFromLoadModel() async throws {
        let engine = RemoteEngine(endpoint: nil)
        do {
            try await engine.loadModel()
            XCTFail("an unconfigured engine's loadModel must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
    }

    /// Defense in depth, exactly as the stub had it: the chain's walk only ever reaches the load
    /// path, so `classify` is asserted separately or not at all.
    func testAnUnconfiguredEngineAlsoRefusesClassify() async throws {
        let engine = RemoteEngine(endpoint: nil)
        do {
            _ = try await engine.classify(try Self.image())
            XCTFail("an unconfigured engine's classify must throw")
        } catch {
            XCTAssertEqual(error, .modelLoadFailed, "classify before a successful load is a driver error")
        }
    }

    // MARK: - The conformance suite, over the engine and over the chain

    /// The claim that separates this rung from the stub: the remote leg passes the SAME
    /// engine-agnostic suite the two on-device engines pass. ADR-0010 said explicitly that the
    /// stub "cannot satisfy the suite and is not claimed to"; this one is run through it.
    ///
    /// Scope, stated because the steady-state ratio is the interesting check here: the fixture
    /// closes each connection (`Connection: close`), so run 2 pays connection setup just as run 1
    /// does. The ratio assertion is therefore not a keep-alive measurement — it confirms this
    /// engine defers no work into the first `classify`, which is true by construction because
    /// there is nothing to load (ADR-0013, Decision 5).
    func testTheRemoteEngineConformsToTheContract() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let engine = RemoteEngine(endpoint: URL(string: "http://127.0.0.1:\(port)/classify")!)
        try await assertConformsToContract(engine)
    }

    /// The shipping shape: the chain with a real remote leg last, never consulted because the
    /// primary is healthy. The suite runs over the chain as one more engine, unchanged.
    func testTheChainConformsWithARealRemoteLegInThirdPosition() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let chain = FallbackEngine(legs: [
            .init(engine: StubEngine(answering: .liteRT), backend: .liteRT),
            .init(engine: StubEngine(answering: .coreML), backend: .coreML),
            .init(
                engine: RemoteEngine(endpoint: URL(string: "http://127.0.0.1:\(port)/classify")!),
                backend: .remote
            ),
        ])
        try await assertConformsToContract(chain)
    }

    /// The leg REACHED, which is the thing a stub could never demonstrate: both on-device legs
    /// fail to load, the walk steps down twice, and a real network round trip answers — carrying
    /// both adjacent hops in the ordinal order the ledger's `run_degradations` rows store.
    func testAChainThatWalksAllTheWayDownIsAnsweredOverTheNetwork() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let chain = FallbackEngine(legs: [
            .init(engine: UnloadableEngine(), backend: .liteRT),
            .init(engine: UnloadableEngine(), backend: .coreML),
            .init(
                engine: RemoteEngine(endpoint: URL(string: "http://127.0.0.1:\(port)/classify")!),
                backend: .remote
            ),
        ])
        try await chain.loadModel()

        let outcome = try await chain.classify(try Self.image())
        XCTAssertEqual(outcome.backend, .remote)
        XCTAssertEqual(outcome.degradations, [
            .fellBack(from: .liteRT, to: .coreML),
            .fellBack(from: .coreML, to: .remote),
        ])
        XCTAssertFalse(outcome.classifications.isEmpty)
    }

    /// The shipped composition's failure story, unchanged by this rung (ADR-0013, Decision 3):
    /// with the remote leg unconfigured, a chain whose every leg fails still throws the LAST leg's
    /// error — `.backendUnavailable`, retryable — exactly as it did with the stub.
    func testAnUnconfiguredRemoteLegLeavesTheChainsFailureStoryUnchanged() async throws {
        let chain = FallbackEngine(legs: [
            .init(engine: UnloadableEngine(), backend: .liteRT),
            .init(engine: RemoteEngine(endpoint: nil), backend: .remote),
        ])
        do {
            try await chain.loadModel()
            XCTFail("a chain whose every leg fails to load must throw")
        } catch {
            XCTAssertEqual(error, .backendUnavailable)
        }
    }

    // MARK: - Helpers

    /// A well-formed buffer at the contract's input size. Content is irrelevant — the fixture
    /// never looks at the tensor, and this suite asserts shape, never accuracy.
    private static func image() throws(InferenceError) -> ImageBuffer {
        try ImageBuffer(
            width: 224,
            height: 224,
            pixelFormat: .rgba8,
            bytes: [UInt8](repeating: 0, count: 224 * 224 * 4)
        )
    }
}

/// A leg that cannot load — the walk's cue, private and in-file by the same reasoning as
/// `FallbackEngineTests.FakeEngine`: the shared `StubEngine` deliberately has no failure switch.
private struct UnloadableEngine: InferenceEngine {
    let descriptor: ModelDescriptor = .stub

    func loadModel() async throws(InferenceError) {
        throw .modelLoadFailed
    }

    func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        throw .modelLoadFailed
    }
}
