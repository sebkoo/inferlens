// The values that cross the ledger's boundary, in and out, plus the only error type that does.
//
// Everything here is a `Sendable` value type over Core's vocabulary. Nothing in this file touches
// SQLite; the mapping from these values to columns lives in `LedgerCodec.swift`, so a reader can
// see WHAT is recorded here and HOW it is stored there without the two being tangled.

import Foundation
import InferlensCore

// MARK: - Where the run happened (CLAUDE.md invariant 7)

/// The hardware and OS a run was measured on.
///
/// Invariant 7 — "every number carries its device + iOS version" — is why this is a required part
/// of every ledger row rather than something a later export tries to reconstruct. A latency without
/// the phone and OS that produced it is not a number anyone can defend, so the ledger refuses to
/// store one: both fields are `NOT NULL` **and** non-empty by `CHECK` constraint in the schema, not
/// by convention (see `LedgerSchema`).
public struct DeviceIdentity: Sendable, Equatable {
    /// The hardware identifier, e.g. `iPhone17,1`. On the simulator this is prefixed (see
    /// `.current`) so a simulator run can never be mistaken for a device run in the table.
    public let model: String
    /// The OS version that ran it, e.g. `iOS 26.1`.
    public let osVersion: String

    public init(model: String, osVersion: String) {
        self.model = model
        self.osVersion = osVersion
    }

    /// The identity of the machine this code is running on.
    ///
    /// The simulator is labelled as such, deliberately. `uname` on a simulator reports the HOST
    /// architecture (`arm64`), and `SIMULATOR_MODEL_IDENTIFIER` names the device being simulated —
    /// so an unprefixed read would let a simulator row claim to be an iPhone 17 Pro. The
    /// README's latency table takes device numbers only; mislabelling here would poison it at the
    /// source, which is exactly what invariant 7 exists to prevent.
    public static var current: DeviceIdentity {
        let environment = ProcessInfo.processInfo.environment
        let model: String
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"] {
            model = "Simulator (\(simulated))"
        } else {
            model = machineIdentifier()
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = version.patchVersion == 0
            ? "iOS \(version.majorVersion).\(version.minorVersion)"
            : "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        return DeviceIdentity(model: model, osVersion: osVersion)
    }

    /// `utsname.machine` as a String. The `machine` field is a fixed-size C char tuple, so it is
    /// rebound rather than read field by field.
    private static func machineIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        // Copied to a local first: taking a pointer to `info.machine` while `info` is still the
        // inout target is an overlapping-access error under exclusivity checking.
        let machine = info.machine
        return withUnsafePointer(to: machine) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout.size(ofValue: machine)
            ) { String(cString: $0) }
        }
    }
}

// MARK: - What one run records

/// One inference, as it is appended to the ledger. The caller composes it from what it already has:
/// the engine's `InferenceOutcome`, the `LatencySample` the recorder assembled, and the device.
///
/// Every field is here because a later question needs it:
/// - `device` — invariant 7; without it no latency in this row can be quoted.
/// - `recordedAt` — orders runs in wall-clock terms across sessions and app launches, which the
///   monotonic row id alone cannot do. Caller-supplied so a test can pin it.
/// - `model` — the ledger compares engines *and* models; a row that names only the backend cannot
///   tell an engine change from a model swap. Precision travels with it because the two models are
///   deliberately at different native precisions (ADR-0003), which is the first thing anyone reading
///   a latency gap will ask about. The input size is what preprocessing actually resized to.
/// - `backend` — the engine that ACTUALLY answered, per the contract's own wording. With
///   `degradations` below, this is how a fallback is legible after the fact (invariant 3).
/// - `sample` — the cold/warm axis plus the preprocess/infer split: the whole measured quantity.
/// - `classifications` — the outcome. Without it the ledger records speed but not correctness, and
///   the thumbs signal (a later rung) would have nothing to be a signal *about*.
/// - `degradations` — invariant 3: degradation is surfaced, never silent. It has to survive into the
///   ledger or "the run fell back" is a UI detail that vanishes the moment the screen redraws.
public struct RunRecord: Sendable {
    public let device: DeviceIdentity
    public let recordedAt: Date
    public let model: ModelDescriptor
    public let backend: Backend
    public let sample: LatencySample
    /// The classifications to record, in the order given. The ledger stores exactly what it is
    /// handed and truncates NOTHING: an engine returns the full score vector (1001 classes for
    /// MobileNetV2), and picking a top-K is the caller's policy — the UI's top-3, the eval's top-5.
    /// A silent truncation inside the ledger would make the exported row a different claim from the
    /// run it describes.
    public let classifications: [Classification]
    public let degradations: [DegradationReason]

