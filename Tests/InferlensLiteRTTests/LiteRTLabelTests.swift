// The ordering proof: that index N of THIS model's output means what the table's row N says.
//
// This is the claim the whole labelling rung rests on, and it is the one that cannot be argued from
// the code. The `.tflite` carries no label strings at all (MODEL_PROVENANCE.md), so nothing inside
// the model can be consulted; the table is derived from Apple's `.mlmodel`, a DIFFERENT artifact
// with independently trained weights. That the two share an output ordering is a fact about how both
// were produced from TF-slim's 1001-class ImageNet arrangement — plausible, load-bearing, and
// therefore not something to assume.
//
// Three independent things establish it here, weakest to strongest:
//
//   1. COUNT. The table's length equals the model's own output dimension, read from the interpreter
//      rather than from a constant. Catches the classic off-by-one — a 1000-entry ImageNet list with
//      no background class — and nothing else.
//   2. SPOT-CHECKS against a source outside this repo. Upstream TensorFlow's `label_image` example
//      publishes its output for a reference image, naming indices with their labels. Those pairs are
//      asserted against our table. This is the strongest evidence available WITHOUT running anything,
//      and it is independent of Apple's model — it comes from Google's side of the comparison.
//   3. THE FIXTURE. The reference image itself, run through the real engine with the real table, must
//      name what the photograph shows. Ground truth here is not another model's opinion: it is what
//      the picture IS, checkable by looking at it. That is what makes this a proof of ORDERING rather
//      than of agreement between two models — a distinction ADR-0003 insists on, since cross-model
//      agreement is a measured, published result in this repo and never an assertion.
//
// What these tests do NOT read: they say nothing about how well the model classifies, and nothing
// about the Core ML engine. A disagreement between the two engines is data (ADR-0003), not a failure,
// and no test here asserts one against the other.

import XCTest

import CoreGraphics
import ImageIO
import InferlensCore
import InferlensLiteRT

