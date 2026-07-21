// The driver: the one object that turns a chosen photo into a state, a result, and a latency sample.
//
// It owns an engine through the PROTOCOL only (`any InferenceEngine`), which is what ADR-0001
// permits this module — Core's value types and the engine protocol, never a concrete engine. It
// therefore has no idea whether Core ML or TensorFlow Lite answers, and it cannot be made to care:
// the app target decides which engine, and this file reads `outcome.backend` to find out
// what actually ran.
//
// It is the emitter the state machine was written for. `InferenceState` documents each event as
// something "a driver" observes — `.modelLoadBegan` immediately before `await engine.loadModel()`,
// `.classifySucceeded` carrying `outcome.degradations` verbatim, `.failed` from the `catch`. Until
// this rung there was no such driver; the events were emitted only by tests. Now there is one, and
// the events are produced by real control flow.
//
// ──────────────────────────────────────────────────────────────────────────────────────────────
// CLAUDE.md INVARIANT 1 — READ BEFORE EDITING. TIMING CODE. HUMAN-REVIEWED.
//
// `classify(_:)` below brackets `await engine.loadModel()` with a `ContinuousClock` and turns the
// result into `LoadTiming.cold`. That is a NEW piece of the measurement path, added with this
// screen, and it is flagged here rather than buried: the whole path is agent-written and human-reviewed, and the
// biasable choices are the maintainer's.
//
// It introduces NO new biasable choice. It implements, unchanged, the two ratified at rung 12 and
// documented at `LatencyRecorder.summarize`:
//   (b) cold/warm boundary — a COLD sample is the first run after a model load, and its `total`
//       carries the load cost. `pendingLoad` holds the measured load until exactly one classify
//       consumes it; every later run on the loaded model is warm. That is the ratified sentence,
//       expressed as a variable.
//   (c) warm-up policy — nothing is discarded. The engine's own throwaway inference happens INSIDE
//       `loadModel()` (the contract requires it: "must not return until the engine can infer at
//       steady-state speed"), so it is inside this bracket, where the ratified policy says the cold
//       cost belongs. There is no discard step here, before or after.
// The percentile definition (a) is not touched, and cannot be: this module cannot compute one.
//
// The bracket's boundary, for review at the diff: the clock starts immediately before the `await`
// and stops immediately after it returns. No image work, no state mutation and no logging is inside
// it. `preprocess` and `infer` are NOT measured here — they arrive already measured, in
// `outcome.timing`, from the engine's own brackets.
// ──────────────────────────────────────────────────────────────────────────────────────────────

import InferlensCore
import Observation
import UIKit

// MARK: - Where a summary comes from

/// The seam through which p50/p95 reaches the screen (ADR-0008).
///
/// `summarize` is supplied by the composition and is satisfied by
/// `{ try? LatencyRecorder().summarize($0) }` — the recorder lives in InferlensBench, which this
/// module must not depend on, so the function crosses the boundary instead of the module.
///
/// `device` and `os` are not optional and are not a convenience: CLAUDE.md invariant 7 says no
/// latency figure exists without the hardware and OS that produced it, so this type makes it
/// impossible to wire up a source of numbers without naming the machine they came from. The
/// composition reads them from `DeviceIdentity.current` in InferlensStore.
public struct LatencySource: Sendable {
    public let device: String
    public let os: String
    public let summarize: @Sendable ([LatencySample]) -> LatencySummary?

    public init(
        device: String,
        os: String,
        summarize: @escaping @Sendable ([LatencySample]) -> LatencySummary?
    ) {
        self.device = device
        self.os = os
        self.summarize = summarize
    }
}

// MARK: - Where a run and its signal land

