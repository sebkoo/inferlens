// InferlensFallback — the fallback chain as a VALUE (CLAUDE.md invariant 3).
//
// It held the remote stub too until the remote-leg rung, which moved that leg out to
// InferlensRemote where the engines are and left this module holding the chain alone — a stronger
// version of the claim below, not a weaker one (ADR-0013, Decision 6).
//
// This module depends on InferlensCore ONLY. The chain holds its legs as `any InferenceEngine`
// and never names a concrete engine — which leg wears which `Backend` is the composition's
// claim, passed in as data. Cross-engine work lives above the engines (ADR-0001, Package.swift);
// this is that work.

import InferlensCore

/// A priority-ordered chain of engines that is itself an `InferenceEngine` — the composition
/// swaps a bare engine for the chain in one line, and everything downstream (the driver, the
/// state machine, the ledger) is unchanged.
///
/// The chain is DATA: an array walked in order, never an `if`-ladder. Degradation is derived
/// from the walk — the outcome of a run answered by leg `k` carries one `.fellBack` hop per
/// adjacent pair above it (`legs[i] → legs[i+1]` for every `i < k`), which is exactly the
/// ordinal-ordered shape the ledger's `run_degradations` rows store. A hop records THAT a leg
/// failed, never why.
///
/// Failure semantics (ADR-0010): a walk where every leg fails throws the LAST leg's error;
/// earlier errors are not preserved as values. A failed walk produces no outcome, so its hops
/// die with the throw — they never leak into a later success.
///
/// Concurrency per ADR-0005: the chain owns no C handle and no engine internals; it only awaits
/// other actors. No `@unchecked Sendable` anywhere.
public actor FallbackEngine: InferenceEngine {
    /// One chain entry: an engine and the `Backend` the composition says it answers as. The
    /// backend here names hops (`.fellBack(from:to:)`); the outcome's own `backend` remains the
    /// answering engine's claim, passed through untouched.
    public struct Leg: Sendable {
        public let engine: any InferenceEngine
        public let backend: Backend

        public init(engine: any InferenceEngine, backend: Backend) {
            self.engine = engine
            self.backend = backend
        }
    }

    /// The preferred leg's descriptor, fixed at init — the protocol getter is synchronous and
    /// nonisolated, so it cannot follow the walk. The ledger's model columns must NOT come from
    /// here: the composition picks them per row from `outcome.backend` (ADR-0010, Consequences).
    public nonisolated let descriptor: ModelDescriptor

    private let legs: [Leg]

    /// Which legs hold a loaded model. A loaded leg that fails a CALL stays loaded and is
    /// retried on later calls; loading is never repeated for it.
    private var loaded: [Bool]

    /// Which legs failed a LOAD. Excluded for the chain's loaded lifetime — a per-call walk
    /// skips them without retrying the load. A fresh `loadModel()` walk starts the lifetime
    /// over (the driver calls it again only when nothing is loaded, e.g. retrying a total load
    /// failure — the retry the error's `isRetryable` promises must actually retry something).
    private var loadExcluded: [Bool]

    /// Whether any `loadModel()` walk has succeeded. `classify` before a successful load is a
    /// driver error and throws `.modelLoadFailed` rather than guessing a walk.
    private var isLoaded = false

    /// - Parameter legs: priority order, preferred first. Must be non-empty — a chain of zero
    ///   engines is a composition bug, refused here rather than surfaced as a puzzling throw.
    public init(legs: [Leg]) {
        precondition(!legs.isEmpty, "FallbackEngine requires at least one leg")
        self.legs = legs
        descriptor = legs[0].engine.descriptor
        loaded = Array(repeating: false, count: legs.count)
        loadExcluded = Array(repeating: false, count: legs.count)
    }

    /// Walk to first success (ADR-0010, Decision 2, maintainer-ratified): try legs in priority
    /// order and stop at the first that loads. Legs above the active one are load-excluded for
    /// the chain's loaded lifetime; legs below stay unloaded and untouched, so with a healthy
    /// primary the chain's load cost — what the driver's bracket measures into cold `load_ns` —
    /// is identical to the bare engine's. The contract's steady-state obligation holds through
    /// the leg that loaded: its own `loadModel()` may not return before it can infer at
    /// steady-state speed, and it is the leg that will answer.
    public func loadModel() async throws(InferenceError) {
        loaded = Array(repeating: false, count: legs.count)
        loadExcluded = Array(repeating: false, count: legs.count)
        isLoaded = false

        var lastError = InferenceError.modelLoadFailed
        for index in legs.indices {
            do {
                try await legs[index].engine.loadModel()
                loaded[index] = true
                isLoaded = true
                return
            } catch {
                // No `.cancelled` guard here, deliberately, and the absence is the honest state of
                // things rather than an oversight: the contract's cancellation clause is scoped to
                // `classify` (ADR-0014, Decision 3 — `loadModel`'s bracket is the driver's, so every
                // site inside it is inside a measurement), so no engine can reach this catch with
                // `.cancelled` and a guard for it would be unreachable code claiming a capability.
                // If `loadModel` ever gains the clause, THIS is the site that must gain the guard
                // `classify` has below — a cancelled leg would otherwise be excluded for the chain's
                // whole loaded lifetime for having been interrupted.
                loadExcluded[index] = true
                lastError = error
            }
        }
        throw lastError
    }

    /// Walk from the top, skipping load-excluded legs: a loaded leg is asked to classify; an
    /// unloaded leg is loaded on demand first. The first success answers, its outcome carrying
    /// the walk's hops ahead of the engine's own degradations.
    ///
    /// INVARIANT 1 — ADR-0010, Decision 2, maintainer-ratified. The on-demand load bracketed
    /// below IS a load: rung 12's ratified boundary reads "cold is the first run after a load,
    /// its total carrying the load cost", so the step-down run is recorded as the fallback
    /// backend's COLD run — the outcome reports the emergency load in `onDemandLoad`, the driver
    /// gives it precedence, and the row lands with `is_cold` set and `load_ns` carrying it. No
    /// new column, no unrecorded load. The only unrecorded residue is the FAILED attempt's
    /// wasted time — the work a leg spent before it threw, genuinely unattributable to a row
    /// whose backend is the leg that answered — disclosed in ADR-0010, with the `fellBack` hop
    /// on the row as its marker. The bracket's boundary: the clock starts immediately before the
    /// leg's `loadModel()` await and stops immediately after it returns; nothing else is inside.
    public func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        guard isLoaded else { throw .modelLoadFailed }

        var lastError = InferenceError.backendUnavailable
        for index in legs.indices where !loadExcluded[index] {
            // THE CHAIN'S OWN BOUNDARY (ADR-0014, Decision 3) — the checkpoint no engine can hold,
            // because the walk is the thing being stopped. Top of the iteration, before the
            // on-demand-load clock below starts, so it is outside that bracket the way the engines'
            // entry checkpoints are outside theirs (INVARIANT 1).
            guard !Task.isCancelled else { throw .cancelled }

            var onDemandLoad: Duration?
            if !loaded[index] {
                let clock = ContinuousClock()
                let began = clock.now
                do {
                    try await legs[index].engine.loadModel()
                } catch {
                    loadExcluded[index] = true
                    lastError = error
                    continue
                }
                onDemandLoad = clock.now - began
                loaded[index] = true
            }

            do {
                let outcome = try await legs[index].engine.classify(image)
                return InferenceOutcome(
                    classifications: outcome.classifications,
                    timing: outcome.timing,
                    backend: outcome.backend,
                    degradations: hops(aboveAnsweringIndex: index) + outcome.degradations,
                    onDemandLoad: onDemandLoad ?? outcome.onDemandLoad
                )
            } catch {
                // A CANCELLED LEG HAS NOT FAILED, so it must not produce a step-down (ADR-0014,
                // Decision 3). Without this the chain would answer a person's new photo by trying
                // every remaining backend — and would derive `.fellBack` hops for hops that never
                // happened, putting a fabricated degradation on screen. Propagated immediately, and
                // the leg is left untouched so a later walk still starts from the top.
                if error == .cancelled { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// The walk record, derived rather than accumulated: reaching leg `k` means every leg above
    /// it was load-excluded or failed this walk, so the hops are the adjacent pairs `i → i+1`
    /// for `i < k` — the same order the ledger's ordinals store. Derivation is what makes a
    /// load-time exclusion appear on EVERY subsequent outcome (permanent while excluded) and a
    /// per-call failure appear only on the call it happened in.
    private func hops(aboveAnsweringIndex index: Int) -> [DegradationReason] {
        (0..<index).map { .fellBack(from: legs[$0].backend, to: legs[$0 + 1].backend) }
    }
}