final class LiteRTLabelTests: XCTestCase {
    // MARK: - Fetched inputs (git-ignored; `make bootstrap`)

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/InferlensLiteRTTests
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
        try bootstrappedFile("Vendor/Models/mobilenet_v2_1.0_224.tflite")
    }

    /// The table exactly as the app gets it: the file `make bootstrap` derives, parsed by the same
    /// initializer the composition uses. Reading the shipped artifact rather than building a table
    /// inline is the point — a spec over a hand-written array would prove nothing about the bytes
    /// that actually reach a user.
    private func derivedTable() throws -> LabelTable {
        let url = try bootstrappedFile("Vendor/Models/imagenet_labels.txt")
        return LabelTable(text: try String(contentsOf: url, encoding: .utf8))
    }

    private func fixtureURL() throws -> URL {
        try bootstrappedFile("Vendor/Fixtures/grace_hopper.bmp")
    }

    // MARK: - 1. Count

    /// The table's length must equal the model's OWN output width, read from the loaded interpreter.
    ///
    /// The engine does not expose its output tensor, so the count is observed the way a consumer
    /// sees it: one classification per output position. That keeps the assertion about the model
    /// rather than about a number typed here — 1001 appears below as the observed value's name, not
    /// as the source of truth.
    func testTableLengthEqualsTheModelsOutputDimension() async throws {
        let table = try derivedTable()
        let engine = LiteRTEngine(modelURL: try modelURL(), labels: table)
        try await engine.loadModel()

        let outcome = try await engine.classify(blankImage())

        XCTAssertEqual(
            table.count, outcome.classifications.count,
            """
            The label table holds \(table.count) labels but the model emits \
            \(outcome.classifications.count) scores. Every index would name the wrong class.
            """
        )
        XCTAssertEqual(table.count, 1001, "MobileNetV2 here is 1001-wide: index 0 background + 1000 ImageNet")
        XCTAssertEqual(table.label(at: 0), "background", "index 0 is TF-slim's background class")
    }

    // MARK: - 2. Spot-checks against upstream TensorFlow's published output

    /// Index/label pairs printed by upstream TensorFlow's `label_image` example, whose README records
    /// runs against this same MobileNet family. They are quoted here as an EXTERNAL fixture: they were
    /// read from that project's published output, not derived from anything in this repo, and they
    /// come from Google's side of the comparison while the table comes from Apple's. Eight agreeing
    /// points spanning 458–907 is not a coincidence two unrelated orderings produce.
    ///
    /// Compared on the FIRST synonym only. ImageNet labels are comma-separated synonym lists and the
    /// two projects print different amounts of them — upstream shows `cornet` where the table holds
    /// `cornet, horn, trumpet, trump`. The class is the same; the rendering is not, and asserting on
    /// the full string would be asserting about formatting rather than about ordering.
    func testKnownIndicesMatchUpstreamPublishedLabels() throws {
        let table = try derivedTable()
        let published: [Int: String] = [
            458: "bow tie",
            466: "bulletproof vest",
            514: "cornet",
            543: "drumstick",
            611: "jersey",
            653: "military uniform",
            835: "suit",
            907: "Windsor tie",
        ]

        for (index, expected) in published.sorted(by: { $0.key < $1.key }) {
            let label = try XCTUnwrap(table.label(at: index), "index \(index) is missing from the table")
            XCTAssertEqual(
                label.split(separator: ",").first.map(String.init), expected,
                "index \(index) should be \(expected) but the table says \(label)"
            )
        }
    }

    // MARK: - 3. The fixture — the ordering proof, end to end

    /// The real engine, the real table, and an image whose subject is known BY LOOKING AT IT.
    ///
    /// The fixture is upstream TensorFlow's own reference photograph for `label_image`: an official
    /// US Navy portrait of Grace Hopper in uniform — cap insignia, service ribbons, nameplate. Its
    /// expected top-1, `military uniform`, is judgeable by any person who opens the file, which is
    /// exactly the property this rung is about. If the table were shifted by even one position this
    /// assertion would name something else entirely.
    ///
    /// This is the test that would have caught a plausible-looking wrong table, and the one no amount
    /// of reading the code could replace.
    func testFixtureTopOneNamesWhatThePhotographShows() async throws {
        let table = try derivedTable()
        let engine = LiteRTEngine(modelURL: try modelURL(), labels: table)
        try await engine.loadModel()

        let outcome = try await engine.classify(try imageBuffer(at: try fixtureURL()))
        let top = try XCTUnwrap(outcome.classifications.first)

        // Printed so a failure shows what the model actually said, not merely that it disagreed.
        let top5 = outcome.classifications.prefix(5)
            .map { "\($0.index.map(String.init) ?? "?"): \($0.label) \(String(format: "%.3f", $0.confidence))" }
        print("fixture top-5 — \(top5.joined(separator: " | "))")

        XCTAssertEqual(
            top.label.split(separator: ",").first.map(String.init), "military uniform",
            """
            The fixture is a Navy portrait in full uniform; top-1 came back as \(top.label). \
            Either the label table is misaligned with the model's output ordering, or the fixture \
            is not the image it is pinned to be.
            """
        )
        XCTAssertEqual(top.index, 653, "the ordering this table was cross-checked at")
        XCTAssertGreaterThan(top.confidence, 0.5, "an unambiguous photo should not be a coin flip")
    }

    // MARK: - The fallback, which is the honest degradation

    /// No table: every class is `"class N"` — this engine's behaviour before labels existed. The
    /// index still travels, so nothing is lost, only unnamed.
    func testWithoutATableClassesKeepTheirIndexForm() async throws {
        let engine = LiteRTEngine(modelURL: try modelURL())
        try await engine.loadModel()

        let outcome = try await engine.classify(blankImage())
        let top = try XCTUnwrap(outcome.classifications.first)

        XCTAssertEqual(top.label, "class \(try XCTUnwrap(top.index))")
        XCTAssertTrue(
            outcome.classifications.allSatisfy { $0.label == "class \($0.index ?? -1)" },
            "with no table every class falls back, not just the first"
        )
    }

    /// A table of the WRONG LENGTH is refused whole, and the engine falls back to indices.
    ///
    /// This is the failure the count check exists for: a 1000-entry ImageNet list against a 1001-wide
    /// output. Every lookup in it would succeed and every word would be one class off, so partial use
    /// is the one outcome that must not happen. `"class N"` is unreadable but true; a confident wrong
    /// word is neither.
    func testAWrongSizedTableIsRefusedRatherThanUsedPartially() async throws {
        let full = try derivedTable()
        // The classic off-by-one: drop the background class, keep the other 1000.
        let shifted = LabelTable((1 ..< full.count).map { full.label(at: $0) ?? "" })
        XCTAssertEqual(shifted.count, 1000, "the wrong table under test is the one people actually ship")

        let engine = LiteRTEngine(modelURL: try modelURL(), labels: shifted)
        try await engine.loadModel()

        let outcome = try await engine.classify(blankImage())
        let top = try XCTUnwrap(outcome.classifications.first)

        XCTAssertEqual(
            top.label, "class \(try XCTUnwrap(top.index))",
            "a table that does not fit the model must name nothing at all"
        )
    }

    /// Same table, this engine: every word on screen is a row of the table it was given. The Core ML
    /// side asserts the same property against the same file, which is what makes "one table, both
    /// engines" a checked claim rather than a description of the composition.
    func testEveryEmittedLabelIsARowOfTheTable() async throws {
        let table = try derivedTable()
        let engine = LiteRTEngine(modelURL: try modelURL(), labels: table)
        try await engine.loadModel()

        let outcome = try await engine.classify(blankImage())

        for classification in outcome.classifications {
            let index = try XCTUnwrap(classification.index, "LiteRT always knows the position")
            XCTAssertEqual(
                classification.label, table.label(at: index),
                "label and index must name the same row"
            )
        }
    }

    // MARK: - Helpers

    private func blankImage() throws -> ImageBuffer {
        try ImageBuffer(
            width: 224, height: 224, pixelFormat: .rgba8,
            bytes: [UInt8](repeating: 0, count: 224 * 224 * 4)
        )
    }

    /// Decode an image file into the contract's `ImageBuffer`.
    ///
    /// ImageIO rather than UIKit: this target tests an engine, and an engine takes bytes. The draw
    /// into an explicit RGBA8 context is what makes the byte order a stated fact rather than whatever
    /// the source file happened to use — the fixture is a BMP, which is natively BGR and bottom-up.
    private func imageBuffer(at url: URL) throws -> ImageBuffer {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) is not decodable"
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil), "\(url.lastPathComponent) has no image at index 0"
        )

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew, "could not create an RGBA context for \(url.lastPathComponent)")

        return try ImageBuffer(width: width, height: height, pixelFormat: .rgba8, bytes: bytes)
    }
}
