// The `→ export` step of the product loop: the ledger, serialized for the offline eval.
//
// NDJSON — one JSON object per line, one line per run. The reader is offline tooling (jq, a
// dataframe, a notebook), so every line is SELF-CONTAINED: the ledger already copies model
// metadata into every run row (the argument recorded at ADR-0006), and device + OS are NOT NULL
// columns, so invariant 7 rides along by construction — no line can lack the machine that
// produced its numbers.
//
// STORED VALUES PASS THROUGH. The export copies column values into JSON without round-tripping
// them through Core's types: the stored tokens ARE the format (LedgerCodec's own rule), so a
// decode would buy nothing and cost something — a token this build does not know would turn into
// a refusal to export a row that is not wrong, merely newer or older than this build's vocabulary.
// What the columns hold is what the eval reads.
//
// THE JOIN SHAPE, decided here for the eval reader, not the writer: signals are EMBEDDED in their
// run's line, in append order, so the read rule recorded at `run_signals`' DDL survives the export
// boundary — the LAST element of `signals` is the current verdict, the earlier ones are history.
// One stream, not two: an eval joining a second file on run_id would re-derive a join the ledger
// already knows. An unsignaled run carries an explicit `"signals": []`, never an absent key —
// absent would read as "this exporter predates signals", an ambiguity the version gate exists to
// remove. No derived "current verdict" field: deriving is the reader's one job, and a derived
// field that disagreed with the array would be a second source of truth.
//
// DETERMINISM IS A CONTRACT, not an observation: runs ascend by id, children by (run_id, ordinal),
// signals by (run_id, id), and every statement says so in an explicit ORDER BY — traversal order
// without one is an implementation detail of the index, not a guarantee. Keys are sorted by the
// encoder. Re-exporting an unchanged ledger is byte-identical, and a test compares the bytes; the
// test is the backstop, never the mechanism.
//
// WHAT THIS DOES NOT DO, so nobody over-reads it: it does not export an in-memory ledger (a
// second connection cannot see one, so tests of the export use a file, like every claim about the
// file); it does not migrate (the connection is read-only — a file behind or ahead of this build
// is refused by version, naming both sides); and it never blocks the writer (its own read-only
// connection under WAL, never the actor's — the reader `RunLedger`'s WAL comment anticipated).

import Foundation
import SQLite3

/// One-shot, synchronous, UI-free. Where the file goes is the caller's decision — share-sheet
/// wiring is the composition's job; this API takes a destination and stays ignorant of screens.
public enum LedgerExport {

    /// Serialize the ledger at `databaseURL` to NDJSON at `destinationURL`, replacing whatever is
    /// there. Memory is bounded by one run and its children — lines are encoded and written one
    /// run at a time, never assembled whole.
    ///
    /// Opens its OWN read-only connection, never the actor's, so a run finishing mid-export is
    /// never blocked and nothing here touches actor isolation. The connection, its statements and
    /// the cursors live inside this one synchronous call frame and are confined to it — which is
    /// what makes NOMUTEX sound here: the same single-owner claim `RunLedger` documents for its
    /// connection, held by scope instead of by actor (ADR-0005's discipline, third appearance).
    public static func export(ledgerAt databaseURL: URL, to destinationURL: URL) throws(LedgerError) {
        let connection = try openReadOnly(at: databaseURL)

        // The version gate, before any table is named: a read-only connection cannot migrate, so
        // a file behind or ahead of this build is refused, naming both sides. The app's own ledger
        // is always migrated by `open()` before an export can be asked of it — a mismatch means
        // the file came from somewhere else. (`user_version` is a read; the configuration pragmas
        // the writer needs — foreign keys, WAL — configure writes this connection cannot perform.)
        let fileVersion = try userVersion(of: connection)
        guard fileVersion == LedgerSchema.latestVersion else {
            throw .exportVersionMismatch(
                fileVersion: fileVersion,
                requiredVersion: LedgerSchema.latestVersion
            )
        }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destinationURL)
        else { throw .exportWriteFailed }
        defer { try? handle.close() }

