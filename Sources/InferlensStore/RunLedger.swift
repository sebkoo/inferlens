// The append-only run ledger: the `→ ledger` step of the product loop, and the thing the offline
// eval will eventually read.
//
// CONCURRENCY — the pattern is ADR-0005's, reused, not reinvented. `sqlite3*` is the same species of
// handle as `TfLiteInterpreter*`: a non-Sendable C pointer with no thread-safety guarantee, and
// `OpaquePointer` is trivial so region isolation will NOT catch a misuse. So:
//
//   - this is an `actor`, and it serializes every access to the connection;
//   - every C call is synchronous and on-actor — there is no `await` anywhere between reading the
//     connection and the C call returning;
//   - the handle is owned by a private-to-the-module `final class` (`SQLiteConnection`) that closes
//     it in its own synchronous `deinit`, run by ARC at refcount zero — RAII, never an
//     `isolated deinit`, which this repo disproved by runtime crash;
//   - `@unchecked Sendable` stays at ZERO (CLAUDE.md invariant 2, enforced by CI lint).
//
// The compiler does not enforce the second point — the discipline is manual and is documented at
// each call site, exactly as `LiteRTEngine` documents its `Invoke`.
//
// APPEND-ONLY is enforced by the schema's BEFORE UPDATE / BEFORE DELETE triggers, in the file
// itself, and the mechanism (plus what it does NOT cover) is written out in `LedgerSchema`. This
// type is the second line only: it exposes `append` and reads, and no mutation path at all.

import Foundation
import InferlensCore
import SQLite3