/// The seam through which a finished run and its thumbs signal reach the ledger — the same
/// dependency inversion as `LatencySource` (ADR-0008): this module cannot import InferlensStore,
/// so the two writes cross the boundary as functions and the composition supplies them over a
/// `RunLedger`.
///
/// `appendRun` is handed what the driver has — the measured sample and the engine's outcome —
/// and returns the id the ledger assigned, or `nil` when the write failed; the composition owns
/// turning those into a full ledger record (adding the device, the clock and the model
/// descriptor). `appendSignal` records a judgement against a previously returned id.
///
/// Both are async and neither throws: a ledger failure must never become a classification failure
/// (invariant 4 — the state machine has no case for it, on purpose), so the sink swallows its own
/// errors the way `FlagCache` does, and the ledger surfaces them in the ledger's terms.
public struct RunSink: Sendable {
    public let appendRun: @Sendable (LatencySample, InferenceOutcome) async -> Int64?
    public let appendSignal: @Sendable (Int64, SignalVerdict) async -> Void

    public init(
        appendRun: @escaping @Sendable (LatencySample, InferenceOutcome) async -> Int64?,
        appendSignal: @escaping @Sendable (Int64, SignalVerdict) async -> Void
    ) {
        self.appendRun = appendRun
        self.appendSignal = appendSignal
    }
}

// MARK: - The driver

/// Drives one engine through the state machine for one photo at a time.
///
/// `@MainActor` because everything it publishes is read by a view on the main actor; the engine it
/// calls is an actor of its own, so the `await` hops off and back. Nothing here is `Sendable`-hostile
/// — `ImageBuffer` in and `InferenceOutcome` out are both Core value types, which is the property
/// the whole contract was arranged around.
@MainActor
@Observable
public final class ClassificationModel {
    // MARK: Published

    /// What the screen draws. Only ever changed by `apply`, so every visible transition goes through
    /// the table in `InferenceState.applying(_:)`.
    public private(set) var state: InferenceState = .idle

    /// The last successful result — labels, timing, and which backend actually answered. `nil` until
    /// one arrives, and cleared when a run fails, so a stale result can never sit under a failure.
    public private(set) var outcome: InferenceOutcome?

    /// p50/p95 over this session's runs, with the device that produced them. `nil` when no
    /// `LatencySource` was injected: a screen with no summarizer shows no latency block at all,
    /// rather than a block reading "—". A number nothing produces is decoration, which is the same
    /// rule invariant 4 applies to states.
    public private(set) var readout: LatencyReadout?

    /// The top three labels: what the screen shows, and what the thumbs-signal rung will record
    /// beside the signal. `prefix(3)` is safe on a shorter list, and the contract already guarantees the
    /// order: `classifications` is sorted by confidence descending, asserted by the conformance suite
    /// against every engine.
    public var topThree: [Classification] {
        Array(outcome?.classifications.prefix(3) ?? [])
    }

    /// The thumb the person gave the current result, or `nil` when they have not given one. An
    /// optimistic echo, not a receipt: it lights the moment of the tap and stays lit even if the
    /// ledger write later fails, because a signal-write failure is a ledger problem surfaced in
    /// the ledger's terms, never a classification failure (invariant 4). Cleared when a new run
    /// starts.
    public private(set) var givenSignal: SignalVerdict?

    /// Whether `retry()` has something to retry with.
    public var canRetry: Bool { lastInput != nil }

    // MARK: Input

    /// What a run was started from. Two cases because the screen picks a photo and a test drives a
    /// buffer, and both have to be re-runnable by `retry()` — holding the ORIGINAL input rather than
    /// the decoded bytes is what lets a retry of an undecodable photo fail the same way twice
    /// instead of silently succeeding on a buffer that was never produced.
    private enum Input {
        case buffer(ImageBuffer)
        case photo(UIImage)

        /// Decode, for the photo case. Throws the same `.unsupportedInput` that `ImageBuffer`'s own
        /// initializer throws — Core already treats input rejection as an `InferenceError` raised
        /// outside an engine call, so this widens nothing.
        func decoded() throws(InferenceError) -> ImageBuffer {
            switch self {
            case .buffer(let buffer): buffer
            case .photo(let photo): try ImageDecoder.buffer(from: photo)
            }
        }
    }

