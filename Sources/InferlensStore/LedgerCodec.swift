// Core's value types <-> the schema's column values.
//
// Kept apart from both the schema and the actor so the mapping is one readable thing. Two rules
// hold throughout:
//
//   - Every encode is an EXHAUSTIVE `switch` with no `default`. Adding a `Backend`, a `Precision`,
//     or a `DegradationReason` in Core must break this file at compile time and force a decision
//     about how it is stored — a `default` here would silently write the wrong string into an
//     append-only ledger, which is the one place a mistake cannot be corrected in place.
//   - Every decode is total: an unrecognized string is `LedgerError.unreadableRow`, never a
//     guessed-at fallback case. The stored token is the contract; if it does not match, the row is
//     wrong and saying so is the honest outcome.
//
// The tokens are the Swift case names. They are a STORED FORMAT: renaming a case in Core does not
// license renaming a token here, because rows already written carry the old one. A rename would be
// a migration, not an edit.

import Foundation
import InferlensCore

enum LedgerCodec {

    // MARK: - Backend

    static func encode(_ backend: Backend) -> String {
        switch backend {
        case .coreML: "coreML"
        case .liteRT: "liteRT"
        case .remote: "remote"
        }
    }

    static func decodeBackend(_ token: String?) throws(LedgerError) -> Backend {
        switch token {
        case "coreML": .coreML
        case "liteRT": .liteRT
        case "remote": .remote
        default: throw .unreadableRow
        }
    }

    // MARK: - Precision

    static func encode(_ precision: Precision) -> String {
        switch precision {
        case .fp32: "fp32"
        case .fp16: "fp16"
        case .int8: "int8"
        }
    }

    static func decodePrecision(_ token: String?) throws(LedgerError) -> Precision {
        switch token {
        case "fp32": .fp32
        case "fp16": .fp16
        case "int8": .int8
        default: throw .unreadableRow
        }
    }

    // MARK: - Degradation

    /// A degradation as the three columns `run_degradations` holds. The backend pair is present
    /// exactly for `.fellBack`, which the table's CHECK constraint also enforces — so the shape of
    /// the enum and the shape of the row cannot drift apart.
    static func encode(
        _ reason: DegradationReason
    ) -> (kind: String, from: String?, to: String?) {
        switch reason {
        case .thermallyThrottled:
            ("thermallyThrottled", nil, nil)
        case .fellBack(let from, let to):
            ("fellBack", encode(from), encode(to))
        }
    }

    static func decodeDegradation(
        kind: String?,
        from: String?,
        to: String?
    ) throws(LedgerError) -> DegradationReason {
        switch kind {
        case "thermallyThrottled":
            // A stored backend pair on a non-fallback row is a contradiction the CHECK constraint
            // should have refused; if one is present the row was not written by this codec.
            guard from == nil, to == nil else { throw .unreadableRow }
            return .thermallyThrottled
        case "fellBack":
            let fromBackend = try decodeBackend(from)
            let toBackend = try decodeBackend(to)
            return .fellBack(from: fromBackend, to: toBackend)
        default:
            throw .unreadableRow
        }
    }

    // MARK: - Duration

    /// `Duration` -> whole nanoseconds. Saturating rather than trapping: a ledger append must not
    /// crash the app on an absurd input value, and Int64 nanoseconds covers ~292 years, so
    /// saturation is unreachable for any real latency and is here only to remove the trap.
    static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        let (scaled, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflowed else { return seconds > 0 ? .max : .min }
        let (total, carried) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
        return carried ? (seconds > 0 ? .max : .min) : total
    }

    static func duration(nanoseconds: Int64) -> Duration {
        .nanoseconds(nanoseconds)
    }

    // MARK: - Timestamp

    /// Milliseconds since the epoch. Rounded, not truncated, so a round trip is off by at most half
    /// a millisecond in either direction rather than always early.
    static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(epochMilliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
    }
}
