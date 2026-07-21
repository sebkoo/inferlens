// The run ledger's smoke test: the schema migrates, a run survives the round trip through SQLite
// unchanged, and the append-only triggers actually bite.
//
// WHAT THIS IS AND IS NOT. This is the evidence for the claims THIS rung makes — no more. The full
// migration and append-only INVARIANT suite (a second migration applied over a v1 file, every CHECK
// constraint exercised, concurrent appenders, WAL behaviour) is its own ladder rung and lands in
// this same target later. Saying that here rather than letting the file's name imply coverage it
// does not have.
//
// The append-only proof is deliberately made from OUTSIDE the module: the test opens its own raw
// `sqlite3` connection to the same file and issues an UPDATE and a DELETE. That is the claim being
// tested — enforcement lives in the FILE, so it holds for any connection, not just callers who go
// through `RunLedger`'s API. A test that could only reach the database through an API with no
// mutation path would prove the discipline and say nothing about the mechanism.
//
// ISOLATION. Every test uses either `:memory:` or a fresh temporary directory removed in teardown.
// No test touches a shared or real ledger path: `test-clean`'s fresh `-derivedDataPath` isolates
// build products, not the filesystem, so file isolation is this file's job (ADR-0006).

import XCTest
import InferlensCore
import InferlensStore
import SQLite3

final class RunLedgerSmokeTests: XCTestCase {