    // MARK: Private

    private let engine: any InferenceEngine
    private let latency: LatencySource?
    private let sink: RunSink?

    /// The in-flight ledger append for the current run, if any. Internal so a test can await it
    /// (the `samples` precedent) and so `signal(_:)` can hand its value to the delivery task.
    private(set) var pendingRunAppend: Task<Int64?, Never>?

    /// The in-flight signal write, if any. Internal for the same reason.
    private(set) var pendingSignalDelivery: Task<Void, Never>?

    /// Every sample this session has produced, in order, cold first. Handed to the summarizer whole
    /// on each run — the recorder partitions them itself, and it is the only thing that may.
    private(set) var samples: [LatencySample] = []

    /// Set the moment a load completes, consumed by the next run that produces a sample.
    /// This IS the cold/warm boundary as ratified — see the invariant-1 block at the top.
    ///
    /// INVARIANT 1 — WHAT HAPPENS TO A `pendingLoad` NOTHING CONSUMES. Stated here because control
    /// flow was deciding it and no comment said so, and a choice a reader has to derive from call
    /// ordering is exactly the buried choice the invariant exists to prevent. Three cases, and the
    /// third is honestly undecided:
    ///
    /// 1. **Loaded but never classified — cannot arise.** A load happens only inside `run(_:)`,
    ///    which always continues to `.classifyBegan` and a classify attempt. There is no API on this
    ///    type that loads without going on to run, so a `pendingLoad` never simply sits unused.
    ///
    /// 2. **A run that fails after the load — RETAINED, deliberately, not discarded.** `record(_:)`
    ///    is reached only on the success path, so a failed decode or a throwing `classify` leaves
    ///    `pendingLoad` set and the NEXT successful run consumes it and is reported cold. That is the
    ///    ratified boundary (b) read exactly as written — "cold is the first run after a load" — the
    ///    first run that produces a *sample*. A failed run produces no sample at all, so it is not a
    ///    run the boundary can attach to, and moving the load cost onto the first real sample is the
    ///    only reading that does not lose it. Retain, never overwrite, never drop.
    ///
    ///    This does not contradict ratified (c), and the distinction has to be written rather than
    ///    assumed: **(c) binds the recorder**, which discards no SAMPLE it is given; `pendingLoad`
    ///    lives in the driver, one level earlier, where the question is which sample a measured load
    ///    is attached to. The driver discards nothing either. One consequence is worth naming: if a
    ///    load succeeds, that run fails, and no later run ever succeeds, the load was measured and
    ///    never reported — not because a policy dropped it, but because no sample exists to carry it.
    ///
    /// 3. **Two loads before any classify — UNDECIDED under overlapping runs, and left that way.**
    ///    A second load cannot follow a successful one (`isLoaded` is never reset), and a FAILED load
    ///    never assigns `pendingLoad` at all — it is assigned only after the `await` returns. So in
    ///    sequential use this is assigned at most once per instance and overwrite is unreachable.
    ///    Under two overlapping `classify` calls it is reachable: both can observe `!isLoaded` before
    ///    either sets it, both load, and the second assignment overwrites the first — so the cold
    ///    sample carries whichever load finished last. `run(_:)` documents itself as not re-entrant
    ///    but **nothing enforces it**, so the ordering, not a decision, picks the number.
    ///
    ///    Recorded as undecided rather than resolved with a plausible-sounding rule. Making it
    ///    decided means serializing runs, which is the cancel-on-input-change rung's subject, and a
    ///    comment claiming a guarantee the code does not make would be worse than this paragraph.
    private var pendingLoad: Duration?

    private var isLoaded = false
    private var lastInput: Input?

