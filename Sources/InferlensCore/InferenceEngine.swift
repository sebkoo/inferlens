// InferlensCore — the inference contract.
//
// Zero dependencies. There is deliberately no `import` in this file: no Foundation, no
// engine SDK. Durations use the standard library's `Duration`; an image is raw bytes. If a
// type here needed an import, that would be the signal it does not belong in Core.
//
// Every type is a `Sendable` value (a struct or enum over stdlib primitives) except
// `InferenceEngine` itself, which is a `Sendable` reference — each implementation is an
// actor that owns loaded model state. The values that cross that actor boundary
// (`ImageBuffer` in, `InferenceOutcome` out) are already safe, which is the whole premise the
// LiteRT engine leans on: its `TfLiteInterpreter*` handle stays inside the actor and every C
// call is synchronous and on-actor, so it needs no `@unchecked Sendable` at all (ADR-0005).
//
// This is a contract, not an implementation. The engine-agnostic conformance suite checks the
// engine-output invariants against every engine; a construction invariant it never sees
// (an `ImageBuffer`'s byte count) is enforced here, at the initializer, instead.

// MARK: - Engine

/// An on-device inference engine.
///
/// Satisfiable by Core ML and by LiteRT without either leaking its native types, and by the
/// fallback chain — which is itself an `InferenceEngine` composing others.
public protocol InferenceEngine: Sendable {
    /// The model this engine runs. Identifies it in the ledger and gives preprocessing the
    /// expected input size.
    var descriptor: ModelDescriptor { get }

    /// Load the model into memory. Timed by the driver that calls it (`ClassificationModel`
    /// today); the observed duration
    /// becomes a run's `LoadTiming.cold`. A cold start is this call plus the first `classify`.
    ///
    /// Contract obligation: `loadModel()` must not return until the engine can infer at
    /// steady-state speed — it may not defer work to the first `classify`. Core ML does ANE
    /// compilation and warm-up on the first `predict`; an engine that lets that happen inside
    /// `classify` makes `.cold(d)` under-report load and the first `.warm` run not actually
    /// warm, putting the time in the wrong phase of the split. The conformance suite tests it: load,
    /// `classify` twice, assert run 1's `compute` is not materially slower than run 2's.
    func loadModel() async throws(InferenceError)

    /// Run one inference over one image, returning the two phases the engine measured as the
    /// outcome's `RunTiming` (load is not here — the recorder adds it).
    ///
    /// This imposes a real constraint: the engine must OWN its preprocessing, so that a
    /// boundary between `preprocess` and `infer` exists to time. Core ML's `VNCoreMLRequest`
    /// fuses resize/crop/normalize into the prediction, so **the Core ML engine cannot use Vision
    /// — it drives `MLModel` directly.** If that proves wrong, `preprocess` collapses into `infer`
    /// and the README's Cold/Warm table loses a column. Recorded in ADR-0001.
    ///
    /// A result that came back but was degraded (thermal throttling, a fallback) is reported
    /// on the outcome, not thrown; only the *absence* of a result throws.
    ///
    /// Invariants every engine must uphold (the conformance suite tests them against real engines):
    /// - `outcome.classifications` is sorted by `confidence`, descending.
    /// - every `confidence` lies in `0...1`.
    /// - `outcome.backend` names the engine that actually produced the result.
    func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome
}

// MARK: - Input

/// A decoded image handed to an engine. Raw bytes, so Core needs no image framework and no
/// engine's native buffer type (`CVPixelBuffer`, a TFLite tensor) leaks into the contract;
/// each engine converts once, inside its measured `preprocess` phase.
public struct ImageBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: PixelFormat
    /// Row-major pixels.
    public let bytes: [UInt8]

    /// Enforces the byte-count invariant at construction — the conformance suite tests engines,
    /// not buffers, so this is the only place it can be checked. Throws `.unsupportedInput`
    /// (rather than trapping) when `bytes.count != width * height * pixelFormat.bytesPerPixel`.
    public init(
        width: Int,
        height: Int,
        pixelFormat: PixelFormat,
        bytes: [UInt8]
    ) throws(InferenceError) {
        guard width > 0, height > 0,
              bytes.count == width * height * pixelFormat.bytesPerPixel
        else { throw .unsupportedInput }
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.bytes = bytes
    }
}

