// InferlensEval — the loop's sixth clause as code: `export → offline eval → choose next
// model/backend`. It reads the NDJSON `LedgerExport` writes and answers one question — which backend
// should the next run use — or REFUSES to answer it, which on today's corpus is what it does.
//
// Dependency direction (ADR-0001, amended 9 -> 10 modules): InferlensEval -> InferlensBench ->
// InferlensCore, plus Foundation. It is the graph's FIRST library -> library arrow and it is the
// point rather than a compromise: CLAUDE.md invariant 1 makes the percentile definition, the
// cold/warm boundary and the warm-up policy maintainer-ratified choices, and `LatencySummary.swift`
// records the consequence — `LatencyRecorder` is the only place any percentile is computed in this
// repo. So this module does not reproduce, describe or approximate them. It rebuilds a
// `LatencySample` from each row's own columns and calls `LatencyRecorder.summarize`. The statistics
// are EXECUTED here, not restated (ADR-0015, Decisions 2 and 4).
//
// It imports no engine and NOT InferlensStore. The exporter's own header says why that arrow is
// unnecessary: "the stored tokens ARE the format ... What the columns hold is what the eval reads."
//
// THE BACKEND IS AN OPAQUE TOKEN HERE, deliberately, and it is the exporter's reasoning applied one
// layer further out. `LedgerExport` copies column values into JSON without decoding them, because
// "a token this build does not know would turn into a refusal to export a row that is not wrong,
// merely newer or older than this build's vocabulary." A reader that decoded `"liteRT"` into
// `Backend` would reintroduce exactly that failure at the other end of the pipe — a fourth engine
// would make every older eval build refuse a valid file. So rows group by the token string and the
// report prints it verbatim; nothing here needs to know what backends exist.
//
// WHAT IT VALIDATES, stated so the scope is not over-read: the key set of every line, the types of
// every field, and the two domain rules the report depends on (`is_cold` is 0 or 1; a signal's
// verdict is `up` or `down`). It does NOT re-validate the exporter's own CHECK constraints — a
// confidence outside 0...1 or a degradation kind this build does not know is passed over rather than
// refused, because no number in the report is computed from either.

import Foundation
import InferlensBench
import InferlensCore

// MARK: - Refusals

/// Why a file was refused. Every case names the 1-based LINE, because an eval that says "malformed
/// input" about a 500-row export has told the reader nothing they can act on.
///
/// A malformed row is REFUSED, never repaired and never partially read — the whole file is refused,
/// not the row, because a report over "the rows that happened to parse" is a statistic about an
/// unknown subset. That is the `RemoteEngine` validation precedent: a response this build cannot
/// fully understand is not a response.
public enum EvalError: Error, Sendable, Equatable {
    /// The input held no rows at all. A summary of nothing is not a summary (the same disposition as
    /// `LatencyRecorderError.noSamples`, which this would otherwise reach).
    case noRows
    /// The line is not a single JSON object — NDJSON's one structural rule.
    case notJSONObject(line: Int)
    /// A key the contract requires is absent.
    case missingKey(line: Int, key: String)
    /// A key this build does not know. THIS is where an export from a future writer is refused: the
    /// NDJSON carries no version field to gate on (ADR-0015, Decision 5), so the key set IS the
    /// contract, and an unrecognized key means the file was written by something this build cannot
    /// claim to read.
    case unknownKey(line: Int, key: String)
    /// A value of the wrong type, or outside the domain the contract fixes. `path` is dotted with
    /// bracketed indices — `signals[1].verdict` — so the reader is sent to the value, not the row.
    case badValue(line: Int, path: String)
    /// `load_ns` is present exactly when `is_cold` is 1 and absent otherwise. The exporter produces
    /// this by omitting a nil optional's key, and `LedgerExportTests` pins it from the writer's side;
    /// this is the same rule read from the reader's side. A cold row with no load, or a warm row
    /// carrying one, is a contradiction rather than a value to interpret.
    case loadTimingMismatch(line: Int, isCold: Bool)
}

// MARK: - Entry point

public enum LedgerEval {

    /// Parse, group, summarize and decide. One synchronous pass, no clock read anywhere — every
    /// number in the result comes from the rows' own columns, which is what makes the whole of this
    /// module testable on shared CI hardware (the rung-31 lesson, applied at authoring time).
    public static func evaluate(ndjson: String) throws(EvalError) -> EvalResult {
        let rows = try parse(ndjson)
        guard !rows.isEmpty else { throw .noRows }
        return summarize(rows)
    }

    // MARK: - Parse

    /// The keys a line must carry, in the order a refusal reports them — so two runs over the same
    /// broken file name the same key rather than whichever the dictionary happened to yield first.
    ///
    /// These mirror `LedgerExport`'s private DTOs exactly. That duplication is the READER's half of a
    /// published interface: the writer's spec (`LedgerExportTests`) pins what is emitted, this pins
    /// what is accepted, and the two meeting is the contract. Sharing a type between them would mean
    /// `InferlensEval` importing `InferlensStore`, which would put SQLite behind a file reader.
    static let requiredKeys = [
        "id",
        "recorded_at_ms",
        "device_model",
        "os_version",
        "model_name",
        "model_precision",
        "model_input_width",
        "model_input_height",
        "backend",
        "is_cold",
        "preprocess_ns",
        "infer_ns",
        "classifications",
        "degradations",
        "signals",
    ]

