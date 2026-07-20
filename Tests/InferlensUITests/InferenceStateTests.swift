// The spec for the UI state machine (CLAUDE.md invariant 4).
//
// Two things are being pinned, and the second is the one that matters:
//
//   1. Every legal transition, as exact input -> exact output. Not "it moved" — the precise
//      resulting state, payload included, so a plausible-but-wrong table fails.
//   2. Every REFUSAL, enumerated exhaustively. The refusals are the complement of the table in
//      `applying(_:)`, which is written as a `default: nil`; if the two were only ever described in
//      one place they could drift silently. `testEveryStateEventPairIsAccountedFor` walks the full
//      cross-product of states x events and asserts the outcome of all of them, so adding a legal
//      transition without updating this file fails here rather than shipping.
//
// And one claim that is the whole point of the rung: `testEveryStateIsReachable` proves no case is
// decoration. Each of the five states is produced by an event some driver actually emits. That test
// is what the dropped `warming` case would have failed — nothing in this codebase can emit a
// warm-up signal, because the contract seals warm-up inside `loadModel()`.
//
// No engine, no model file, no simulator capability needed: the machine is a pure function over two
// enums, which is the payoff of the UI module knowing nothing about an engine.

import InferlensCore
import XCTest

@testable import InferlensUI

final class InferenceStateTests: XCTestCase {
    // MARK: - Fixtures

    /// One representative value per state case. `failed` appears in both its retryable and
    /// non-retryable forms because the table must treat them identically — `retryable` is a
    /// rendering fact, and a table that quietly gated on it would pass a one-value-per-case sweep.
    private static let allStates: [InferenceState] = [
        .idle,
        .loadingModel,
        .inferring,
        .success(degraded: []),
        .success(degraded: [.fellBack(from: .liteRT, to: .coreML)]),
        .failed(retryable: true),
        .failed(retryable: false),
    ]

    private static let allEvents: [InferenceEvent] = [
        .modelLoadBegan,
        .classifyBegan,
        .classifySucceeded(degradations: []),
        .classifySucceeded(degradations: [.thermallyThrottled]),
        .failed(.inferenceFailed),
        .failed(.unsupportedInput),
        .reset,
    ]

    // MARK: - The legal transitions, pinned exactly

    func testStartingARunLoadsTheModel() {
        XCTAssertEqual(InferenceState.idle.applying(.modelLoadBegan), .loadingModel)
    }

    func testTheLoadIsFollowedDirectlyByInference() {
        // No state in between. This assertion IS the `warming` correction: if a warm-up state
        // existed and were reachable, this transition would not be `loadingModel -> inferring`.
        XCTAssertEqual(InferenceState.loadingModel.applying(.classifyBegan), .inferring)
    }

    func testACleanResultIsSuccessWithNoDegradations() {
        XCTAssertEqual(
            InferenceState.inferring.applying(.classifySucceeded(degradations: [])),
            .success(degraded: [])
        )
    }

    func testDegradationsTravelIntoTheStateUnmodified() {
        // The claim the ledger has to agree with: the screen carries the same structured reasons
        // the row records, in the same order, not a collapsed boolean. A `Bool` payload would make
        // this test unwritable, which is why the payload is not a `Bool`.
        let reasons: [DegradationReason] = [
            .fellBack(from: .liteRT, to: .coreML),
            .thermallyThrottled,
        ]

        XCTAssertEqual(
            InferenceState.inferring.applying(.classifySucceeded(degradations: reasons)),
            .success(degraded: reasons)
        )
    }

    func testRetryableIsReadFromCoreForEveryErrorCase() {
        // Pins the mapping against Core's own definition, case by case, from BOTH in-flight states.
        // Written as literals rather than `error.isRetryable` on both sides: comparing a value to
        // itself would pass no matter what either side did. If Core reclassifies an error, this
        // fails and the UI's promise of a Retry button is re-decided deliberately.
        let expected: [(InferenceError, Bool)] = [
            (.modelLoadFailed, false),
            (.unsupportedInput, false),
            (.inferenceFailed, true),
            (.outOfMemory, true),
            (.backendUnavailable, true),
        ]

        for (error, retryable) in expected {
            XCTAssertEqual(
                InferenceState.loadingModel.applying(.failed(error)),
                .failed(retryable: retryable),
                "loadingModel + \(error)"
            )
            XCTAssertEqual(
                InferenceState.inferring.applying(.failed(error)),
                .failed(retryable: retryable),
                "inferring + \(error)"
            )
        }
    }

    func testInputChangingMidFlightStaysInferring() {
        // The seam the cancel-on-input-change rung plugs into: the screen shows the same spinner
        // over a new image, so the state does not change. Cancelling the superseded Task is an
        // engine concern, not a UI state.
        XCTAssertEqual(InferenceState.inferring.applying(.classifyBegan), .inferring)
    }

    func testAResolvedRunCanClassifyAgainOrReload() {
        for state in [
            InferenceState.success(degraded: []),
            .success(degraded: [.thermallyThrottled]),
            .failed(retryable: true),
            .failed(retryable: false),
        ] {
            XCTAssertEqual(state.applying(.classifyBegan), .inferring, "\(state) + classifyBegan")
            XCTAssertEqual(state.applying(.modelLoadBegan), .loadingModel, "\(state) + modelLoadBegan")
        }
    }

    func testANonRetryableFailureIsNotATrap() {
        // `retryable: false` means retrying THAT call is pointless, not that the screen is stuck.
        // A different image must still be classifiable, or `.unsupportedInput` would strand the
        // user with nothing but a reset.
        XCTAssertEqual(InferenceState.failed(retryable: false).applying(.classifyBegan), .inferring)
    }

