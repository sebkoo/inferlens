// One exported NDJSON line, as this build accepts it.
//
// These types mirror `LedgerExport`'s private DTOs field for field and key for key. The duplication
// is deliberate and is the shape of a published interface: the writer's spec
// (`LedgerExportTests`) pins what is emitted, this pins what is accepted, and an interface exists
// where the two agree. Sharing one type across the boundary would mean `InferlensEval` importing
// `InferlensStore` — SQLite behind a file reader — for no gain a reader of NDJSON can use.
//
// `Decodable` rather than hand-written `as?` casts, because JSON's types and Swift's do not line up
// where it matters: a JSON `true` and a JSON `1` both bridge to `NSNumber`, so `as? Int64` accepts a
// boolean and `as? Bool` accepts a 1. A synthesized decoder rejects both, at the key that is wrong.
//
// What it cannot do on its own is notice a key it was never told about, which is why the key-set
// sweep in `LedgerEval.row(from:at:)` runs first: with no version field in the format (ADR-0015,
// Decision 5), silently ignoring an unknown key is how a reader claims to understand a file written
// by something newer than itself.

import InferlensCore

struct ExportedRow: Decodable {
    let id: Int64
    let recordedAtMs: Int64
    let deviceModel: String
    let osVersion: String
    let modelName: String
    let modelPrecision: String
    let modelInputWidth: Int64
    let modelInputHeight: Int64
    /// The stored token, never decoded into `Backend` — see `LedgerEval`'s header for why a reader
    /// that decoded it would refuse valid files the day a fourth backend shipped.
    let backend: String
    let isCold: Int64
    /// Present exactly when `isCold == 1`; the rule is enforced after decoding, because "absent" is
    /// legal here and a contradiction elsewhere.
    let loadNs: Int64?
    let preprocessNs: Int64
    let inferNs: Int64
    let classifications: [ExportedClassification]
    let degradations: [ExportedDegradation]
    /// Append order, so the LAST element is the current verdict and earlier ones are history — the
    /// read rule `run_signals`' DDL states and the export carries across the boundary.
    let signals: [ExportedSignal]

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAtMs = "recorded_at_ms"
        case deviceModel = "device_model"
        case osVersion = "os_version"
        case modelName = "model_name"
        case modelPrecision = "model_precision"
        case modelInputWidth = "model_input_width"
        case modelInputHeight = "model_input_height"
        case backend
        case isCold = "is_cold"
        case loadNs = "load_ns"
        case preprocessNs = "preprocess_ns"
        case inferNs = "infer_ns"
        case classifications
        case degradations
        case signals
    }

    /// The row, rebuilt as the value type `LatencyRecorder` aggregates.
    ///
    /// This is the whole of the reuse (ADR-0015, Decision 4): the columns carry `is_cold`,
    /// `load_ns`, `preprocess_ns` and `infer_ns`, which is exactly a `LatencySample`, so the eval
    /// hands the recorder its own vocabulary and the ratified statistics run unchanged. Nothing
    /// about the percentile, the cold/warm boundary or the warm-up policy is decided here — this
    /// function only restores the shape the driver had when it recorded the run.
    var latencySample: LatencySample {
        LatencySample(
            load: loadNs.map { LoadTiming.cold(.nanoseconds($0)) } ?? .warm,
            run: RunTiming(preprocess: .nanoseconds(preprocessNs), infer: .nanoseconds(inferNs))
        )
    }

    /// The current verdict for this run, or `nil` if nobody judged it. The read rule, applied.
    var currentVerdict: String? { signals.last?.verdict }
}

struct ExportedClassification: Decodable {
    let ordinal: Int64
    let label: String
    let confidence: Double
}

struct ExportedDegradation: Decodable {
    let ordinal: Int64
    let kind: String
    let fromBackend: String?
    let toBackend: String?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case kind
        case fromBackend = "from_backend"
        case toBackend = "to_backend"
    }
}

struct ExportedSignal: Decodable {
    let id: Int64
    let recordedAtMs: Int64
    let verdict: String

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAtMs = "recorded_at_ms"
        case verdict
    }
}