public enum PixelFormat: Sendable {
    case rgba8
    case bgra8

    /// A `switch`, not a constant `4`: adding a format (`.gray8`, when an engine needs one) must not
    /// silently inherit 4 and corrupt the byte-count invariant — the compiler forces the
    /// decision.
    public var bytesPerPixel: Int {
        switch self {
        case .rgba8, .bgra8: 4
        }
    }
}

// MARK: - Model

/// What a model is, independent of the engine that runs it. Stored as the metadata document
/// in the NoSQL side of the ledger.
public struct ModelDescriptor: Sendable {
    public let name: String
    public let precision: Precision
    /// The input the model expects; preprocessing resizes to this.
    public let inputSize: PixelSize

    public init(name: String, precision: Precision, inputSize: PixelSize) {
        self.name = name
        self.precision = precision
        self.inputSize = inputSize
    }
}

public enum Precision: Sendable {
    case fp32
    case fp16
    case int8
}

public struct PixelSize: Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

// MARK: - Output

/// The result of one inference: what was seen, the two phases the engine measured, which
/// engine answered, and whether the answer was degraded.
public struct InferenceOutcome: Sendable {
    /// Top labels, sorted by `confidence` descending.
    public let classifications: [Classification]
    /// The `preprocess` and `infer` the engine measured. Load is *not* here — the recorder
    /// adds it when it composes a `LatencySample`.
    public let timing: RunTiming
    /// The engine that actually produced this result — may differ from the one requested if
    /// the fallback chain stepped down (recorded in `degradations`).
    public let backend: Backend
    /// Empty when the result was clean; otherwise every reason it was degraded. This list travels
    /// intact to both consumers: the UI's `success(degraded:)` and the ledger's `degradation` rows.
    /// It is deliberately not collapsed to a `Bool` at either end — "something was degraded" cannot
    /// say a LiteRT → Core ML fallback happened, and the ledger stores that structurally (invariant
    /// 3, and CLAUDE.md invariant 4's first correction).
    public let degradations: [DegradationReason]

    /// The load a step-down paid INSIDE this call, or `nil` for every engine that loads only in
    /// `loadModel()` — plain engines never set it; only a composing engine (the fallback chain)
    /// can, when it loaded a fallback leg on demand mid-call. It carries the sample's own unit
    /// (`Duration`, exactly what `LoadTiming.cold` holds), so the driver composes `.cold` from it
    /// with no conversion and the store keeps sole ownership of the nanosecond encoding.
    ///
    /// INVARIANT 1 (ADR-0010, Decision 2, maintainer-ratified): an on-demand load IS a load under
    /// the rung-12 boundary — "cold is the first run after a load" — so the driver gives this
    /// field precedence and records the step-down run as the answering backend's COLD run.
    public let onDemandLoad: Duration?

    public init(
        classifications: [Classification],
        timing: RunTiming,
        backend: Backend,
        degradations: [DegradationReason] = [],
        onDemandLoad: Duration? = nil
    ) {
        self.classifications = classifications
        self.timing = timing
        self.backend = backend
        self.degradations = degradations
        self.onDemandLoad = onDemandLoad
    }

    public var isDegraded: Bool { !degradations.isEmpty }
}

public struct Classification: Sendable {
    /// What the class is called. When an engine has a `LabelTable`, this is the word from it; with
    /// no table (or an index the table cannot map) it is `LabelTable.fallbackLabel(for:)` — the
    /// `"class N"` the LiteRT engine emitted before labels existed.
    public let label: String
    /// A probability in `0...1` (an engine-output invariant the conformance suite asserts).
    public let confidence: Float