    /// - Parameters:
    ///   - engine: the engine to drive. `any InferenceEngine`, never a concrete type — the whole
    ///     reason this module can be tested with no model file and no simulator capability.
    ///   - latency: where p50/p95 come from, and the machine they were measured on. `nil` — the
    ///     default — means the screen shows no latency at all.
    ///   - sink: where a finished run and its thumbs signal land. `nil` — the default — means
    ///     nothing is recorded and the screen offers no thumbs: a control whose tap goes nowhere
    ///     is decoration, the same rule the readout follows.
    public init(
        engine: any InferenceEngine,
        latency: LatencySource? = nil,
        sink: RunSink? = nil
    ) {
        self.engine = engine
        self.latency = latency
        self.sink = sink
    }

    // MARK: - Running

    /// Classify a photo the user picked. The screen's entry point.
    public func classify(photo: UIImage) async {
        await run(.photo(photo))
    }

    /// Classify an already-decoded buffer. What a test drives, and what a caller with bytes already
    /// in hand uses.
    public func classify(_ image: ImageBuffer) async {
        await run(.buffer(image))
    }

    /// Load if needed, then decode, then classify. The whole rung, in one method.
    ///
    /// **Why the decode is INSIDE the run and not before it.** A photo that cannot be decoded is a
    /// failed run and has to show as one — but `.failed` is refused from `idle` (the machine's
    /// premise is that nothing is in flight there), so reporting a decode failure before the run
    /// starts would leave the screen sitting on `idle` with nothing said. Decoding after
    /// `.classifyBegan` puts the failure exactly where the machine can carry it: `.inferring ->
    /// .failed(retryable: false)`, which draws "Trying the same photo again won't help" — the true
    /// sentence for a file that is not an image.
    ///
    /// Deliberately not cancellable and deliberately not re-entrant: cancelling a superseded run when
    /// the input changes is its own ladder rung (`refactor(engine)`), and the state machine already
    /// holds the seam it will plug into (`inferring + classifyBegan -> inferring`). Doing it here
    /// would land two concerns in one commit.
    private func run(_ input: Input) async {
        lastInput = input

        // A new run means a new (future) ledger row: retire the previous run's pending id and its
        // thumb echo NOW, at the start, not on success — otherwise a tap landing while this run
        // is in flight (or after it fails) would file a judgement against the previous run. The
        // retired append task itself keeps running: the previous run still lands in the ledger;
        // only its signalability ends here.
        pendingRunAppend = nil
        givenSignal = nil

        if !isLoaded {
            state.apply(.modelLoadBegan)

            // INVARIANT 1 — the load bracket. See the block at the top of this file. The clock starts
            // immediately before the await and stops immediately after it returns; nothing else is
            // inside it.
            let clock = ContinuousClock()
            let began = clock.now
            do {
                try await engine.loadModel()
            } catch {
                state.apply(.failed(error))
                return
            }
            pendingLoad = clock.now - began

            isLoaded = true
        }

        state.apply(.classifyBegan)
        do {
            // Decoding is inside the run — see the note above. It is NOT inside the measured path:
            // `preprocess` and `infer` are the engine's own brackets, and the engine still owns the
            // model's resize (ADR-0001). See `ImageDecoding.swift` for what this decode bounds.
            let buffer = try input.decoded()
            let result = try await engine.classify(buffer)
            record(result)
            outcome = result
            // The degradations travel verbatim into the state, which is what lets the screen and the
            // ledger row say the same thing about the same run (invariant 3).
            state.apply(.classifySucceeded(degradations: result.degradations))
        } catch {
            // A failed run has no result. Clearing it is what stops the previous photo's labels from
            // sitting on screen underneath an error about this one.
            outcome = nil
            state.apply(.failed(error))
        }
    }

    /// Run the last photo again. Does nothing if there has not been one.
    ///
    /// This is what `InferenceStateView`'s Retry button calls. Retrying a load failure re-enters the
    /// load path, because `isLoaded` is still false — which is the honest behaviour: the thing that
    /// failed is the thing that is retried.
    public func retry() async {
        guard let lastInput else { return }
        await run(lastInput)
    }

    // MARK: - Recording