    public init(
        device: DeviceIdentity,
        recordedAt: Date,
        model: ModelDescriptor,
        backend: Backend,
        sample: LatencySample,
        classifications: [Classification],
        degradations: [DegradationReason] = []
    ) {
        self.device = device
        self.recordedAt = recordedAt
        self.model = model
        self.backend = backend
        self.sample = sample
        self.classifications = classifications
        self.degradations = degradations
    }
}

extension RunRecord {
    /// The composition's one-liner: a record from what the `RunSink` closure is handed — the
    /// engine's outcome and the driver's measured sample — plus the three facts the composition
    /// owns (the model descriptor, the device, the clock). Field-for-field delegation, so the
    /// outcome travels VERBATIM: the full classification vector in the engine's order, never a
    /// top-K, and every degradation (invariant 3) — nothing is summarized on the way to the row.
    public init(
        outcome: InferenceOutcome,
        sample: LatencySample,
        model: ModelDescriptor,
        device: DeviceIdentity,
        recordedAt: Date
    ) {
        self.init(
            device: device,
            recordedAt: recordedAt,
            model: model,
            backend: outcome.backend,
            sample: sample,
            classifications: outcome.classifications,
            degradations: outcome.degradations
        )
    }
}

/// A run read back out of the ledger: the record plus the id the database assigned it.
///
/// The id is monotonic and is the append order — the ledger's own sequence, independent of
/// `recordedAt`, which is a clock and can jump.
public struct LedgerRun: Sendable {
    public let id: Int64
    public let record: RunRecord

    public init(id: Int64, record: RunRecord) {
        self.id = id
        self.record = record
    }
}

// MARK: - What one signal records

/// A thumbs signal read back out of the ledger: the judgement, the run it judges, and the id the
/// database assigned it.
///
/// The id is data, not plumbing. Signals are append-only and a run may carry several; the schema's
/// read rule (recorded at `run_signals`' DDL) says the HIGHEST id is the current verdict and the
/// earlier rows are its history. Carrying the id is what lets a caller apply that rule instead of
/// trusting an array order it did not produce.
public struct RunSignal: Sendable, Equatable {
    public let id: Int64
    public let runID: Int64
    public let recordedAt: Date
    public let verdict: SignalVerdict

    public init(id: Int64, runID: Int64, recordedAt: Date, verdict: SignalVerdict) {
        self.id = id
        self.runID = runID
        self.recordedAt = recordedAt
        self.verdict = verdict
    }
}

// MARK: - Failure

/// The only error this module throws. No `sqlite3` result code crosses the boundary — the same rule
/// `InferenceError` imposes on the engines, for the same reason: a caller should be able to handle
/// every failure without linking or understanding SQLite.
///
/// Each case is a distinct thing a caller might do differently; result codes that mean the same
/// thing to a caller collapse into one case rather than being passed through for detail's sake.
public enum LedgerError: Error, Sendable, Equatable {
    /// The database file could not be opened or configured (bad path, unreadable directory, a
    /// pragma the connection refused).
    case cannotOpen
    /// A migration failed and was rolled back; the file is still at its previous version.
    case migrationFailed(toVersion: Int)
    /// A call arrived before `open()` succeeded. Not a trap — the same shape as an engine's
    /// `classify` before `loadModel`.
    case notOpen
    /// The file's `user_version` is newer than this build knows how to read. Refused rather than
    /// guessed at: a newer schema may have moved a column this build would silently misread.
    case schemaTooNew(fileVersion: Int, supportedVersion: Int)
    /// The append did not commit; nothing was written. Covers a rejected constraint — including the
    /// append-only triggers — and any step/bind failure inside the transaction.
    case appendFailed
    /// A read could not be executed.
    case readFailed
    /// A row was read but could not be mapped back to Core's value types — an unrecognized backend
    /// or precision string, or a `NULL` where the schema promises a value. Distinct from
    /// `readFailed` on purpose: the query worked and the data is wrong, which is a different bug.
    case unreadableRow
    /// The file's `user_version` is not the version this build exports. A read-only export cannot
    /// migrate, so a file behind this build is as unreadable as one ahead of it — both are refused
    /// naming both sides. The app's own ledger is always migrated by `open()` before an export can
    /// be asked of it, so a mismatch means the file came from a different build's world.
    case exportVersionMismatch(fileVersion: Int, requiredVersion: Int)
    /// The NDJSON destination could not be created or written. Says nothing about the ledger: the
    /// database was fine, and the disk the export was headed to was not.
    case exportWriteFailed
}
