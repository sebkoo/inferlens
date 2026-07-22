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
//
// ADDED AT THE CANCEL-ON-INPUT-CHANGE RUNG, and flagged here for the same review: `run(_:)` gained
// three `Task.isCancelled` checkpoints. NONE is inside the bracket above — one sits before it opens,
// one after `pendingLoad` has already been assigned from it, one after `classify` has returned. The
// bracket measures exactly what it measured before, to the same two clock reads. Nor does this
// introduce a biasable choice: what a cancelled run does to the record is decided by ratified (b)
// and (c) read unchanged — no sample is created, so the recorder is handed nothing and discards
// nothing; the measured load is retained, so the next real run reports cold carrying it. ADR-0014,
// Decision 3, has the placement table and the site that was REFUSED (between `preprocess` and
// `infer`, where a check could not avoid being measured).
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

    /// The run currently in flight, if any — the whole cancel-on-input-change rung, in one field.
    ///
    /// A new run cancels it and does NOT wait for it. Not waiting is the decision, not an oversight:
    /// cancellation is cooperative (ADR-0005 — an in-flight `TfLiteInterpreterInvoke` has no
    /// suspension point to be interrupted at), so awaiting the superseded run would make the new
    /// photo queue behind a compute nothing can stop. Superseding beats serializing.
    ///
    /// Internal so a test can observe it, the `samples` and `pendingRunAppend` precedent.
    private(set) var inFlightRun: Task<Void, Never>?

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
    ///
    ///    **Correction, at the cancel-on-input-change rung (ADR-0014): the prediction in the
    ///    sentence above is falsified, and case 3 is NARROWED, not closed.** That rung is this one,
    ///    and it does not serialize runs — it SUPERSEDES them. Awaiting a superseded run before
    ///    starting the new one would make a new photo queue behind a compute ADR-0005 makes
    ///    uninterruptible, which is a worse product than the ambiguity it would close. What the
    ///    cancellation does narrow: a superseded run now stops at the checkpoint after the load
    ///    bracket, so reaching an overwrite additionally requires the SUPERSEDED run's load to
    ///    return after the superseding one's. What would actually close it is a shared load task, so
    ///    two overlapping runs cannot both load — a load-deduplication concern, not a cancellation
    ///    one. Recorded as a finding in docs/ROADMAP.md rather than smuggled in here.
    ///
    ///    A fourth case, and it is the one this rung adds: **a run cancelled after its load —
    ///    RETAINED, for case 2's reason exactly.** A cancelled run produces no sample, so the load
    ///    it measured has no run to attach to; but the model IS resident, so the next successful run
    ///    genuinely is "the first run after a load" and is reported cold carrying that cost. That is
    ///    ratified boundary (b) read as written. Discarding it instead would have hidden a load cost
    ///    the next run really did benefit from.
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
        await start(.photo(photo))
    }

    /// Classify an already-decoded buffer. What a test drives, and what a caller with bytes already
    /// in hand uses.
    public func classify(_ image: ImageBuffer) async {
        await start(.buffer(image))
    }

    /// Cancel whatever is in flight, then run this input. The cancel-on-input-change rung, entire.
    ///
    /// The screen already spawns a `Task` per photo selection (`ClassificationScreen`'s
    /// `Task { await choose(item) }`), so two selections genuinely overlap here — this is not a
    /// hypothetical race being pre-empted. The superseded run is cancelled and NOT awaited; see
    /// `inFlightRun`.
    ///
    /// The run is wrapped in its own `Task` rather than awaited directly because a task is the only
    /// thing `cancel()` can be sent to: `run(_:)`'s checkpoints read `Task.isCancelled`, and without
    /// a handle there is nothing to set that flag on. This caller still awaits its OWN run, so
    /// `await model.classify(x)` means what it always meant — the difference is only that the
    /// previous one is told to stop first.
    private func start(_ input: Input) async {
        inFlightRun?.cancel()
        let task = Task { await self.run(input) }
        inFlightRun = task
        await task.value
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
    /// **Cancellable as of ADR-0014, and still not re-entrant.** The rung the previous version of
    /// this comment named ("cancelling a superseded run when the input changes is its own ladder
    /// rung") is this one, and the seam it predicted needing — `inferring + classifyBegan ->
    /// inferring` — was enough: the state machine is unchanged and gained no case (invariant 4, and
    /// ADR-0014's own section on it). A cancelled run is a TRANSITION straight into the next run's
    /// `.inferring`, not a state, because nothing could ever draw a state that is overwritten in the
    /// same turn it is entered.
    ///
    /// Three checkpoints, and each sits where it does for a reason invariant 1 decides (ADR-0014,
    /// Decision 3 has the full table):
    ///
    /// 1. **Before the load bracket opens** — the only site in a run that can stop having paid
    ///    nothing at all. The engines cannot hold this one: `loadModel`'s bracket belongs to THIS
    ///    file, so a checkpoint at an engine's `loadModel` entry would sit inside a measurement.
    /// 2. **After the load bracket closes, before `.classifyBegan`** — the bracket is shut and
    ///    `pendingLoad` assigned, so the measurement is complete and untouched. `pendingLoad` is
    ///    deliberately kept: the model is resident, and the next successful run legitimately reports
    ///    cold carrying it (see the fourth case at `pendingLoad`).
    /// 3. **After `classify` returns, before `record(_:)`** — engines have no post-compute
    ///    checkpoint by contract, so a superseded result arrives here intact and is dropped HERE.
    ///    Being upstream of both the recorder and the ledger is what makes ADR-0014's Decision 1
    ///    true by construction: a cancelled run cannot write a row or become a `LatencySample`
    ///    because it never reaches the code that would do either. There is no filtering step
    ///    anywhere, and invariant 1's ratified (c) is untouched — the recorder discards nothing
    ///    because it is never handed anything.
    ///
    /// A `.cancelled` thrown by the engine is swallowed rather than transitioned: nothing failed, so
    /// `.failed` would be a lie on screen, and `outcome` is left alone so the superseding run owns
    /// what is displayed.
    private func run(_ input: Input) async {
        lastInput = input

        // A new run means a new (future) ledger row: retire the previous run's pending id and its
        // thumb echo NOW, at the start, not on success — otherwise a tap landing while this run
        // is in flight (or after it fails) would file a judgement against the previous run. The
        // retired append task itself keeps running: the previous run still lands in the ledger;
        // only its signalability ends here.
        pendingRunAppend = nil
        givenSignal = nil

        // CHECKPOINT 1 — before anything is spent. Above the load bracket, so it is outside every
        // measurement in this file.
        if Task.isCancelled { return }

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

            // CHECKPOINT 2 — the bracket above is CLOSED (`pendingLoad` is already assigned from
            // it), so nothing here is inside a measurement. `pendingLoad` is kept on purpose: the
            // model really is loaded, so the next run that produces a sample is genuinely the first
            // run after a load and reports cold carrying this cost — ratified boundary (b), read as
            // written.
            if Task.isCancelled { return }
        }

        state.apply(.classifyBegan)
        do {
            // Decoding is inside the run — see the note above. It is NOT inside the measured path:
            // `preprocess` and `infer` are the engine's own brackets, and the engine still owns the
            // model's resize (ADR-0001). See `ImageDecoding.swift` for what this decode bounds.
            let buffer = try input.decoded()
            let result = try await engine.classify(buffer)

            // CHECKPOINT 3 — a result for a photo nobody is looking at any more. The contract
            // promises engines never retroactively cancel a completed compute (ADR-0014, Decision
            // 2), so this result is real and arrives intact; deciding it no longer matters is the
            // caller's job, and this is the caller. Dropped BEFORE `record(_:)`, which is what keeps
            // it out of the recorder and out of the ledger without either of them knowing
            // cancellation exists.
            if Task.isCancelled { return }

            record(result)
            outcome = result
            // The degradations travel verbatim into the state, which is what lets the screen and the
            // ledger row say the same thing about the same run (invariant 3).
            state.apply(.classifySucceeded(degradations: result.degradations))
        } catch {
            // A cancelled run is not a failure and must not be drawn as one: nothing went wrong, and
            // a superseding run is already on its way to `.inferring`. Swallowed with `outcome` left
            // alone — clearing it would blank the screen underneath the new run's spinner for a
            // reason the person would have no way to understand.
            if error == .cancelled { return }

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
        await start(lastInput)
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