    // MARK: - Fixtures

    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            self.temporaryDirectory = nil
        }
        try super.tearDownWithError()
    }

    /// A fresh, per-test database path under a directory this test owns and deletes.
    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferlens-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        return directory.appendingPathComponent("ledger.sqlite3")
    }

    private let device = DeviceIdentity(model: "iPhone17,1", osVersion: "iOS 26.1")

    private let model = ModelDescriptor(
        name: "MobileNetV2 (Google, FP32)",
        precision: .fp32,
        inputSize: PixelSize(width: 224, height: 224)
    )

    /// A record with every optional part populated, so the round trip has something to lose.
    private func coldRecord(at date: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> RunRecord {
        RunRecord(
            device: device,
            recordedAt: date,
            model: model,
            backend: .coreML,
            sample: LatencySample(
                load: .cold(.milliseconds(120)),
                run: RunTiming(preprocess: .milliseconds(3), infer: .milliseconds(17))
            ),
            classifications: [
                Classification(label: "class 281", confidence: 0.75),
                Classification(label: "class 282", confidence: 0.125),
            ],
            degradations: [.fellBack(from: .liteRT, to: .coreML), .thermallyThrottled]
        )
    }

    private func warmRecord(at date: Date = Date(timeIntervalSince1970: 1_770_000_100)) -> RunRecord {
        RunRecord(
            device: device,
            recordedAt: date,
            model: model,
            backend: .liteRT,
            sample: LatencySample(
                load: .warm,
                run: RunTiming(preprocess: .milliseconds(2), infer: .milliseconds(11))
            ),
            classifications: [Classification(label: "class 281", confidence: 0.9)]
        )
    }

    // MARK: - Migration

    func testAFreshDatabaseMigratesToTheLatestSchemaVersion() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        // 2 since the thumbs-signal migration. A later rung appending a migration moves this
        // number, which is the point of asserting it: the ladder step must be deliberate.
        let version = try await ledger.schemaVersion()
        XCTAssertEqual(version, 2)
    }

    func testOpenIsIdempotent() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        try await ledger.open()
        let version = try await ledger.schemaVersion()
        XCTAssertEqual(version, 2)
    }

    func testCallsBeforeOpenAreATypedErrorNotATrap() async throws {
        let ledger = RunLedger(location: .inMemory)
        do {
            _ = try await ledger.append(warmRecord())
            XCTFail("append before open should throw")
        } catch {
            XCTAssertEqual(error, LedgerError.notOpen)
        }
    }

    // MARK: - Round trip

    func testAColdRunRoundTripsWithItsClassificationsAndDegradations() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()

        let written = coldRecord()
        let id = try await ledger.append(written)
        XCTAssertGreaterThan(id, 0)

        let runs = try await ledger.recentRuns(limit: 10)
        XCTAssertEqual(runs.count, 1)
        let read = try XCTUnwrap(runs.first)
        XCTAssertEqual(read.id, id)

        // Invariant 7: the device and OS came back, or the latency below cannot be quoted.
        XCTAssertEqual(read.record.device, written.device)

        XCTAssertEqual(read.record.model.name, written.model.name)
        XCTAssertEqual(read.record.model.inputSize.width, 224)
        XCTAssertEqual(read.record.model.inputSize.height, 224)
        assertSamePrecision(read.record.model.precision, written.model.precision)
        assertSameBackend(read.record.backend, written.backend)

        // The cold/warm axis and the preprocess/infer split, exact — these are the benchmark.
        XCTAssertTrue(read.record.sample.isCold)
        XCTAssertEqual(read.record.sample.run.preprocess, .milliseconds(3))
        XCTAssertEqual(read.record.sample.run.infer, .milliseconds(17))
        XCTAssertEqual(read.record.sample.total, Duration.milliseconds(140))

        // Millisecond resolution is what the column stores; the round trip is exact at that
        // resolution for a whole-second fixture.
        XCTAssertEqual(
            read.record.recordedAt.timeIntervalSince1970,
            written.recordedAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        XCTAssertEqual(read.record.classifications.count, 2)
        XCTAssertEqual(read.record.classifications.first?.label, "class 281")
        XCTAssertEqual(read.record.classifications.first?.confidence ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(read.record.classifications.last?.label, "class 282")

        // Invariant 3: the fallback survived into the ledger, in order, still naming both backends.
        XCTAssertEqual(read.record.degradations.count, 2)
        switch read.record.degradations.first {
        case .fellBack(let from, let to):
            assertSameBackend(from, .liteRT)
            assertSameBackend(to, .coreML)
        default:
            XCTFail("expected the fallback to be the first recorded degradation")
        }
        switch read.record.degradations.last {
        case .thermallyThrottled: break
        default: XCTFail("expected the thermal degradation to survive the round trip")
        }
    }

    func testAWarmRunCarriesNoLoadTimeAndNoDegradations() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        try await ledger.append(warmRecord())

        let latest = try await ledger.recentRuns(limit: 1)
        let read = try XCTUnwrap(latest.first)
        XCTAssertFalse(read.record.sample.isCold)
        // A warm total is compute only — the load column was NULL, not zero.
        XCTAssertEqual(read.record.sample.total, Duration.milliseconds(13))
        XCTAssertTrue(read.record.degradations.isEmpty)
    }

    func testRecentRunsComeBackNewestFirstByAppendOrder() async throws {
        let ledger = RunLedger(location: .inMemory)
        try await ledger.open()
        let firstID = try await ledger.append(coldRecord())
        let secondID = try await ledger.append(warmRecord())

        let runs = try await ledger.recentRuns(limit: 10)
        XCTAssertEqual(runs.map(\.id), [secondID, firstID])
    }

    // MARK: - Append-only, proven from outside the module

    func testAnUpdateIsRefusedByTheDatabaseItself() async throws {
        let url = try temporaryDatabaseURL()
        let ledger = RunLedger(location: .file(url))
        try await ledger.open()
        try await ledger.append(coldRecord())

        let (code, message) = try executeRaw(
            "UPDATE runs SET infer_ns = 1 WHERE id = 1",
            at: url
        )
        XCTAssertEqual(code, SQLITE_CONSTRAINT, "an UPDATE must be refused, not silently applied")
        XCTAssertTrue(
            message.contains("append-only"),
            "the trigger should say why it refused; got: \(message)"
        )

        // The teeth: the row is unchanged, so the refusal was a real abort and not a no-op.
        let latest = try await ledger.recentRuns(limit: 1)
        let read = try XCTUnwrap(latest.first)
        XCTAssertEqual(read.record.sample.run.infer, .milliseconds(17))
    }

    func testADeleteIsRefusedByTheDatabaseItself() async throws {
        let url = try temporaryDatabaseURL()
        let ledger = RunLedger(location: .file(url))
        try await ledger.open()
        try await ledger.append(coldRecord())

        let (code, message) = try executeRaw("DELETE FROM runs WHERE id = 1", at: url)
        XCTAssertEqual(code, SQLITE_CONSTRAINT, "a DELETE must be refused, not silently applied")
        XCTAssertTrue(message.contains("append-only"), "got: \(message)")

        let runs = try await ledger.recentRuns(limit: 10)
        XCTAssertEqual(runs.count, 1, "the row must still be there after a refused DELETE")
    }

    // MARK: - Invariant 7

    func testDeviceIdentityNeverLetsTheSimulatorPassAsAPhone() {
        let identity = DeviceIdentity.current
        XCTAssertTrue(
            identity.model.hasPrefix("Simulator ("),
            "this suite runs on the simulator; a row claiming a device model here would poison the "
                + "latency table at the source. Got: \(identity.model)"
        )
        XCTAssertTrue(identity.osVersion.hasPrefix("iOS "), "got: \(identity.osVersion)")
    }

    // MARK: - Helpers

    /// Open the ledger file directly, outside `RunLedger`, and run one statement. Returns the raw
    /// result code and SQLite's own message — the only place in the test suite that touches a result
    /// code, because proving the trigger fired means naming the code it fires with.
    private func executeRaw(_ sql: String, at url: URL) throws -> (Int32, String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(connection) }

        let code = sqlite3_exec(connection, sql, nil, nil, nil)
        let message = String(cString: sqlite3_errmsg(connection))
        return (code, message)
    }

    /// `Backend` and `Precision` are not `Equatable` in Core (they are contract vocabulary, not
    /// comparison types), so the assertions switch rather than reaching for `==`.
    private func assertSameBackend(_ lhs: Backend, _ rhs: Backend, line: UInt = #line) {
        switch (lhs, rhs) {
        case (.coreML, .coreML), (.liteRT, .liteRT), (.remote, .remote): break
        default: XCTFail("backend mismatch", line: line)
        }
    }

    private func assertSamePrecision(_ lhs: Precision, _ rhs: Precision, line: UInt = #line) {
        switch (lhs, rhs) {
        case (.fp32, .fp32), (.fp16, .fp16), (.int8, .int8): break
        default: XCTFail("precision mismatch", line: line)
        }
    }
}