public actor RunLedger {

    /// Where the database lives.
    ///
    /// `.inMemory` exists so a test never touches a real ledger file. A test that wrote to the app's
    /// ledger would void exactly the isolation `test-clean` was built to guarantee — a fresh
    /// `-derivedDataPath` isolates build products, not the user's Application Support directory
    /// (ADR-0006). Tests that need a file use a per-test temporary directory, never a shared path.
    public enum Location: Sendable {
        case file(URL)
        case inMemory
    }

    private let location: Location

    /// `nil` until `open()` succeeds. A call before then is `LedgerError.notOpen` — the same shape
    /// as an engine's `classify` before `loadModel`, and never a trap.
    private var connection: SQLiteConnection?

    public init(location: Location) {
        self.location = location
    }

    // MARK: - Open + migrate

    /// Open the database and bring it to the latest schema version. Idempotent: calling it again on
    /// an open ledger is a no-op, so a composition root need not track whether it already ran.
    ///
    /// A failure here leaves the ledger closed — the `SQLiteConnection` created on the failing path
    /// is released by ARC on the way out and closes its handle, so no connection is leaked and no
    /// half-open state is stored.
    public func open() throws(LedgerError) {
        guard connection == nil else { return }

        let path: String
        switch location {
        case .file(let url): path = url.path
        case .inMemory: path = ":memory:"
        }

        // NOMUTEX: SQLite's own serialization is switched OFF because the actor already provides it.
        // That is sound ONLY because of the on-actor discipline described at the top of this file —
        // it is a claim about this type's design, not a performance tweak taken on faith.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            // open_v2 can hand back a handle even on failure; it still has to be closed.
            if let handle { sqlite3_close_v2(handle) }
            throw .cannotOpen
        }
        let opening = SQLiteConnection(handle: opened)

        // Foreign keys are OFF by default in SQLite and are per-connection, so the child tables'
        // REFERENCES clauses would be decorative without this line.
        try opening.exec("PRAGMA foreign_keys = ON", orThrow: .cannotOpen)

        // WAL for a file, so a reader (the export) never blocks the writer (a run finishing). An
        // in-memory database has no WAL and would refuse it, so it is not asked for.
        if case .file = location {
            try opening.exec("PRAGMA journal_mode = WAL", orThrow: .cannotOpen)
        }

        try migrate(opening)
        connection = opening
    }

    /// The schema version of the open file.
    public func schemaVersion() throws(LedgerError) -> Int {
        guard let connection else { throw .notOpen }
        return try userVersion(of: connection)
    }

    /// Apply every migration above the file's current version, each inside its own transaction
    /// together with its `user_version` bump — so a file is never left between two versions.
    private func migrate(_ connection: SQLiteConnection) throws(LedgerError) {
        let current = try userVersion(of: connection)
        let latest = LedgerSchema.latestVersion
        guard current <= latest else {
            // A file written by a newer build. Refused rather than opened optimistically: a later
            // version may have moved a column this build would read as something else.
            throw .schemaTooNew(fileVersion: current, supportedVersion: latest)
        }

        for migration in LedgerSchema.migrations.sorted(by: { $0.version < $1.version })
        where migration.version > current {
            let failure = LedgerError.migrationFailed(toVersion: migration.version)
            try connection.exec("BEGIN IMMEDIATE", orThrow: failure)
            do {
                for statement in migration.statements {
                    try connection.exec(statement, orThrow: failure)
                }
                // Transactional: `user_version` lives in the database header, so it commits with the
                // DDL above it or not at all.
                try connection.exec("PRAGMA user_version = \(migration.version)", orThrow: failure)
                try connection.exec("COMMIT", orThrow: failure)
            } catch {
                connection.execIgnoringResult("ROLLBACK")
                throw error
            }
        }
    }

    private func userVersion(of connection: SQLiteConnection) throws(LedgerError) -> Int {
        let statement = try connection.prepare("PRAGMA user_version", orThrow: .cannotOpen)
        guard try statement.step(orThrow: .cannotOpen) else { throw .cannotOpen }
        return Int(statement.int64(at: 0))
    }

    // MARK: - Append

    /// Append one run. Returns the id the ledger assigned it.
    ///
    /// The run row and all of its classification and degradation rows commit together or not at all:
    /// a partially-written run in an append-only ledger could never be repaired, because there is no
    /// UPDATE path to repair it with. On any failure the transaction is rolled back and
    /// `LedgerError.appendFailed` is thrown — including the case where an append-only trigger
    /// refuses the statement.
    @discardableResult
    public func append(_ record: RunRecord) throws(LedgerError) -> Int64 {
        guard let connection else { throw .notOpen }

        try connection.exec("BEGIN IMMEDIATE", orThrow: .appendFailed)
        do {
            let id = try insertRun(record, into: connection)
            try insertClassifications(record.classifications, forRun: id, into: connection)
            try insertDegradations(record.degradations, forRun: id, into: connection)
            try connection.exec("COMMIT", orThrow: .appendFailed)
            return id
        } catch {
            connection.execIgnoringResult("ROLLBACK")
            throw error
        }
    }

    private func insertRun(
        _ record: RunRecord,
        into connection: SQLiteConnection
    ) throws(LedgerError) -> Int64 {
        let statement = try connection.prepare(
            """
            INSERT INTO runs (
                recorded_at_ms, device_model, os_version,
                model_name, model_precision, model_input_width, model_input_height,
                backend, is_cold, load_ns, preprocess_ns, infer_ns
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            orThrow: .appendFailed
        )

        // The cold/warm axis, split into the two columns the CHECK constraint pairs: `load_ns` is
        // non-NULL exactly when `is_cold` is 1, which is `LoadTiming`'s shape expressed in SQL.
        let loadNanoseconds: Int64?
        switch record.sample.load {
        case .cold(let duration): loadNanoseconds = LedgerCodec.nanoseconds(duration)
        case .warm: loadNanoseconds = nil
        }

        try statement.bind(LedgerCodec.epochMilliseconds(record.recordedAt), at: 1, orThrow: .appendFailed)
        try statement.bind(record.device.model, at: 2, orThrow: .appendFailed)
        try statement.bind(record.device.osVersion, at: 3, orThrow: .appendFailed)
        try statement.bind(record.model.name, at: 4, orThrow: .appendFailed)
        try statement.bind(LedgerCodec.encode(record.model.precision), at: 5, orThrow: .appendFailed)
        try statement.bind(record.model.inputSize.width, at: 6, orThrow: .appendFailed)
        try statement.bind(record.model.inputSize.height, at: 7, orThrow: .appendFailed)
        try statement.bind(LedgerCodec.encode(record.backend), at: 8, orThrow: .appendFailed)
        try statement.bind(record.sample.isCold ? 1 : 0, at: 9, orThrow: .appendFailed)
        try statement.bind(optional: loadNanoseconds, at: 10, orThrow: .appendFailed)
        try statement.bind(LedgerCodec.nanoseconds(record.sample.run.preprocess), at: 11, orThrow: .appendFailed)
        try statement.bind(LedgerCodec.nanoseconds(record.sample.run.infer), at: 12, orThrow: .appendFailed)

        // An INSERT returns no rows, so `step` must report DONE, not ROW.
        guard try statement.step(orThrow: .appendFailed) == false else { throw .appendFailed }
        return connection.lastInsertedRowID
    }

    private func insertClassifications(
        _ classifications: [Classification],
        forRun runID: Int64,
        into connection: SQLiteConnection
    ) throws(LedgerError) {
        guard !classifications.isEmpty else { return }
        let statement = try connection.prepare(
            "INSERT INTO run_classifications (run_id, ordinal, label, confidence) VALUES (?, ?, ?, ?)",
            orThrow: .appendFailed
        )
        // One compiled statement, reset and rebound per row — the ordinary way to insert a batch,
        // and it keeps the whole batch inside the caller's transaction.
        for (ordinal, classification) in classifications.enumerated() {
            try statement.bind(runID, at: 1, orThrow: .appendFailed)
            try statement.bind(ordinal, at: 2, orThrow: .appendFailed)
            try statement.bind(classification.label, at: 3, orThrow: .appendFailed)
            try statement.bind(Double(classification.confidence), at: 4, orThrow: .appendFailed)
            guard try statement.step(orThrow: .appendFailed) == false else { throw .appendFailed }
            sqlite3_reset(statement.handle)
        }
    }

    private func insertDegradations(
        _ degradations: [DegradationReason],
        forRun runID: Int64,
        into connection: SQLiteConnection
    ) throws(LedgerError) {
        guard !degradations.isEmpty else { return }
        let statement = try connection.prepare(
            """
            INSERT INTO run_degradations (run_id, ordinal, kind, from_backend, to_backend)
            VALUES (?, ?, ?, ?, ?)
            """,
            orThrow: .appendFailed
        )
        for (ordinal, reason) in degradations.enumerated() {
            let encoded = LedgerCodec.encode(reason)
            try statement.bind(runID, at: 1, orThrow: .appendFailed)
            try statement.bind(ordinal, at: 2, orThrow: .appendFailed)
            try statement.bind(encoded.kind, at: 3, orThrow: .appendFailed)
            try statement.bind(optional: encoded.from, at: 4, orThrow: .appendFailed)
            try statement.bind(optional: encoded.to, at: 5, orThrow: .appendFailed)
            guard try statement.step(orThrow: .appendFailed) == false else { throw .appendFailed }
            sqlite3_reset(statement.handle)
        }
    }

    // MARK: - Signals

    /// Append one thumbs signal for a run this ledger already holds. Returns the id the ledger
    /// assigned it.
    ///
    /// A single INSERT, auto-committed — no explicit transaction, because unlike `append(_:)`
    /// there are no child rows to keep atomic with it. The foreign key is live
    /// (`PRAGMA foreign_keys` in `open()`), so a signal naming a run the ledger never recorded is
    /// refused as `.appendFailed`, not stored as a dangling opinion.
    ///
    /// A SECOND signal for the same run appends a superseding row. The duplicate policy and its
    /// read rule — highest id wins — are recorded at the schema (`run_signals`' DDL), which is
    /// also where the export's obligation to carry the superseded rows is stated.
    ///
    /// `recordedAt` is caller-supplied so a test can pin it — `RunRecord`'s own convention.
    @discardableResult
    public func appendSignal(
        runID: Int64,
        verdict: SignalVerdict,
        recordedAt: Date
    ) throws(LedgerError) -> Int64 {
        guard let connection else { throw .notOpen }

        let statement = try connection.prepare(
            "INSERT INTO run_signals (run_id, recorded_at_ms, verdict) VALUES (?, ?, ?)",
            orThrow: .appendFailed
        )
        try statement.bind(runID, at: 1, orThrow: .appendFailed)
        try statement.bind(LedgerCodec.epochMilliseconds(recordedAt), at: 2, orThrow: .appendFailed)
        try statement.bind(LedgerCodec.encode(verdict), at: 3, orThrow: .appendFailed)
        guard try statement.step(orThrow: .appendFailed) == false else { throw .appendFailed }
        return connection.lastInsertedRowID
    }

    /// Every signal for one run, in append order (ascending id). Under the schema's read rule the
    /// LAST element is therefore the current verdict; the earlier ones are its history — data the
    /// export carries, not noise.
    public func signals(forRun runID: Int64) throws(LedgerError) -> [RunSignal] {
        guard let connection else { throw .notOpen }

        let statement = try connection.prepare(
            """
            SELECT id, recorded_at_ms, verdict FROM run_signals
            WHERE run_id = ? ORDER BY id ASC
            """,
            orThrow: .readFailed
        )
        try statement.bind(runID, at: 1, orThrow: .readFailed)

        var results: [RunSignal] = []
        while try statement.step(orThrow: .readFailed) {
            results.append(
                RunSignal(
                    id: statement.int64(at: 0),
                    runID: runID,
                    recordedAt: LedgerCodec.date(epochMilliseconds: statement.int64(at: 1)),
                    verdict: try LedgerCodec.decodeVerdict(statement.text(at: 2))
                )
            )
        }
        return results
    }

    // MARK: - Read

    /// The most recent `limit` runs, newest first, each with its classifications and degradations.
    ///
    /// Ordered by `id`, not by `recorded_at_ms`: id is the ledger's own append order and is
    /// monotonic, while a wall clock can jump backwards and reorder two runs that did not happen in
    /// that order.
    ///
    /// The children are fetched per run rather than by one join. That is N+1 queries, chosen
    /// deliberately: a join over a run's full score vector would return the parent row once per
    /// classification and need de-duplicating in Swift, and this read exists to fill a screen with a
    /// handful of runs. The export rung reads in bulk and will want a different query — that is its
    /// problem to solve, not a reason to complicate this one now.
    public func recentRuns(limit: Int) throws(LedgerError) -> [LedgerRun] {
        guard let connection else { throw .notOpen }
        guard limit > 0 else { return [] }

        let statement = try connection.prepare(
            """
            SELECT id, recorded_at_ms, device_model, os_version,
                   model_name, model_precision, model_input_width, model_input_height,
                   backend, is_cold, load_ns, preprocess_ns, infer_ns
            FROM runs
            ORDER BY id DESC
            LIMIT ?
            """,
            orThrow: .readFailed
        )
        try statement.bind(limit, at: 1, orThrow: .readFailed)

        var runs: [LedgerRun] = []
        while try statement.step(orThrow: .readFailed) {
            runs.append(try run(from: statement, in: connection))
        }
        return runs
    }

    /// Map one `runs` row plus its children back to Core's value types. Any column that cannot be
    /// mapped is `.unreadableRow` — the query worked and the data is wrong, which is a different
    /// failure from the query not working.
    private func run(
        from statement: SQLiteStatement,
        in connection: SQLiteConnection
    ) throws(LedgerError) -> LedgerRun {
        let id = statement.int64(at: 0)

        guard let deviceModel = statement.text(at: 2),
              let osVersion = statement.text(at: 3),
              let modelName = statement.text(at: 4)
        else { throw .unreadableRow }

        let precision = try LedgerCodec.decodePrecision(statement.text(at: 5))
        let backend = try LedgerCodec.decodeBackend(statement.text(at: 8))

        // The CHECK constraint guarantees the pairing on write; it is re-checked on read because a
        // row this build did not write could still be in the file.
        let isCold = statement.int64(at: 9) == 1
        let load: LoadTiming
        switch (isCold, statement.optionalInt64(at: 10)) {
        case (true, .some(let nanoseconds)): load = .cold(LedgerCodec.duration(nanoseconds: nanoseconds))
        case (false, .none): load = .warm
        default: throw .unreadableRow
        }

        let record = RunRecord(
            device: DeviceIdentity(model: deviceModel, osVersion: osVersion),
            recordedAt: LedgerCodec.date(epochMilliseconds: statement.int64(at: 1)),
            model: ModelDescriptor(
                name: modelName,
                precision: precision,
                inputSize: PixelSize(
                    width: Int(statement.int64(at: 6)),
                    height: Int(statement.int64(at: 7))
                )
            ),
            backend: backend,
            sample: LatencySample(
                load: load,
                run: RunTiming(
                    preprocess: LedgerCodec.duration(nanoseconds: statement.int64(at: 11)),
                    infer: LedgerCodec.duration(nanoseconds: statement.int64(at: 12))
                )
            ),
            classifications: try classifications(forRun: id, in: connection),
            degradations: try degradations(forRun: id, in: connection)
        )
        return LedgerRun(id: id, record: record)
    }

    private func classifications(
        forRun runID: Int64,
        in connection: SQLiteConnection
    ) throws(LedgerError) -> [Classification] {
        let statement = try connection.prepare(
            """
            SELECT label, confidence FROM run_classifications
            WHERE run_id = ? ORDER BY ordinal ASC
            """,
            orThrow: .readFailed
        )
        try statement.bind(runID, at: 1, orThrow: .readFailed)

        var results: [Classification] = []
        while try statement.step(orThrow: .readFailed) {
            guard let label = statement.text(at: 0) else { throw .unreadableRow }
            results.append(Classification(label: label, confidence: Float(statement.double(at: 1))))
        }
        return results
    }

    private func degradations(
        forRun runID: Int64,
        in connection: SQLiteConnection
    ) throws(LedgerError) -> [DegradationReason] {
        let statement = try connection.prepare(
            """
            SELECT kind, from_backend, to_backend FROM run_degradations
            WHERE run_id = ? ORDER BY ordinal ASC
            """,
            orThrow: .readFailed
        )
        try statement.bind(runID, at: 1, orThrow: .readFailed)

        var results: [DegradationReason] = []
        while try statement.step(orThrow: .readFailed) {
            results.append(
                try LedgerCodec.decodeDegradation(
                    kind: statement.text(at: 0),
                    from: statement.text(at: 1),
                    to: statement.text(at: 2)
                )
            )
        }
        return results
    }
}