    /// The model's own output position for this class, when it is known.
    ///
    /// Optional because the two engines know it by different routes and one of them can genuinely
    /// fail to. LiteRT reads a positional vector, so it always knows. Core ML emits a
    /// label→probability dictionary with no positions in it at all, so its index is recovered by
    /// looking the label up in the same table — which answers `nil` for a label the table does not
    /// hold, and for `"crane"`, which the table holds twice (`LabelTable.index(of:)`).
    ///
    /// It is carried because the index is the model's raw, stable identity for a class where the
    /// word is a rendering of it: two models can phrase a class differently and still mean the same
    /// position. The screen shows it beside the label so a reader can trace a word back to the
    /// output it came from.
    ///
    /// **Not persisted.** The ledger stores `label` and `confidence` and gains no column here, so a
    /// `Classification` read back from a ledger row has `index == nil` even when the one written had
    /// an index. That is a deliberate deferral, not an oversight: the ledger records the fact a
    /// person judged — the word they saw — and adding a column is a schema migration whose caller
    /// does not exist yet. Recorded as a finding in docs/ROADMAP.md against the cross-model
    /// agreement rung, which is the first thing that would want index-keyed comparison.
    public let index: Int?

    public init(label: String, confidence: Float, index: Int? = nil) {
        self.label = label
        self.confidence = confidence
        self.index = index
    }
}

/// `Equatable` because both downstream consumers compare backends as data, not as control flow:
/// the UI's state machine asserts an exact transition result, and the ledger round-trips a
/// `.fellBack(from:to:)` through SQLite text columns and must prove what came back is what went in.
public enum Backend: Sendable, Equatable {
    case coreML
    case liteRT
    case remote
}

/// Why a result was degraded. A result still came back — this is not failure (failure throws
/// `InferenceError`). The fallback chain writes `.fellBack`; the thermal-state mapping writes
/// `.thermallyThrottled`.
public enum DegradationReason: Sendable, Equatable {
    case thermallyThrottled
    case fellBack(from: Backend, to: Backend)
}

// MARK: - Latency

/// What the engine measures for one inference: the two phases it owns. It never sees model
/// load, so it never reports it — no `nil`, no half-filled type.
public struct RunTiming: Sendable {
    public let preprocess: Duration
    public let infer: Duration

    public init(preprocess: Duration, infer: Duration) {
        self.preprocess = preprocess
        self.infer = infer
    }

    public var compute: Duration { preprocess + infer }
}

/// Whether a run paid model-load cost — the cold/warm axis the README's table is built on.
/// `.cold` carries the load `Duration`; `.warm` means the model was already resident. An
/// explicit axis, not an overloaded `nil`: a consumer can always bucket a row.
public enum LoadTiming: Sendable {
    case cold(Duration)
    case warm
}

/// The complete timing of one run, composed by the driver that observed the load, from the engine's
/// `RunTiming` and the load it observed. The engine never constructs this — it can only
/// half-fill it. `make bench`'s JSON emits it; `load`'s cold/warm split feeds the table's Cold
/// and Warm columns.
public struct LatencySample: Sendable {
    public let load: LoadTiming
    public let run: RunTiming

    public init(load: LoadTiming, run: RunTiming) {
        self.load = load
        self.run = run
    }

    /// Total wall time for this run: the load duration when cold, plus preprocess + infer.
    public var total: Duration {
        switch load {
        case .cold(let loadDuration): loadDuration + run.compute
        case .warm: run.compute
        }
    }

    public var isCold: Bool {
        switch load {
        case .cold: true
        case .warm: false
        }
    }
}

// MARK: - Failure

/// The only error an engine throws — no native Core ML or LiteRT error crosses the contract.
/// Typed throws makes that a compiler rule rather than a convention, which is how the
/// protocol stays satisfiable by both engines without either leaking.
public enum InferenceError: Error, Sendable, Equatable {
    case modelLoadFailed
    case unsupportedInput
    case inferenceFailed
    case outOfMemory
    case backendUnavailable

    /// Whether retrying the same call could plausibly succeed. The UI maps this onto
    /// `failed(retryable:)`.
    public var isRetryable: Bool {
        switch self {
        case .outOfMemory, .inferenceFailed, .backendUnavailable: true
        case .modelLoadFailed, .unsupportedInput: false
        }
    }
}
