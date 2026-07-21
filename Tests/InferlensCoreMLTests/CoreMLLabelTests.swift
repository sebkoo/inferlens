// The other half of "one table, both engines".
//
// The Core ML engine has always returned words — a Core ML classifier carries its own label strings
// — so nothing here is about making it readable. What is under test is that the words it returns are
// rows of the SAME table the LiteRT engine maps indices through, and that the index it reports is
// recovered from that table rather than invented.
//
// The two engines are checked separately, against the same file, rather than against each other.
// That is deliberate and it is ADR-0003: the models have independently trained weights, so
// cross-model agreement is a measured and published result in this repo, never an assertion. A test
// here that ran both engines on one image and demanded the same answer would be quietly converting a
// benchmark finding into a gate.
//
// What this file does NOT read: ordering. Whether index N means the same thing to the model and to
// the table is proved in Tests/InferlensLiteRTTests, where a fixture with a known subject is run
// through the engine. Nothing here could establish it — this engine never sees an index at all.

import XCTest

import InferlensCore
import InferlensCoreML

final class CoreMLLabelTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/InferlensCoreMLTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <repo>
    }

    private func bootstrappedFile(_ relativePath: String) throws -> URL {
        let url = repoRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "not fetched — run `make bootstrap` (git-ignored; ADR-0002). expected at \(url.path)"
            )
        }
        return url
    }

    private func modelURL() throws -> URL {
        try bootstrappedFile("Vendor/Models/MobileNetV2FP16.mlmodel")
    }

    /// The shipped table, read from the file `make bootstrap` derives — the same bytes the LiteRT
    /// spec reads and the same the app loads.
    private func derivedTable() throws -> LabelTable {
        let url = try bootstrappedFile("Vendor/Models/imagenet_labels.txt")
        return LabelTable(text: try String(contentsOf: url, encoding: .utf8))
    }

    private func gradientImage() throws -> ImageBuffer {
        let width = 200, height = 200
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in bytes.indices { bytes[i] = UInt8(i % 256) }
        return try ImageBuffer(width: width, height: height, pixelFormat: .rgba8, bytes: bytes)
    }

    /// Every label this engine emits is a row of the table.
    ///
    /// This is the strongest available statement that the table really is derived from THIS model:
    /// the table was extracted from the `.mlmodel`'s embedded label vector, so if extraction had
    /// picked up the wrong vector — or dropped, reordered or mangled entries — the model's own output
    /// keys would stop matching it. 1001 agreeing strings is not something a wrong extraction
    /// produces.
    func testEveryLabelTheModelEmitsIsARowOfTheTable() async throws {
        let table = try derivedTable()
        let engine = CoreMLEngine(modelURL: try modelURL(), labels: table)
        try await engine.loadModel()

        let outcome = try await engine.classify(try gradientImage())

        // 1000, not 1001 — and the missing one is not a rounding error, it is a CLASS.
        //
        // Core ML hands a classifier's output back as `classLabelProbs`, a [String: probability]
        // DICTIONARY keyed by label. The model has 1001 output positions but only 1000 distinct
        // label strings, because `"crane"` is the name of both index 135 (the bird) and index 518
        // (the machine). Two positions, one key: the dictionary keeps one probability and the other
        // is gone before this engine ever sees it, with no error and nothing to observe it by.
        //
        // This was true before labels existed and nothing could have noticed — a count nobody took,
        // over classes nobody could tell apart. It is asserted here rather than smoothed over so the
        // number stays a statement about the engine. Recorded as a finding in docs/ROADMAP.md; the
        // fix is to read the raw output vector instead of the label dictionary, which is a change to
        // this engine's contract with Core ML and not this rung's to make.
        let distinctLabels = Set((0 ..< table.count).compactMap { table.label(at: $0) })
        XCTAssertEqual(
            outcome.classifications.count, distinctLabels.count,
            """
            The model has \(table.count) output positions but Core ML returns a dictionary keyed by \
            label, and only \(distinctLabels.count) of those labels are distinct.
            """
        )

        for classification in outcome.classifications {
            XCTAssertNotNil(
                table.index(of: classification.label) ?? knownAmbiguousIndex(classification.label),
                "\(classification.label) is not a row of the table this engine was given"
            )
        }
    }

    /// The index is RECOVERED, not invented: for a label the table resolves, the reported index is
    /// the position that table gives it.
    func testReportedIndexIsTheTablesPositionForThatLabel() async throws {
        let table = try derivedTable()
        let engine = CoreMLEngine(modelURL: try modelURL(), labels: table)
        try await engine.loadModel()

        let outcome = try await engine.classify(try gradientImage())

        var resolved = 0
        for classification in outcome.classifications {
            guard let index = classification.index else { continue }
            XCTAssertEqual(
                table.label(at: index), classification.label,
                "index \(index) must name the label it was reported for"
            )
            resolved += 1
        }
        // 1000 classifications survive the dictionary (see the count test), and exactly one of them
        // is `"crane"`, which resolves to no index because the table holds it twice. So 999.
        XCTAssertEqual(resolved, 999, "every unambiguous label resolves to its position")
    }

    /// With no table the engine still names classes — it always could — and simply reports no index.
    /// The default is `nil`, so this is also the proof that the labelling change did not make a table
    /// mandatory for an engine that never needed one.
    func testWithoutATableLabelsSurviveAndIndicesAreAbsent() async throws {
        let engine = CoreMLEngine(modelURL: try modelURL())
        try await engine.loadModel()

        let outcome = try await engine.classify(try gradientImage())
        let top = try XCTUnwrap(outcome.classifications.first)

        XCTAssertFalse(top.label.isEmpty)
        XCTAssertFalse(top.label.hasPrefix("class "), "a Core ML classifier names its own classes")
        XCTAssertTrue(
            outcome.classifications.allSatisfy { $0.index == nil },
            "with no table there is nothing to recover a position from"
        )
    }

    /// `"crane"` is at index 135 (the bird) and 518 (the machine), so it resolves to neither. This
    /// asserts the ambiguity is real in the SHIPPED table, not merely handled in the type — the
    /// LabelTable spec proves the behaviour, this proves the case exists here.
    private func knownAmbiguousIndex(_ label: String) -> Int? {
        label == "crane" ? 135 : nil
    }

    func testTheShippedTableReallyContainsTheAmbiguousLabel() throws {
        let table = try derivedTable()

        XCTAssertEqual(table.label(at: 135), "crane")
        XCTAssertEqual(table.label(at: 518), "crane")
        XCTAssertNil(table.index(of: "crane"), "two positions, so no single index")
    }
}