    /// Turn one finished run into a `LatencySample` and refresh the readout.
    ///
    /// INVARIANT 1: the cold/warm decision here is the ratified boundary (b) and nothing else — a
    /// sample is cold exactly when a load has completed and no run has consumed it yet. Nothing is
    /// discarded (c). The percentiles are computed by the injected summarizer, in InferlensBench,
    /// never here.
    private func record(_ outcome: InferenceOutcome) {
        // INVARIANT 1 — the on-demand precedence (ADR-0010, Decision 2, maintainer-ratified). A
        // step-down's on-demand load IS a load under ratified (b), so an outcome that carries one
        // wins: the step-down run is reported as the answering backend's COLD run, `.cold` built
        // from the outcome's own `Duration` with no unit conversion. `pendingLoad` is cleared on
        // BOTH branches: when the outcome reports its own load, the bracketed load belongs to a
        // leg that did not answer — the failed attempt's wasted time, ADR-0010's one disclosed
        // residue — and attaching it to a later run that paid no load would misreport that run.
        let load: LoadTiming = if let onDemand = outcome.onDemandLoad {
            .cold(onDemand)
        } else {
            pendingLoad.map { .cold($0) } ?? .warm
        }
        pendingLoad = nil
        let sample = LatencySample(load: load, run: outcome.timing)
        samples.append(sample)

        // The ledger append is fire-and-forget BY DESIGN: the state transition never waits on a
        // disk write, and a failed append is a ledger problem surfaced in the ledger's terms —
        // the sink answers `nil` and the run on screen is unaffected (invariant 4: no state).
        // The task handle is kept so a thumbs tap can await the id of the run it judges.
        if let sink {
            pendingRunAppend = Task { await sink.appendRun(sample, outcome) }
        }

        guard let latency, let summary = latency.summarize(samples) else { return }
        readout = LatencyReadout(summary: summary, device: latency.device, os: latency.os)
    }

    // MARK: - The thumbs signal

    /// Record the person's judgement of the current result.
    ///
    /// Never blocks and never fails the UI: the write happens in its own task, against the run id
    /// the pending append produces. The echo (`givenSignal`) is optimistic — see its declaration.
    /// A second tap supersedes: the ledger appends a new row, and its read rule (highest id wins)
    /// makes the later judgement current — the policy recorded at the ledger's schema.
    public func signal(_ verdict: SignalVerdict) {
        // Captured at tap time: if a new run starts before this write lands, the reference here
        // still names the run whose result was on screen when the person tapped — or is nil (no
        // successful run, or no sink), making the tap a no-op. Misfiling a judgement onto a later
        // run is impossible by construction, because `run(_:)` retires the reference at its start.
        guard let pending = pendingRunAppend, let sink else { return }
        givenSignal = verdict
        pendingSignalDelivery = Task {
            guard let runID = await pending.value else { return }
            await sink.appendSignal(runID, verdict)
        }
    }
}

// MARK: - A note on `.reset`, which this driver never emits
//
// `InferenceEvent.reset` returns the machine to `idle` from anywhere, and after this rung it has no
// emitter in the shipped app. That is worth stating rather than leaving to be noticed, because the
// event enum's own documentation forbids exactly this: "an event with no emitter would smuggle back
// exactly the unreachability the `warming` correction removed."
//
// It has none because using it would strand the screen. `idle` means "nothing is loaded" to the
// transition table — `(.idle, .classifyBegan)` is refused — but a driver that has run once has a
// LOADED engine, so a reset would land the machine in a state whose only exit is `.modelLoadBegan`,
// and emitting that would put "Preparing the model" on screen for a load that never happens. The
// alternatives are all worse than having no Clear button: lie about a load, unload a model that is
// fine, or teach the machine a notion of "loaded" it does not have.
//
// So the screen simply has no Clear affordance: choosing another photo runs it, which is legal from
// `success` and from `failed`. Recorded in ROADMAP as a finding against a later rung, in the same
// place the `loadingModel`/`inferring` finding was recorded — the fix is a state-machine change, not
// a screen change, and it is not this rung's to make.