        // sortedKeys is half the byte-determinism contract (the ORDER BYs are the other half).
        // withoutEscapingSlashes because a label or an OS string gains nothing from `\/`.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let runs = try connection.prepare(
            """
            SELECT id, recorded_at_ms, device_model, os_version,
                   model_name, model_precision, model_input_width, model_input_height,
                   backend, is_cold, load_ns, preprocess_ns, infer_ns
            FROM runs
            ORDER BY id ASC
            """,
            orThrow: .readFailed
        )

        // The k-way merge: all four cursors ascend by run_id, so one pass over `runs` hands each
        // line its children with no per-run queries and no more than one run held in memory.
        let classifications = try ChildCursor(
            over: connection,
            sql: """
            SELECT run_id, ordinal, label, confidence FROM run_classifications
            ORDER BY run_id ASC, ordinal ASC
            """
        ) { statement throws(LedgerError) -> ExportedClassification in
            guard let label = statement.text(at: 2) else { throw .unreadableRow }
            return ExportedClassification(
                ordinal: statement.int64(at: 1),
                label: label,
                confidence: statement.double(at: 3)
            )
        }
        let degradations = try ChildCursor(
            over: connection,
            sql: """
            SELECT run_id, ordinal, kind, from_backend, to_backend FROM run_degradations
            ORDER BY run_id ASC, ordinal ASC
            """
        ) { statement throws(LedgerError) -> ExportedDegradation in
            guard let kind = statement.text(at: 2) else { throw .unreadableRow }
            return ExportedDegradation(
                ordinal: statement.int64(at: 1),
                kind: kind,
                fromBackend: statement.text(at: 3),
                toBackend: statement.text(at: 4)
            )
        }
        let signals = try ChildCursor(
            over: connection,
            sql: """
            SELECT run_id, id, recorded_at_ms, verdict FROM run_signals
            ORDER BY run_id ASC, id ASC
            """
        ) { statement throws(LedgerError) -> ExportedSignal in
            guard let verdict = statement.text(at: 3) else { throw .unreadableRow }
            return ExportedSignal(
                id: statement.int64(at: 1),
                recordedAtMs: statement.int64(at: 2),
                verdict: verdict
            )
        }

        while try runs.step(orThrow: .readFailed) {
            let line = try exportedRun(
                from: runs,
                classifications: classifications,
                degradations: degradations,
                signals: signals
            )

            var data: Data
            do {
                data = try encoder.encode(line)
            } catch {
                // The one value these DTOs can hold that JSON cannot carry is a non-finite REAL —
                // a confidence no CHECK constraint can fully forbid to a foreign writer. The query
                // worked and the data is wrong: `.unreadableRow`'s exact meaning.
                throw .unreadableRow
            }
            data.append(0x0A)

            do {
                try handle.write(contentsOf: data)
            } catch {
                throw .exportWriteFailed
            }
        }
    }

    // MARK: - One line

    private static func exportedRun(
        from statement: SQLiteStatement,
        classifications: ChildCursor<ExportedClassification>,
        degradations: ChildCursor<ExportedDegradation>,
        signals: ChildCursor<ExportedSignal>
    ) throws(LedgerError) -> ExportedRun {
        let id = statement.int64(at: 0)
        guard let deviceModel = statement.text(at: 2),
              let osVersion = statement.text(at: 3),
              let modelName = statement.text(at: 4),
              let modelPrecision = statement.text(at: 5),
              let backend = statement.text(at: 8)
        else { throw .unreadableRow }

        return ExportedRun(
            id: id,
            recordedAtMs: statement.int64(at: 1),
            deviceModel: deviceModel,
            osVersion: osVersion,
            modelName: modelName,
            modelPrecision: modelPrecision,
            modelInputWidth: statement.int64(at: 6),
            modelInputHeight: statement.int64(at: 7),
            backend: backend,
            isCold: statement.int64(at: 9),
            loadNs: statement.optionalInt64(at: 10),
            preprocessNs: statement.int64(at: 11),
            inferNs: statement.int64(at: 12),
            classifications: try classifications.rows(forRun: id),
            degradations: try degradations.rows(forRun: id),
            signals: try signals.rows(forRun: id)
        )
    }

    // MARK: - Connection

    private static func openReadOnly(at url: URL) throws(LedgerError) -> SQLiteConnection {
        // READONLY makes this connection INCAPABLE of the writes the export must never perform —
        // enforcement by capability, the same idea as the append-only triggers, one level up.
        // NOMUTEX is sound only because of the call-frame confinement `export` documents.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw .cannotOpen
        }
        return SQLiteConnection(handle: opened)
    }

    private static func userVersion(of connection: SQLiteConnection) throws(LedgerError) -> Int {
        let statement = try connection.prepare("PRAGMA user_version", orThrow: .cannotOpen)
        guard try statement.step(orThrow: .cannotOpen) else { throw .cannotOpen }
        return Int(statement.int64(at: 0))
    }
}

