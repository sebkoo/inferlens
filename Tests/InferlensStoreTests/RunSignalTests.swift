// The thumbs signal's spec: schema v2 migrates, a signal round-trips, the foreign key and the
// append-only triggers bite from outside the module, and the duplicate policy's read rule —
// highest id wins — is enforced here, which is rider one of the policy recorded at `run_signals`'
// DDL.
//
// WHAT THIS IS NOT. Still not the full migration/invariant suite: applying migration 2 over an
// EXISTING v1 FILE (as opposed to a fresh database applying 1 then 2 in sequence, which every test
// here exercises implicitly) is the sequential-migration proof, and it is its own ladder rung,
// deliberately not half-landed here.
//
// `@testable` is new for this target and is spent on exactly two structural assertions public API
// cannot reach: migration 1's statement list never names `run_signals` (growing a shipped
// migration's trigger list is the divergence `LedgerSchema` forbids — it would abort migration 1
// on every fresh file), and every user table in the file carries both append-only triggers (the
// whole-file guarantee, checked rather than narrated).

import XCTest
import InferlensCore
import SQLite3
@testable import InferlensStore

final class RunSignalTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            self.temporaryDirectory = nil
        }
        try super.tearDownWithError()
    }

    /// A fresh, per-test database path under a directory this test owns and deletes — the same
    /// isolation contract `RunLedgerSmokeTests` documents (ADR-0006).
    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferlens-signals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        return directory.appendingPathComponent("ledger.sqlite3")
    }

    /// The smallest legal run for a signal to reference; the round-trip fidelity of a full record
    /// is `RunLedgerSmokeTests`' subject, not this file's.
    private func anyRun(at date: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> RunRecord {
        RunRecord(
            device: DeviceIdentity(model: "iPhone17,1", osVersion: "iOS 26.1"),
            recordedAt: date,
            model: ModelDescriptor(
                name: "MobileNetV2 (Google, FP32)",
                precision: .fp32,
                inputSize: PixelSize(width: 224, height: 224)
            ),
            backend: .liteRT,
            sample: LatencySample(
                load: .warm,
                run: RunTiming(preprocess: .milliseconds(2), infer: .milliseconds(11))
            ),
            classifications: [Classification(label: "class 281", confidence: 0.9)]
        )
    }

    // MARK: - Migration

    func testAFreshDatabaseReachesVersionTwoApplyingBothMigrations() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        // Both halves of the claim: the file is at 2, and 2 is what the ladder currently tops out
        // at — so it moves in lockstep with `latestVersion` instead of pinning a stale copy.
        let version = try await ledger.schemaVersion()
        XCTAssertEqual(version, 2)
        XCTAssertEqual(version, LedgerSchema.latestVersion)
    }

    func testMigrationOneNamesNoRunSignals() throws {
        // The byte-identity insurance: migration 1 shipped at the ledger rung, and a later edit
        // that folded `run_signals` into its trigger list would abort every fresh migration (the
        // table does not exist at v1) — caught here as a structural fact, not by a crash later.
        let migrationOne = try XCTUnwrap(
            LedgerSchema.migrations.first(where: { $0.version == 1 })
        )
        for statement in migrationOne.statements {
            XCTAssertFalse(
                statement.contains("run_signals"),
                "migration 1 is shipped and immutable; run_signals belongs to migration 2 alone"
            )
        }
    }

    // MARK: - Round trip

    func testASignalRoundTripsWithItsVerdictAndTimestamp() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        let runID = try await ledger.append(anyRun())

        let judged = Date(timeIntervalSince1970: 1_770_000_042)
        let signalID = try await ledger.appendSignal(
            runID: runID, verdict: .down, recordedAt: judged
        )
        XCTAssertGreaterThan(signalID, 0)

        let signals = try await ledger.signals(forRun: runID)
        XCTAssertEqual(signals.count, 1)
        let read = try XCTUnwrap(signals.first)
        XCTAssertEqual(read.id, signalID)
        XCTAssertEqual(read.runID, runID)
        XCTAssertEqual(read.verdict, .down)
        // Millisecond resolution is what the column stores — the same accuracy contract as
        // `recordedAt` on a run row.
        XCTAssertEqual(
            read.recordedAt.timeIntervalSince1970,
            judged.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testARunWithNoSignalReadsBackAnEmptyHistory() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        let runID = try await ledger.append(anyRun())
        // "No signal yet" is the absence of rows, not a stored value — the reason `SignalVerdict`
        // has no third case.
        let signals = try await ledger.signals(forRun: runID)
        XCTAssertTrue(signals.isEmpty)
    }

    // MARK: - The duplicate policy's read rule (rider one, enforced)

    func testASecondSignalSupersedesAndTheHighestIdWins() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        let runID = try await ledger.append(anyRun())

        let firstID = try await ledger.appendSignal(
            runID: runID,
            verdict: .up,
            recordedAt: Date(timeIntervalSince1970: 1_770_000_042)
        )
        let secondID = try await ledger.appendSignal(
            runID: runID,
            verdict: .down,
            recordedAt: Date(timeIntervalSince1970: 1_770_000_050)
        )
        XCTAssertGreaterThan(
            secondID, firstID,
            "append order must be the id order, or the rule is ill-founded"
        )

        let signals = try await ledger.signals(forRun: runID)
        XCTAssertEqual(
            signals.map(\.id), [firstID, secondID],
            "history in append order, superseded row retained"
        )
        XCTAssertEqual(
            signals.last?.verdict, .down,
            "the later judgement is the current verdict — the read rule recorded at the schema"
        )
    }

    // MARK: - Refusals

    func testASignalForAnUnknownRunIsRefusedByTheForeignKey() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        do {
            _ = try await ledger.appendSignal(
                runID: 999,
                verdict: .up,
                recordedAt: Date(timeIntervalSince1970: 1_770_000_042)
            )
            XCTFail("a signal naming a run the ledger never recorded must be refused")
        } catch {
            XCTAssertEqual(error, LedgerError.appendFailed)
        }
    }

    func testUpdateAndDeleteOnRunSignalsAreRefusedFromAnOutsideConnection() async throws {
        let url = try temporaryDatabaseURL()
        let ledger = RunLedger(location: .file(url))
        try await ledger.open()
        let runID = try await ledger.append(anyRun())
        try await ledger.appendSignal(
            runID: runID,
            verdict: .up,
            recordedAt: Date(timeIntervalSince1970: 1_770_000_042)
        )

        // From OUTSIDE the module, like the smoke suite's trigger proof: the enforcement lives in
        // the file, so it must hold for a connection that never heard of `RunLedger`.
        let (updateCode, updateMessage) = try executeRaw(
            "UPDATE run_signals SET verdict = 'down' WHERE id = 1",
            at: url
        )
        XCTAssertEqual(updateCode, SQLITE_CONSTRAINT, "an UPDATE must be refused, not applied")
        XCTAssertTrue(updateMessage.contains("append-only"), "got: \(updateMessage)")

        let (deleteCode, deleteMessage) = try executeRaw("DELETE FROM run_signals", at: url)
        XCTAssertEqual(deleteCode, SQLITE_CONSTRAINT, "a DELETE must be refused, not applied")
        XCTAssertTrue(deleteMessage.contains("append-only"), "got: \(deleteMessage)")

        // The teeth: the row survived both refusals unchanged.
        let signals = try await ledger.signals(forRun: runID)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.verdict, .up)
    }

    // MARK: - The whole-file guarantee

    func testEveryUserTableHasBothAppendOnlyTriggers() async throws {
        let url = try temporaryDatabaseURL()
        let ledger = RunLedger(location: .file(url))
        try await ledger.open()

        // `sqlite_sequence` is AUTOINCREMENT's bookkeeping table, excluded by the sqlite_ prefix.
        let tables = try queryRawStrings(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            at: url
        )
        XCTAssertEqual(
            Set(tables), Set(LedgerSchema.appendOnlyTables),
            "every user table must be on the guarded list — an unguarded table is the decay "
                + "ADR-0009 warns about"
        )

        let triggers = try queryRawStrings(
            "SELECT name FROM sqlite_master WHERE type = 'trigger'",
            at: url
        )
        for table in tables {
            XCTAssertTrue(triggers.contains("\(table)_no_update"), "\(table) lacks _no_update")
            XCTAssertTrue(triggers.contains("\(table)_no_delete"), "\(table) lacks _no_delete")
        }
    }

    // MARK: - Helpers

    /// Open the ledger file directly, outside `RunLedger`, and run one statement — the smoke
    /// suite's pattern, for the same reason it exists there: the claim under test is about the
    /// file, not the API.
    private func executeRaw(_ sql: String, at url: URL) throws -> (Int32, String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(connection) }

        let code = sqlite3_exec(connection, sql, nil, nil, nil)
        let message = String(cString: sqlite3_errmsg(connection))
        return (code, message)
    }

    /// Run one single-text-column query over a raw outside connection and collect the rows.
    private func queryRawStrings(_ sql: String, at url: URL) throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(connection) }

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: text))
            }
        }
        return rows
    }
}