    /// Present exactly when the row is cold. The one key whose absence is meaning rather than error.
    static let conditionalKey = "load_ns"

    private static func parse(_ ndjson: String) throws(EvalError) -> [ExportedRow] {
        var rows: [ExportedRow] = []
        var lineNumber = 0

        // `split(omittingEmptySubsequences:)` drops the trailing newline every export ends with, and
        // drops blank lines anywhere else too. A blank line is not a row and is not a malformed row.
        // The line NUMBER still counts them, so a refusal points at the file as an editor shows it.
        for line in ndjson.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            rows.append(try row(from: Data(line.utf8), at: lineNumber))
        }
        return rows
    }

    private static func row(from data: Data, at line: Int) throws(EvalError) -> ExportedRow {
        // Two passes over the same bytes, on purpose. JSONSerialization answers "what keys are here"
        // — the question `Decodable` cannot ask, because a synthesized decoder silently ignores every
        // key it does not know, which is the one failure mode a versionless format cannot afford.
        // JSONDecoder then answers "are the values the right types", which hand-written `as?` casts
        // do badly (a JSON `true` and a JSON `1` both bridge to NSNumber).
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .notJSONObject(line: line)
        }

        for key in requiredKeys where object[key] == nil {
            throw .missingKey(line: line, key: key)
        }
        let known = Set(requiredKeys + [conditionalKey])
        for key in object.keys.sorted() where !known.contains(key) {
            throw .unknownKey(line: line, key: key)
        }

        let decoded: ExportedRow
        do {
            decoded = try JSONDecoder().decode(ExportedRow.self, from: data)
        } catch let error as DecodingError {
            throw decodingFailure(error, at: line)
        } catch {
            throw .badValue(line: line, path: "")
        }

        guard decoded.isCold == 0 || decoded.isCold == 1 else {
            throw .badValue(line: line, path: "is_cold")
        }
        let cold = decoded.isCold == 1
        guard (decoded.loadNs != nil) == cold else {
            throw .loadTimingMismatch(line: line, isCold: cold)
        }
        for (index, signal) in decoded.signals.enumerated() where !["up", "down"].contains(signal.verdict) {
            throw .badValue(line: line, path: "signals[\(index)].verdict")
        }
        return decoded
    }

    private static func decodingFailure(_ error: DecodingError, at line: Int) -> EvalError {
        switch error {
        case .keyNotFound(let key, let context):
            // Unreachable for a top-level key — the key-set sweep above has already run — but a
            // nested object (a classification with no `label`) arrives here, and it is a missing key
            // rather than a bad value.
            .missingKey(line: line, key: path(context.codingPath + [key]))
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            .badValue(line: line, path: path(context.codingPath))
        @unknown default:
            .badValue(line: line, path: "")
        }
    }

    /// `["signals", 1, "verdict"]` -> `signals[1].verdict`.
    private static func path(_ codingPath: [any CodingKey]) -> String {
        var rendered = ""
        for key in codingPath {
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else {
                rendered += rendered.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return rendered
    }

    // MARK: - Group and summarize

    /// Rows partition by `(device_model, os_version, backend)` and never across it.
    ///
    /// This is CLAUDE.md invariant 7 doing work rather than being quoted. "Every number carries its
    /// device + iOS version" is satisfied by a report that pools a phone's rows with a simulator's
    /// and prints both labels above the total — and that report would be a lie with a correct
    /// caption. Percentiles are computed within one machine, backends are compared within one
    /// machine, and rows from two machines are never the same population (ADR-0015, Decision 3).
    private static func summarize(_ rows: [ExportedRow]) -> EvalResult {
        var grouped: [ScopeKey: [String: [ExportedRow]]] = [:]
        for row in rows {
            let scope = ScopeKey(device: row.deviceModel, osVersion: row.osVersion)
            grouped[scope, default: [:]][row.backend, default: []].append(row)
        }

        let scopes = grouped.keys.sorted().map { scope -> ScopeReport in
            let byBackend = grouped[scope] ?? [:]
            let backends = byBackend.keys.sorted().map { backend -> BackendReport in
                let rows = byBackend[backend] ?? []
                // The reuse, in one line: the ratified percentile, the ratified cold/warm partition
                // and the ratified no-discard policy all happen inside this call, in InferlensBench,
                // in the same code the app runs. Nothing is filtered before it — a cold row is
                // reported in the cold bucket exactly as ratified choice (c) requires.
                //
                // The recorder's only error is `.noSamples`, which this cannot produce — a group
                // exists because a row created it. The fallback is not a fabricated number standing
                // in for a failure: `LatencySummary(cold: nil, warm: nil)` is what "no rows" means
                // in that type, so the unreachable branch and the correct answer coincide.
                let summary = (try? LatencyRecorder().summarize(rows.map(\.latencySample)))
                    ?? LatencySummary(cold: nil, warm: nil)
                return BackendReport(
                    backend: backend,
                    latency: summary,
                    signal: SignalTally(rows: rows)
                )
            }
            return ScopeReport(device: scope.device, osVersion: scope.osVersion, backends: backends)
        }

        return EvalResult(rowCount: rows.count, scopes: scopes)
    }
}

// MARK: - The grouping key

struct ScopeKey: Hashable, Comparable {
    let device: String
    let osVersion: String

    static func < (lhs: ScopeKey, rhs: ScopeKey) -> Bool {
        (lhs.device, lhs.osVersion) < (rhs.device, rhs.osVersion)
    }
}