// MARK: - The line's shape

// Private DTOs whose coding keys are the LITERAL column names, filled straight from the
// statements — the export is the schema's vocabulary, not Core's. Synthesized Encodable omits a
// nil optional's key entirely (never `null`), which is how `load_ns` disappears from a warm run
// and the backend pair from a non-fallback degradation: the same absences the columns hold.

private struct ExportedRun: Encodable {
    let id: Int64
    let recordedAtMs: Int64
    let deviceModel: String
    let osVersion: String
    let modelName: String
    let modelPrecision: String
    let modelInputWidth: Int64
    let modelInputHeight: Int64
    let backend: String
    let isCold: Int64
    let loadNs: Int64?
    let preprocessNs: Int64
    let inferNs: Int64
    let classifications: [ExportedClassification]
    let degradations: [ExportedDegradation]
    /// Never optional: an unsignaled run exports `"signals": []`, the absence of judgements — not
    /// an absent key, which would be the absence of the question.
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
}

/// `ordinal` is carried explicitly even though the array is ordered by it: a line should survive
/// tooling that re-sorts an array, and the column is the row's own statement of its position.
private struct ExportedClassification: Encodable {
    let ordinal: Int64
    let label: String
    let confidence: Double
}

private struct ExportedDegradation: Encodable {
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

private struct ExportedSignal: Encodable {
    let id: Int64
    let recordedAtMs: Int64
    let verdict: String

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAtMs = "recorded_at_ms"
        case verdict
    }
}

// MARK: - The merge's per-stream state

/// A forward-only cursor over one child statement ordered by `run_id` — which is column 0 by
/// convention here — with one row of lookahead, so a single pass can hand each run its rows.
///
/// Non-`Sendable` and confined to the exporting call frame, like the connection whose statement it
/// holds; the lookahead exists because a stepped row cannot be un-stepped, so the first row of the
/// NEXT run must be held somewhere between runs.
private final class ChildCursor<Row> {
    private let statement: SQLiteStatement
    private let read: (SQLiteStatement) throws(LedgerError) -> Row
    /// The `run_id` of the row the statement currently sits on; `nil` once exhausted.
    private var pendingRunID: Int64?

    init(
        over connection: SQLiteConnection,
        sql: String,
        read: @escaping (SQLiteStatement) throws(LedgerError) -> Row
    ) throws(LedgerError) {
        self.statement = try connection.prepare(sql, orThrow: .readFailed)
        self.read = read
        try advance()
    }

    /// Every row belonging to `runID`, possibly none. Correct only when calls ascend in `runID`,
    /// which the runs statement's own ORDER BY guarantees; rows are consumed exactly once.
    func rows(forRun runID: Int64) throws(LedgerError) -> [Row] {
        var rows: [Row] = []
        while pendingRunID == runID {
            rows.append(try read(statement))
            try advance()
        }
        return rows
    }

    private func advance() throws(LedgerError) {
        pendingRunID = try statement.step(orThrow: .readFailed) ? statement.int64(at: 0) : nil
    }
}
