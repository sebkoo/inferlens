// The offline eval's spec: the ratified refusal threshold at its exact boundary, the identity
// between this tool's numbers and `LatencyRecorder`'s, the refusals named by line and key, and the
// report pinned to the byte.
//
// NO CLOCK IS READ ANYWHERE IN THIS FILE. Every number under test comes from a row's own columns, so
// every assertion produces the same verdict on a pinned local simulator and on a shared, virtualized
// CI runner. That is the rung-31 lesson applied at authoring time rather than after a red build:
// a check that measures the machine it runs on is weather, not evidence.
//
// The goldens below were AUTHORED FROM THE RENDER RULES, not captured from a run. If an
// implementation change makes one fail, the question is which of the two is wrong — regenerating a
// golden to match the code it is supposed to constrain turns a spec into a screenshot.

import XCTest
import CryptoKit
import InferlensBench
import InferlensCore
@testable import InferlensEval

final class LedgerEvalTests: XCTestCase {

    // MARK: - The real export, byte for byte

    /// The fixture IS the `demo-sim-ac8d402` release asset, and the spec proves it rather than
    /// asserting it in a comment. Without this, "the tool reads what the app actually exports" would
    /// rest on whoever copied the file having copied the right one.
    ///
    /// The expected digest is the value published in the release notes, not one computed from the
    /// file in the tree — so editing the fixture to make another test pass fails HERE, loudly.
    func testTheFixtureIsThePublishedReleaseAssetByteForByte() throws {
        let data = try Data(contentsOf: try fixtureURL())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest,
            "dab26389037e265fa06d049cf9385b07fc85deba58aeb63f9755c87eff603700",
            "the fixture must be the published demo-sim-ac8d402 exported-runs.ndjson, unedited"
        )
        XCTAssertEqual(data.count, 166_609)
    }

    /// The whole report over the real export, to the byte.
    ///
    /// This is the rung's central claim in one assertion: on the corpus that exists today the tool
    /// REFUSES, it names both shortfalls, and it prints what would satisfy it. A tool that answered
    /// here would be the failure the threshold exists to prevent.
    func testTheRealExportRendersTheRefusalReportByteForByte() throws {
        let ndjson = try String(contentsOf: try fixtureURL(), encoding: .utf8)
        let result = try LedgerEval.evaluate(ndjson: ndjson)

        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.verdict, .refused)
        XCTAssertEqual(result.rendered(), """
        inferlens-eval — offline eval over the ledger export
        rows: 2

        LATENCY
        p50/p95 by nearest-rank over the rows' own columns, computed by InferlensBench.LatencyRecorder.
        Cold totals include model load; warm totals do not.

          Simulator (iPhone18,1) · iOS 26.1
            backend  load  n  total p50  total p95  preprocess p50  preprocess p95  infer p50  infer p95
            liteRT   cold  1  151.58 ms  151.58 ms         4.83 ms         4.83 ms    8.82 ms    8.82 ms
            liteRT   warm  1   13.24 ms   13.24 ms         4.60 ms         4.60 ms    8.65 ms    8.65 ms

        SIGNAL
        Reported, not weighed. The last signal on a run is its verdict; earlier ones are history.

          Simulator (iPhone18,1) · iOS 26.1
            backend  up  down  unjudged
            liteRT    1     0         1

        VERDICT
        No recommendation.

          Simulator (iPhone18,1) · iOS 26.1: no recommendation — liteRT has 1 warm row (needs 20); fewer than two backends measured.

        The threshold is 20 warm rows per backend within one device and OS. Below 20, the
        nearest-rank p95 is the slowest run rather than a percentile, so a comparison would compare
        two worst cases. The verdict weighs latency only; the signal table above is reported and not
        weighed — weighing it would need a second ratified threshold.

        """)
    }

    /// Invariant 7 reaching the output: the numbers above are the numbers in the file's own columns,
    /// under the device and OS the file's own columns name. Asserted separately from the golden so a
    /// layout change cannot quietly take the arithmetic claim with it.
    func testTheRealExportsNumbersAreTheRowsOwnColumns() throws {
        let ndjson = try String(contentsOf: try fixtureURL(), encoding: .utf8)
        let scope = try XCTUnwrap(try LedgerEval.evaluate(ndjson: ndjson).scopes.first)

        XCTAssertEqual(scope.device, "Simulator (iPhone18,1)")
        XCTAssertEqual(scope.osVersion, "iOS 26.1")
        let liteRT = try XCTUnwrap(scope.backends.first)
        XCTAssertEqual(liteRT.backend, "liteRT")

        // Cold: load 137_931_875 + preprocess 4_828_792 + infer 8_822_000 = 151_582_667 ns.
        let cold = try XCTUnwrap(liteRT.latency.cold)
        XCTAssertEqual(cold.sampleCount, 1)
        XCTAssertEqual(nanoseconds(cold.total.p50), 151_582_667, "cold total carries the load")
        XCTAssertEqual(nanoseconds(cold.infer.p50), 8_822_000)

        // Warm: no load, so total is preprocess + infer = 4_596_042 + 8_645_917.
        let warm = try XCTUnwrap(liteRT.latency.warm)
        XCTAssertEqual(warm.sampleCount, 1)
        XCTAssertEqual(nanoseconds(warm.total.p50), 13_241_959, "warm total is compute only")

        XCTAssertEqual(liteRT.signal, SignalTally(up: 1, down: 0, unjudged: 1))
    }

    // MARK: - The ratified threshold, at its boundary

    /// The teeth of ADR-0015 Decision 3. 19 rows refuses, 20 recommends — and the number is asserted
    /// as a literal, not read from the constant, so changing the constant fails here rather than
    /// silently redefining what "enough evidence" means.
    func testTwentyWarmRowsPerBackendIsTheThreshold() throws {
        XCTAssertEqual(minimumWarmRowsPerBackend, 20, "the ratified value — invariant 1, applied offline")

        let nineteen = ndjson(
            warmRows(backend: "coreML", count: 19, inferNs: 5_000_000)
                + warmRows(backend: "liteRT", count: 19, inferNs: 9_000_000)
        )
        XCTAssertEqual(try LedgerEval.evaluate(ndjson: nineteen).verdict, .refused)

        let twenty = ndjson(
            warmRows(backend: "coreML", count: 20, inferNs: 5_000_000)
                + warmRows(backend: "liteRT", count: 20, inferNs: 9_000_000)
        )
        let result = try LedgerEval.evaluate(ndjson: twenty)
        XCTAssertEqual(result.verdict, .recommended)
        XCTAssertEqual(
            try XCTUnwrap(result.scopes.first).verdict,
            .recommended(backend: "coreML", runnerUp: "liteRT"),
            "the faster warm total p95 wins"
        )
    }

    /// One eligible backend is a measurement, not a comparison. The tool refuses even though the
    /// backend it could name has ample evidence.
    func testOneEligibleBackendIsNotAComparison() throws {
        let text = ndjson(
            warmRows(backend: "coreML", count: 20, inferNs: 5_000_000)
                + warmRows(backend: "liteRT", count: 19, inferNs: 9_000_000)
        )
        let scope = try XCTUnwrap(try LedgerEval.evaluate(ndjson: text).scopes.first)
        XCTAssertEqual(
            scope.verdict,
            .refused(shortfalls: ["liteRT has 19 warm rows (needs 20)"]),
            "the shortfall names the backend that is short, and not the one that is not"
        )
    }

    /// A tie refuses rather than breaking it on a quantity nobody ratified.
    func testATieAtWarmTotalP95Refuses() throws {
        let text = ndjson(
            warmRows(backend: "coreML", count: 20, inferNs: 5_000_000)
                + warmRows(backend: "liteRT", count: 20, inferNs: 5_000_000)
        )
        let scope = try XCTUnwrap(try LedgerEval.evaluate(ndjson: text).scopes.first)
        XCTAssertEqual(
            scope.verdict,
            .refused(shortfalls: ["coreML and liteRT tie at warm total p95"])
        )
    }

    // MARK: - Reuse, asserted as identity

    /// The claim that cannot be satisfied by writing a second implementation.
    ///
    /// The same series of runs is put through `LatencyRecorder` directly and through the eval's whole
    /// parse-and-group path, and the two `LatencySummary` values must be EQUAL. A test that compared
    /// the eval's output to hand-computed constants would pass just as well against a reimplemented
    /// percentile; this one holds only if the ratified code is the code that ran.
    func testTheEvalsNumbersAreTheRecordersNumbers() throws {
        // Deliberately irregular, and deliberately mixed cold/warm: an aggregation that pooled the
        // buckets, sorted differently, or interpolated a percentile would diverge here.
        let timings: [(preprocess: Int64, infer: Int64, load: Int64?)] = [
            (1_100_000, 7_300_000, 210_000_000),
            (1_900_000, 6_200_000, nil),
            (1_050_000, 9_900_000, nil),
            (2_400_000, 6_050_000, nil),
            (1_300_000, 8_800_000, nil),
            (1_700_000, 7_000_000, 198_000_000),
            (1_020_000, 12_400_000, nil),
        ]

        let samples = timings.map { timing in
            LatencySample(
                load: timing.load.map { LoadTiming.cold(.nanoseconds($0)) } ?? .warm,
                run: RunTiming(
                    preprocess: .nanoseconds(timing.preprocess),
                    infer: .nanoseconds(timing.infer)
                )
            )
        }
        let expected = try LatencyRecorder().summarize(samples)

        let lines = timings.enumerated().map { index, timing in
            row(
                id: index + 1,
                backend: "liteRT",
                loadNs: timing.load,
                preprocessNs: timing.preprocess,
                inferNs: timing.infer
            )
        }
        let actual = try XCTUnwrap(
            try LedgerEval.evaluate(ndjson: ndjson(lines)).scopes.first?.backends.first?.latency
        )

        XCTAssertEqual(actual, expected, "the eval must not compute a percentile; it must call the one that exists")
        XCTAssertEqual(actual.cold?.sampleCount, 2)
        XCTAssertEqual(actual.warm?.sampleCount, 5, "the cold rows are reported, never pooled into warm")
    }

    // MARK: - Two backends, one machine

    /// The comparison table, to the byte. This is the shape the real fixture cannot exercise — it
    /// holds one backend — so the case that the whole tool exists for is pinned here.
    func testTwoBackendsRenderInOneScopeUnderTheirSharedDeviceAndOS() throws {
        let text = ndjson(
            warmRows(backend: "liteRT", count: 2, preprocessNs: 2_000_000, inferNs: 9_000_000)
                + warmRows(backend: "coreML", count: 2, preprocessNs: 1_000_000, inferNs: 5_000_000)
        )

        XCTAssertEqual(try LedgerEval.evaluate(ndjson: text).rendered(), """
        inferlens-eval — offline eval over the ledger export
        rows: 4

        LATENCY
        p50/p95 by nearest-rank over the rows' own columns, computed by InferlensBench.LatencyRecorder.
        Cold totals include model load; warm totals do not.

          iPhone17,1 · iOS 26.1
            backend  load  n  total p50  total p95  preprocess p50  preprocess p95  infer p50  infer p95
            coreML   warm  2    6.00 ms    6.00 ms         1.00 ms         1.00 ms    5.00 ms    5.00 ms
            liteRT   warm  2   11.00 ms   11.00 ms         2.00 ms         2.00 ms    9.00 ms    9.00 ms

        SIGNAL
        Reported, not weighed. The last signal on a run is its verdict; earlier ones are history.

          iPhone17,1 · iOS 26.1
            backend  up  down  unjudged
            coreML    0     0         2
            liteRT    0     0         2

        VERDICT
        No recommendation.

          iPhone17,1 · iOS 26.1: no recommendation — coreML has 2 warm rows (needs 20); liteRT has 2 warm rows (needs 20).

        The threshold is 20 warm rows per backend within one device and OS. Below 20, the
        nearest-rank p95 is the slowest run rather than a percentile, so a comparison would compare
        two worst cases. The verdict weighs latency only; the signal table above is reported and not
        weighed — weighing it would need a second ratified threshold.

        """)
    }

    /// Invariant 7, enforced rather than captioned: a phone's rows and a simulator's are never one
    /// population, so the same backend measured on two machines is two scopes and never one p95.
    func testRowsFromTwoMachinesAreNeverPooled() throws {
        let text = ndjson(
            warmRows(backend: "liteRT", count: 20, device: "iPhone17,1", inferNs: 5_000_000)
                + warmRows(backend: "coreML", count: 20, device: "Simulator (iPhone18,1)", inferNs: 9_000_000)
        )
        let result = try LedgerEval.evaluate(ndjson: text)

        XCTAssertEqual(result.scopes.count, 2, "two machines, two scopes")
        XCTAssertEqual(result.scopes.map(\.device), ["Simulator (iPhone18,1)", "iPhone17,1"])
        for scope in result.scopes {
            XCTAssertEqual(scope.backends.count, 1, "no backend appears outside the machine it ran on")
        }
        XCTAssertEqual(
            result.verdict, .refused,
            "twenty rows each, but on different machines — that is not a comparison this tool will make"
        )
    }

    // MARK: - The signal table

    /// The schema's read rule, carried through the export and applied here: the LAST signal is the
    /// verdict, the earlier ones are the record of somebody changing their mind.
    func testTheLastSignalOnARunIsItsVerdict() throws {
        let text = ndjson([
            row(id: 1, backend: "liteRT", signals: ["down", "up"]),
            row(id: 2, backend: "liteRT", signals: ["up", "down"]),
            row(id: 3, backend: "liteRT", signals: []),
        ])
        let tally = try XCTUnwrap(
            try LedgerEval.evaluate(ndjson: text).scopes.first?.backends.first?.signal
        )
        XCTAssertEqual(tally, SignalTally(up: 1, down: 1, unjudged: 1))
        XCTAssertEqual(tally.judged, 2, "an unjudged run is never counted as agreement")
    }

    // MARK: - Refusals, named

    func testAMissingKeyIsRefusedByLineAndKey() {
        assertRefused(
            ndjson([
                row(id: 1, backend: "liteRT"),
                row(id: 2, backend: "liteRT", omitting: "infer_ns"),
            ]),
            with: .missingKey(line: 2, key: "infer_ns")
        )
    }

    /// The version gate this format cannot have, in the form it can.
    ///
    /// The NDJSON carries NO version field (ADR-0015, Decision 5), so a file written by a newer
    /// exporter cannot announce itself. What it can do is carry a key this build has never heard of —
    /// and that is refused, rather than silently ignored, which is what a synthesized `Decodable`
    /// would do and what would let this tool report numbers over a format it does not understand.
    func testAnUnknownKeyIsRefusedRatherThanIgnored() {
        let future = addingKey("\"schema_version\":3", to: row(id: 1, backend: "liteRT"))
        assertRefused(ndjson([future]), with: .unknownKey(line: 1, key: "schema_version"))
    }

    /// `load_ns` is present exactly when the row is cold. Both directions are contradictions, and
    /// both are refused rather than interpreted.
    func testTheLoadKeyMustAgreeWithTheColdFlag() {
        let coldWithoutLoad = row(id: 1, backend: "liteRT", loadNs: 210_000_000, omitting: "load_ns")
        assertRefused(ndjson([coldWithoutLoad]), with: .loadTimingMismatch(line: 1, isCold: true))

        let warmWithLoad = addingKey("\"load_ns\":210000000", to: row(id: 1, backend: "liteRT"))
        assertRefused(ndjson([warmWithLoad]), with: .loadTimingMismatch(line: 1, isCold: false))
    }

    func testALineThatIsNotAJSONObjectIsRefused() {
        assertRefused(ndjson([row(id: 1, backend: "liteRT"), "[1, 2, 3]"]), with: .notJSONObject(line: 2))
        assertRefused(ndjson(["{oops"]), with: .notJSONObject(line: 1))
    }

    func testAValueOfTheWrongTypeIsRefusedAtItsPath() {
        let text = row(id: 1, backend: "liteRT").replacingOccurrences(
            of: "\"infer_ns\":8000000",
            with: "\"infer_ns\":\"fast\""
        )
        assertRefused(ndjson([text]), with: .badValue(line: 1, path: "infer_ns"))
    }

    /// A verdict token this build does not know is a bad value, and the refusal points at the
    /// element rather than at the row.
    func testAnUnknownSignalVerdictIsRefusedAtItsIndex() {
        let text = row(id: 1, backend: "liteRT", signals: ["up", "maybe"])
        assertRefused(ndjson([text]), with: .badValue(line: 1, path: "signals[1].verdict"))
    }

    func testAFileWithNoRowsIsRefused() {
        assertRefused("", with: .noRows)
        assertRefused("\n\n", with: .noRows, "blank lines are not rows")
    }

    /// One malformed row refuses the WHOLE file. A report over "the rows that happened to parse" is a
    /// statistic about an unknown subset, which is worse than no report.
    func testOneBadRowRefusesTheWholeFileRatherThanSkippingIt() {
        let text = ndjson([
            row(id: 1, backend: "liteRT"),
            row(id: 2, backend: "liteRT", omitting: "backend"),
            row(id: 3, backend: "liteRT"),
        ])
        assertRefused(text, with: .missingKey(line: 2, key: "backend"))
    }

    // MARK: - Fixtures

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: "demo-sim-ac8d402",
                withExtension: "ndjson",
                subdirectory: "Fixtures"
            ),
            "the released export must be bundled with this test target"
        )
    }

    /// One exported line, spelled the way `LedgerExport` spells it — the same keys, the same tokens,
    /// the same nil-omission for `load_ns`.
    private func row(
        id: Int,
        device: String = "iPhone17,1",
        osVersion: String = "iOS 26.1",
        backend: String,
        loadNs: Int64? = nil,
        preprocessNs: Int64 = 2_000_000,
        inferNs: Int64 = 8_000_000,
        signals: [String] = [],
        omitting omittedKey: String? = nil
    ) -> String {
        let signalObjects = signals.enumerated().map { index, verdict in
            "{\"id\":\(index + 1),\"recorded_at_ms\":1770000000000,\"verdict\":\"\(verdict)\"}"
        }
        var fields = [
            "\"id\":\(id)",
            "\"recorded_at_ms\":1770000000000",
            "\"device_model\":\"\(device)\"",
            "\"os_version\":\"\(osVersion)\"",
            "\"model_name\":\"MobileNetV2\"",
            "\"model_precision\":\"fp32\"",
            "\"model_input_width\":224",
            "\"model_input_height\":224",
            "\"backend\":\"\(backend)\"",
            "\"is_cold\":\(loadNs == nil ? 0 : 1)",
            "\"preprocess_ns\":\(preprocessNs)",
            "\"infer_ns\":\(inferNs)",
            "\"classifications\":[{\"ordinal\":0,\"label\":\"cliff, drop, drop-off\",\"confidence\":0.65}]",
            "\"degradations\":[]",
            "\"signals\":[\(signalObjects.joined(separator: ","))]",
        ]
        if let loadNs {
            fields.append("\"load_ns\":\(loadNs)")
        }
        if let omittedKey {
            fields.removeAll { $0.hasPrefix("\"\(omittedKey)\":") }
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private func warmRows(
        backend: String,
        count: Int,
        device: String = "iPhone17,1",
        preprocessNs: Int64 = 2_000_000,
        inferNs: Int64
    ) -> [String] {
        (0 ..< count).map { index in
            row(
                id: index + 1,
                device: device,
                backend: backend,
                preprocessNs: preprocessNs,
                inferNs: inferNs
            )
        }
    }

    private func ndjson(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    /// Prepend one field to an otherwise valid line. The point of these fixtures is that they are a
    /// VALID line with exactly one thing wrong, so the refusal under test cannot have been produced
    /// by anything else.
    private func addingKey(_ field: String, to line: String) -> String {
        "{\(field),\(line.dropFirst())"
    }

    private func assertRefused(
        _ ndjson: String,
        with expected: EvalError,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try LedgerEval.evaluate(ndjson: ndjson)
            XCTFail("expected a refusal, got a report. \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        }
    }
}