    func testResetIsLegalFromEveryState() {
        for state in Self.allStates {
            XCTAssertEqual(state.applying(.reset), .idle, "\(state) + reset")
        }
    }

    // MARK: - The refusals

    func testResolutionEventsAreRefusedWhenNothingIsInFlight() {
        for state in [InferenceState.idle, .success(degraded: []), .failed(retryable: true)] {
            XCTAssertNil(
                state.applying(.classifySucceeded(degradations: [])),
                "\(state) must refuse a result it never asked for"
            )
            XCTAssertNil(
                state.applying(.failed(.inferenceFailed)),
                "\(state) must refuse a failure from no call"
            )
        }
    }

    func testClassifyingIsRefusedBeforeAnythingIsLoaded() {
        XCTAssertNil(InferenceState.idle.applying(.classifyBegan))
    }

    func testReloadingIsRefusedWhileACallIsInFlight() {
        XCTAssertNil(InferenceState.loadingModel.applying(.modelLoadBegan))
        XCTAssertNil(InferenceState.inferring.applying(.modelLoadBegan))
    }

    func testApplyDiscardsARefusalAndLeavesTheStateUntouched() {
        var state = InferenceState.idle
        state.apply(.classifySucceeded(degradations: [.thermallyThrottled]))
        XCTAssertEqual(state, .idle, "a refused event must not move the machine")

        state.apply(.modelLoadBegan)
        XCTAssertEqual(state, .loadingModel, "a legal event must still move it")
    }

    // MARK: - The whole table, so the two descriptions cannot drift

    func testEveryStateEventPairIsAccountedFor() {
        // The cross-product, asserted as a set of expectations rather than re-deriving the table:
        // a pair missing from `expectations` fails, and a pair whose result changed fails. This is
        // the check that keeps `default: nil` in `applying(_:)` honest.
        var checked = 0

        for state in Self.allStates {
            for event in Self.allEvents {
                let actual = state.applying(event)
                let expected = Self.expectedResult(from: state, on: event)
                XCTAssertEqual(actual, expected, "(\(state)) + (\(event))")
                checked += 1
            }
        }

        XCTAssertEqual(checked, Self.allStates.count * Self.allEvents.count)
        XCTAssertEqual(checked, 49, "the sweep must cover 7 states x 7 events")
    }

    /// The transition table, written a second time and INDEPENDENTLY — as a flat list of the legal
    /// pairs, with everything absent refused. Deliberate duplication: the implementation groups
    /// pairs into `switch` arms with a `default`, so a second description in a different shape is
    /// what makes a drift detectable at all. Two spellings of one table that must agree.
    private static func expectedResult(
        from state: InferenceState,
        on event: InferenceEvent
    ) -> InferenceState? {
        if case .reset = event { return .idle }

        switch state {
        case .idle:
            if case .modelLoadBegan = event { return .loadingModel }
            return nil

        case .loadingModel:
            if case .classifyBegan = event { return .inferring }
            if case .failed(let error) = event { return .failed(retryable: error.isRetryable) }
            return nil

        case .inferring:
            if case .classifyBegan = event { return .inferring }
            if case .classifySucceeded(let degradations) = event {
                return .success(degraded: degradations)
            }
            if case .failed(let error) = event { return .failed(retryable: error.isRetryable) }
            return nil

        case .success, .failed:
            if case .modelLoadBegan = event { return .loadingModel }
            if case .classifyBegan = event { return .inferring }
            return nil
        }
    }

    // MARK: - No case is decoration

    func testEveryStateIsReachable() {
        // The rung's central claim, as a test. Drive the machine from `idle` using only events a
        // driver actually emits, and collect the case tags it passes through. All five must appear.
        //
        // This is the test the removed `warming` case would have failed, and the reason it was
        // removed rather than shipped: no event in `InferenceEvent` can produce it, because the
        // engine contract gives a driver nothing to observe between entering `loadModel()` and it
        // returning warm.
        var reached: Set<String> = []
        var state = InferenceState.idle
        reached.insert(Self.tag(state))

        for event in [
            InferenceEvent.modelLoadBegan,
            .classifyBegan,
            .classifySucceeded(degradations: [.fellBack(from: .liteRT, to: .coreML)]),
            .classifyBegan,
            .failed(.inferenceFailed),
            .reset,
        ] {
            state.apply(event)
            reached.insert(Self.tag(state))
        }

        XCTAssertEqual(
            reached,
            ["idle", "loadingModel", "inferring", "success", "failed"],
            "every case must be entered by a real event, or it is decoration"
        )
    }

    private static func tag(_ state: InferenceState) -> String {
        switch state {
        case .idle: "idle"
        case .loadingModel: "loadingModel"
        case .inferring: "inferring"
        case .success: "success"
        case .failed: "failed"
        }
    }

    // MARK: - Presentation

    func testAFallbackReadsAsWhichEngineAnsweredAndWhichDidNot() {
        // Invariant 3 is about degradation being visible, and "degraded" is not visible enough to
        // act on. The text must name both ends of the fallback the ledger row records.
        let text = DegradationReason.fellBack(from: .liteRT, to: .coreML).displayText

        XCTAssertTrue(text.contains("TensorFlow Lite"), text)
        XCTAssertTrue(text.contains("Core ML"), text)
    }

    func testACleanSuccessIsNotDegraded() {
        XCTAssertFalse(InferenceState.success(degraded: []).isDegraded)
        XCTAssertTrue(InferenceState.success(degraded: [.thermallyThrottled]).isDegraded)
        XCTAssertFalse(InferenceState.failed(retryable: true).isDegraded)
    }
}
