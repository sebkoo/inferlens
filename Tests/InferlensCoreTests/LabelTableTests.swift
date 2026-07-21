// The label table's spec — the value type only. No model, no engine, no file: this is the mapping's
// own behaviour, and every claim here is decidable from the array it was constructed with.
//
// What this file does NOT read: whether the table is the RIGHT table for any model. Ordering, count
// against a real output tensor, and the words themselves are established where a model is actually
// loaded (Tests/InferlensLiteRTTests). A test that stated ordering here would be checking an array
// against itself.

import XCTest

import InferlensCore

final class LabelTableTests: XCTestCase {
    // MARK: - Lookup and its bounds

    func testLabelAtIndexReturnsTheLabel() {
        let table = LabelTable(["background", "tench", "goldfish"])

        XCTAssertEqual(table.count, 3)
        XCTAssertEqual(table.label(at: 0), "background")
        XCTAssertEqual(table.label(at: 2), "goldfish")
    }

    /// Out of range is `nil`, not a trap and not a placeholder — the caller owns what an unmappable
    /// index looks like. Negative is covered because an index arriving from arithmetic can be.
    func testOutOfRangeIndexIsNil() {
        let table = LabelTable(["background", "tench"])

        XCTAssertNil(table.label(at: 2), "one past the end is out of range")
        XCTAssertNil(table.label(at: 99))
        XCTAssertNil(table.label(at: -1), "a negative index must not trap")
    }

    func testEmptyTableAnswersNothing() {
        let table = LabelTable([])

        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(table.count, 0)
        XCTAssertNil(table.label(at: 0))
    }

    // MARK: - The fallback

    /// The fallback string is the LiteRT engine's pre-table output, character for character. If this
    /// ever drifts, an app with no table stops degrading to its old behaviour and starts degrading to
    /// something new — which is the kind of change that should have to be typed on purpose.
    func testFallbackLabelIsTheOriginalIndexForm() {
        XCTAssertEqual(LabelTable.fallbackLabel(for: 0), "class 0")
        XCTAssertEqual(LabelTable.fallbackLabel(for: 653), "class 653")
        XCTAssertEqual(LabelTable.fallbackLabel(for: 973), "class 973")
    }

    // MARK: - Parsing

    func testParsesNewlineDelimitedText() {
        let table = LabelTable(text: "background\ntench\ngoldfish\n")

        XCTAssertEqual(table.count, 3, "a trailing newline must not add a 1002nd class")
        XCTAssertEqual(table.label(at: 1), "tench")
    }

    func testParseDropsBlankLinesAndTrimsCarriageReturns() {
        let table = LabelTable(text: "background\r\n\ntench\r\n")

        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table.label(at: 0), "background", "a CRLF file must not yield 'background\\r'")
        XCTAssertEqual(table.label(at: 1), "tench")
    }

    /// Labels contain commas and spaces — `"tench, Tinca tinca"` is ONE label, not two. Stated
    /// because a comma-splitting parser is the obvious wrong guess, and it would silently produce a
    /// table roughly twice the right length with every index shifted.
    func testCommasInsideALabelAreNotSeparators() {
        let table = LabelTable(text: "tench, Tinca tinca\ngoldfish, Carassius auratus\n")

        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table.label(at: 0), "tench, Tinca tinca")
    }

    // MARK: - The reverse direction

    func testIndexOfLabelFindsIt() {
        let table = LabelTable(["background", "tench", "goldfish"])

        XCTAssertEqual(table.index(of: "background"), 0)
        XCTAssertEqual(table.index(of: "goldfish"), 2)
    }

    func testIndexOfUnknownLabelIsNil() {
        let table = LabelTable(["background", "tench"])

        XCTAssertNil(table.index(of: "goldfish"))
        XCTAssertNil(table.index(of: ""))
    }

    /// The `"crane"` case, which is a real entry in the real table (index 135, the bird; index 518,
    /// the machine). An ambiguous label resolves to NO index rather than to its first occurrence: a
    /// number that is wrong half the time it appears is worse than an absent one, because nothing
    /// about it looks uncertain.
    func testAmbiguousLabelResolvesToNoIndex() {
        let table = LabelTable(["crane", "tench", "crane"])

        XCTAssertNil(table.index(of: "crane"), "a label at two positions has no single index")
        XCTAssertEqual(table.index(of: "tench"), 1, "its neighbours are unaffected")
        XCTAssertEqual(table.label(at: 0), "crane", "the forward direction is still total")
        XCTAssertEqual(table.label(at: 2), "crane")
    }
}
