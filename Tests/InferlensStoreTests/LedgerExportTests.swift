// The export's spec: one self-contained line per run, stored values passed through, the signal
// join embedded with its read rule intact, byte-determinism as a compared fact, refusals named.
//
// Lines are parsed back with JSONSerialization, never the module's own types, on purpose: the
// reader being specified is offline tooling that knows nothing of this codebase, so the
// assertions read the file the way jq would — including the difference between an absent key and
// a null, which `Dictionary`'s subscript surfaces exactly.
//
// Every ledger here is a FILE in a per-test temporary directory, not `.inMemory` — the export
// opens its own second connection, and a second connection cannot see an in-memory database.
// That is a documented property of the exporter, and these tests inhabit it rather than fight it.

import XCTest
import InferlensCore
import SQLite3
import InferlensStore

final class LedgerExportTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            self.temporaryDirectory = nil
        }
        try super.tearDownWithError()
    }

    /// A fresh per-test directory this test owns and deletes — the isolation contract the store
    /// suite documents (ADR-0006). Both the ledger and the export land inside it.
    private func temporaryURL(_ name: String) throws -> URL {
        if temporaryDirectory == nil {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("inferlens-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory
        }
        return temporaryDirectory!.appendingPathComponent(name)
    }

    /// A run with every knob the export must carry; defaults are the smallest legal row.
    private func run(
        device: DeviceIdentity = DeviceIdentity(model: "iPhone17,1", osVersion: "iOS 26.1"),
        load: LoadTiming = .warm,
        classifications: [Classification] = [Classification(label: "class 281", confidence: 0.9)],
        degradations: [DegradationReason] = [],
        at date: Date = Date(timeIntervalSince1970: 1_770_000_000)
    ) -> RunRecord {
        RunRecord(
            device: device,
            recordedAt: date,
            model: ModelDescriptor(
                name: "MobileNetV2 (Google, FP32)",
                precision: .fp32,
                inputSize: PixelSize(width: 224, height: 224)
            ),
            backend: .liteRT,
            sample: LatencySample(
                load: load,
                run: RunTiming(preprocess: .milliseconds(2), infer: .milliseconds(11))
            ),
            classifications: classifications,
            degradations: degradations
        )
    }

    /// Export the ledger file and parse every line back the way offline tooling would.
    private func exportedLines(
        ledgerAt databaseURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [[String: Any]] {
        let destination = try temporaryURL("export-\(UUID().uuidString).ndjson")
        try LedgerExport.export(ledgerAt: databaseURL, to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)
        if !text.isEmpty {
            XCTAssertTrue(
                text.hasSuffix("\n"),
                "every NDJSON line is terminated, the last included",
                file: file,
                line: line
            )
        }
        return try text.split(separator: "\n").map { lineText in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(lineText.utf8)) as? [String: Any],
                "not one JSON object: \(lineText)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - One self-contained line per run

    func testEveryRunBecomesOneSelfContainedLine() async throws {
        let databaseURL = try temporaryURL("ledger.sqlite3")
        let ledger = RunLedger(location: .file(databaseURL))
        try await ledger.open()
        let firstID = try await ledger.append(run())
        let secondID = try await ledger.append(
            run(
                device: DeviceIdentity(model: "Simulator (iPhone18,1)", osVersion: "iOS 26.2"),
                at: Date(timeIntervalSince1970: 1_770_000_060)
            )
        )

        let lines = try exportedLines(ledgerAt: databaseURL)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0["id"] as? Int64 }, [firstID, secondID], "runs ascend by id")

        // Invariant 7 by construction: EVERY line names its machine, because the columns are
        // NOT NULL — no join, no sidecar file, no "see line 1".
        for line in lines {
            XCTAssertNotNil(line["device_model"] as? String)
            XCTAssertNotNil(line["os_version"] as? String)
            XCTAssertNotNil(line["model_name"] as? String)
            XCTAssertNotNil(line["backend"] as? String)
        }
        XCTAssertEqual(lines[0]["device_model"] as? String, "iPhone17,1")
        XCTAssertEqual(lines[1]["device_model"] as? String, "Simulator (iPhone18,1)")
        XCTAssertEqual(lines[1]["os_version"] as? String, "iOS 26.2")

        // Stored values pass through: tokens, 0/1, epoch milliseconds — the columns' own
        // vocabulary, not Swift's.
        XCTAssertEqual(lines[0]["backend"] as? String, "liteRT")
        XCTAssertEqual(lines[0]["model_precision"] as? String, "fp32")
        XCTAssertEqual(lines[0]["is_cold"] as? Int64, 0)
        XCTAssertEqual(lines[0]["recorded_at_ms"] as? Int64, 1_770_000_000_000)

        // A warm run has no load: the KEY is absent, not null — `Dictionary` reads NSNull as
        // non-nil, so this assertion can tell the two apart.
        XCTAssertNil(lines[0]["load_ns"])
    }

    func testTheFullVectorAndTheDegradationsAreEmbedded() async throws {
        let databaseURL = try temporaryURL("ledger.sqlite3")
        let ledger = RunLedger(location: .file(databaseURL))
        try await ledger.open()
        try await ledger.append(
            run(
                load: .cold(.milliseconds(214)),
                classifications: [
                    Classification(label: "golden retriever", confidence: 0.871),
                    Classification(label: "Labrador retriever", confidence: 0.062),
                    Classification(label: "kuvasz", confidence: 0.011),
                ],
                degradations: [
                    .fellBack(from: .liteRT, to: .coreML),
                    .thermallyThrottled,
                ]
            )
        )

        let lines = try exportedLines(ledgerAt: databaseURL)
        let line = try XCTUnwrap(lines.first)

        let classifications = try XCTUnwrap(line["classifications"] as? [[String: Any]])
        XCTAssertEqual(
            classifications.map { $0["label"] as? String },
            ["golden retriever", "Labrador retriever", "kuvasz"],
            "the vector in ordinal order — 0 is top-1"
        )
        XCTAssertEqual(classifications.map { $0["ordinal"] as? Int64 }, [0, 1, 2])
        let confidence = try XCTUnwrap(classifications[0]["confidence"] as? Double)
        XCTAssertEqual(confidence, 0.871, accuracy: 0.000001)

        let degradations = try XCTUnwrap(line["degradations"] as? [[String: Any]])
        XCTAssertEqual(degradations.count, 2)
        XCTAssertEqual(degradations[0]["kind"] as? String, "fellBack")
        XCTAssertEqual(degradations[0]["from_backend"] as? String, "liteRT")
        XCTAssertEqual(degradations[0]["to_backend"] as? String, "coreML")
        XCTAssertEqual(degradations[1]["kind"] as? String, "thermallyThrottled")
        XCTAssertNil(degradations[1]["from_backend"], "no pair on a non-fallback: key absent")
        XCTAssertNil(degradations[1]["to_backend"])

        // The cold half of the load_ns contract, paired with the warm half above.
        XCTAssertEqual(line["is_cold"] as? Int64, 1)
        XCTAssertEqual(line["load_ns"] as? Int64, 214_000_000)
    }

    // MARK: - The signal join (the read rule crosses the boundary)

    func testSignalsEmbedInAppendOrderAndTheLastOneWins() async throws {
        let databaseURL = try temporaryURL("ledger.sqlite3")
        let ledger = RunLedger(location: .file(databaseURL))
        try await ledger.open()
        let runID = try await ledger.append(run())
        let firstID = try await ledger.appendSignal(
            runID: runID, verdict: .up, recordedAt: Date(timeIntervalSince1970: 1_770_000_042)
        )
        let secondID = try await ledger.appendSignal(
            runID: runID, verdict: .down, recordedAt: Date(timeIntervalSince1970: 1_770_000_050)
        )

        let lines = try exportedLines(ledgerAt: databaseURL)
        let signals = try XCTUnwrap(lines.first?["signals"] as? [[String: Any]])

        XCTAssertEqual(
            signals.map { $0["id"] as? Int64 }, [firstID, secondID],
            "append order, superseded row carried — the history must survive the boundary"
        )
        XCTAssertEqual(signals.map { $0["verdict"] as? String }, ["up", "down"])
        XCTAssertEqual(
            signals.last?["verdict"] as? String, "down",
            "a reader takes the LAST element as the verdict — the schema's read rule, exported"
        )
    }

    func testARunWithNoSignalsCarriesAnExplicitEmptyArray() async throws {
        let databaseURL = try temporaryURL("ledger.sqlite3")
        let ledger = RunLedger(location: .file(databaseURL))
        try await ledger.open()
        try await ledger.append(run())

        let lines = try exportedLines(ledgerAt: databaseURL)
        let line = try XCTUnwrap(lines.first)

        XCTAssertTrue(line.keys.contains("signals"), "the key must be present, not absent")
        let signals = try XCTUnwrap(line["signals"] as? [Any])
        XCTAssertTrue(signals.isEmpty, "no judgements is an empty array, not a missing question")
    }

    // MARK: - Determinism, to the byte

    func testReExportingAnUnchangedLedgerIsByteIdentical() async throws {
        let databaseURL = try temporaryURL("ledger.sqlite3")
        let ledger = RunLedger(location: .file(databaseURL))
        try await ledger.open()
        let runID = try await ledger.append(
            run(
                load: .cold(.milliseconds(214)),
                classifications: [
                    Classification(label: "golden retriever", confidence: 0.871),
                    Classification(label: "kuvasz", confidence: 0.011),
                ],
                degradations: [.fellBack(from: .liteRT, to: .coreML)]
            )
        )
        try await ledger.appendSignal(
            runID: runID, verdict: .up, recordedAt: Date(timeIntervalSince1970: 1_770_000_042)
        )
        try await ledger.append(run(at: Date(timeIntervalSince1970: 1_770_000_060)))

        let first = try temporaryURL("first.ndjson")
        let second = try temporaryURL("second.ndjson")
        try LedgerExport.export(ledgerAt: databaseURL, to: first)
        try LedgerExport.export(ledgerAt: databaseURL, to: second)

        let firstData = try Data(contentsOf: first)
        XCTAssertFalse(firstData.isEmpty)
        XCTAssertEqual(
            firstData, try Data(contentsOf: second),
            "determinism is the contract the ORDER BYs and sortedKeys exist for; this is the backstop"
        )
    }

    // MARK: - Refusals, named

    func testAWrongVersionFileIsRefusedNamingBothVersions() throws {
        // A version-1 file, made the way a foreign tool would: a raw connection and a pragma. No
        // tables are needed — the gate must refuse before naming any.
        let databaseURL = try temporaryURL("old.sqlite3")
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
            ),
            SQLITE_OK
        )
        let connection = try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA user_version = 1", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(connection)

        // Outside the `do`, so the catch stays TYPED: a throwing call of a second error type in
        // the block would widen it to `any Error` and fail the XCTAssertEqual's type match.
        let destination = try temporaryURL("out.ndjson")
        do {
            try LedgerExport.export(ledgerAt: databaseURL, to: destination)
            XCTFail("a file the exporter cannot migrate must be refused, not guessed at")
        } catch {
            XCTAssertEqual(
                error, LedgerError.exportVersionMismatch(fileVersion: 1, requiredVersion: 2),
                "the refusal names both sides, so the reader knows which end is stale"
            )
        }
    }

    func testAMissingFileIsCannotOpen() throws {
        let missing = try temporaryURL("never-created.sqlite3")
        let destination = try temporaryURL("out.ndjson")
        do {
            try LedgerExport.export(ledgerAt: missing, to: destination)
            XCTFail("a read-only open of a missing file must refuse, never create")
        } catch {
            XCTAssertEqual(error, LedgerError.cannotOpen)
        }
    }

    // MARK: - The reader never blocks the writer

    func testExportSucceedsWhileTheWriterHoldsItsOpenConnection() async throws {
        let databaseURL = try temporaryURL("ledger.sqlite3")
        let ledger = RunLedger(location: .file(databaseURL))
        try await ledger.open()
        try await ledger.append(run())

        // The actor is alive and its write connection open — the state the share-sheet export
        // will always run in. The export reads through its own connection under WAL.
        let lines = try exportedLines(ledgerAt: databaseURL)
        XCTAssertEqual(lines.count, 1)

        // And the writer is unharmed: the ledger appends again after the export.
        let laterID = try await ledger.append(run(at: Date(timeIntervalSince1970: 1_770_000_060)))
        XCTAssertGreaterThan(laterID, 0)
    }
}
