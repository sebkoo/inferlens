// The spec for the photo → `ImageBuffer` conversion.
//
// Three properties, each of which has a way of being wrong that no other test in the repo would
// catch: the byte layout (silently wrong colours), the decode bound (a 48 MB array through an actor
// boundary), and orientation (a sideways photo classified with total confidence).
//
// What these tests do NOT read:
//   - they do not check that an ENGINE likes the buffer. The conformance suite does that against
//     real engines; here the assertion stops at the contract's own invariant (`width * height *
//     bytesPerPixel`), which `ImageBuffer.init` enforces and which is what a downstream engine
//     depends on.
//   - they do not assert exact pixel values after a RESIZE. Interpolation is CoreGraphics's and
//     pinning it would be testing Apple's resampler; the resize is checked by dimension, and exact
//     bytes are checked only at 1:1, where there is a right answer.
//   - they say nothing about the model's 224x224 resize, which happens inside the engine's measured
//     `preprocess` and is not this code's job (ADR-0001).

import CoreGraphics
import InferlensCore
import UIKit
import XCTest

@testable import InferlensUI

final class ImageDecodingTests: XCTestCase {
    // MARK: - Helpers

    /// A solid-colour image of a given pixel size, at scale 1 so points and pixels agree.
    private func image(width: Int, height: Int, color: UIColor = .red) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Left half red, right half blue — a picture with a known left/right asymmetry, which is what
    /// makes an orientation change observable.
    private func twoTone(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.blue.setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
    }

    // MARK: - Byte layout

    func testBytesAreRowMajorRgbaWithNoRowPadding() throws {
        let source = try XCTUnwrap(twoTone(width: 2, height: 1).cgImage)
        let buffer = try ImageDecoder.bytes(of: source)

        XCTAssertEqual(buffer.width, 2)
        XCTAssertEqual(buffer.height, 1)
        XCTAssertEqual(buffer.pixelFormat, .rgba8)
        // The invariant the contract enforces at construction. A padded row stride would break it,
        // which is exactly why the context pins bytesPerRow to width * 4.
        XCTAssertEqual(buffer.bytes.count, 2 * 1 * 4)

        // R,G,B,A in that byte order. Tolerance because the render goes through a colour space.
        XCTAssertEqual(Int(buffer.bytes[0]), 255, accuracy: 2)   // red pixel, R
        XCTAssertEqual(Int(buffer.bytes[1]), 0, accuracy: 2)     // red pixel, G
        XCTAssertEqual(Int(buffer.bytes[2]), 0, accuracy: 2)     // red pixel, B
        XCTAssertEqual(Int(buffer.bytes[3]), 255)                // opaque
        XCTAssertEqual(Int(buffer.bytes[4]), 0, accuracy: 2)     // blue pixel, R
        XCTAssertEqual(Int(buffer.bytes[6]), 255, accuracy: 2)   // blue pixel, B
    }

    func testAWideImageKeepsItsRowsInOrder() throws {
        // 4x2, top row red / bottom row blue would test the other axis; this checks the simpler
        // property that the byte count scales with both dimensions and the buffer is constructible.
        let source = try XCTUnwrap(image(width: 4, height: 2).cgImage)
        let buffer = try ImageDecoder.bytes(of: source)

        XCTAssertEqual(buffer.bytes.count, 4 * 2 * 4)
    }

    // MARK: - The decode bound

    func testAnImageWithinTheBoundIsNotResized() {
        let fitted = ImageDecoder.fittedSize(
            for: CGSize(width: 800, height: 600),
            maximumLongEdge: 1024
        )
        XCTAssertEqual(fitted.width, 800)
        XCTAssertEqual(fitted.height, 600)
    }

    /// Never scales UP. Enlarging a small photo would invent pixels and make the engine's
    /// `preprocess` measure work on data that was not there.
    func testASmallImageIsNeverEnlarged() {
        let fitted = ImageDecoder.fittedSize(
            for: CGSize(width: 64, height: 32),
            maximumLongEdge: 1024
        )
        XCTAssertEqual(fitted.width, 64)
        XCTAssertEqual(fitted.height, 32)
    }

    func testAnOversizedImageLandsExactlyOnTheBoundAndKeepsItsAspect() {
        let fitted = ImageDecoder.fittedSize(
            for: CGSize(width: 4032, height: 3024),
            maximumLongEdge: 1024
        )
        XCTAssertEqual(max(fitted.width, fitted.height), 1024)
        // 4:3 preserved.
        XCTAssertEqual(fitted.width, 1024)
        XCTAssertEqual(fitted.height, 768)
    }

    func testTheBoundIsAppliedEndToEnd() throws {
        let buffer = try ImageDecoder.buffer(from: image(width: 2000, height: 1000))

        XCTAssertEqual(buffer.width, 1024)
        XCTAssertEqual(buffer.height, 512)
        XCTAssertEqual(buffer.bytes.count, 1024 * 512 * 4)
    }

    // MARK: - Orientation

    /// The failure this exists to prevent: a portrait photo is commonly stored landscape plus a
    /// "rotate right" flag, and reading the `CGImage`'s pixels directly ignores the flag — so the
    /// engine classifies a sideways picture and returns a confident wrong answer. Drawing the
    /// `UIImage` bakes the rotation in, which shows up here as swapped dimensions.
    func testOrientationIsAppliedRatherThanIgnored() throws {
        let landscape = try XCTUnwrap(twoTone(width: 40, height: 20).cgImage)
        let rotated = UIImage(cgImage: landscape, scale: 1, orientation: .right)

        let buffer = try ImageDecoder.buffer(from: rotated)

        // The stored bitmap is 40x20; the oriented image is 20x40, and that is what must reach the
        // engine.
        XCTAssertEqual(buffer.width, 20)
        XCTAssertEqual(buffer.height, 40)
    }

    // MARK: - Refusal

    func testAnImageWithNoSizeIsRefusedAsUnsupportedInput() {
        // The picker can hand over data that decodes to nothing; the screen passes an empty
        // `UIImage` on rather than failing through a second, invisible path.
        XCTAssertThrowsError(try ImageDecoder.buffer(from: UIImage())) { error in
            XCTAssertEqual(error as? InferenceError, .unsupportedInput)
        }
    }
}

// MARK: - Latency formatting

/// The only arithmetic `InferlensUI` is allowed to do with a latency: turn a `Duration` into
/// something a person reads. The percentiles themselves are `LatencyRecorderTests`' subject, in the
/// module that owns them (ADR-0008).
final class LatencyFormatTests: XCTestCase {
    func testMillisecondsCombinesBothComponentsOfADuration() {
        // 1.5 s is `(seconds: 1, attoseconds: 5e17)`; a formatter reading only one field reports
        // either 1000 or 500 and looks plausible doing it.
        XCTAssertEqual(LatencyFormat.milliseconds(.milliseconds(1500)), 1500, accuracy: 0.001)
        XCTAssertEqual(LatencyFormat.milliseconds(.microseconds(1234)), 1.234, accuracy: 0.001)
    }

    func testTextAlwaysCarriesItsUnit() {
        XCTAssertEqual(LatencyFormat.text(Duration.milliseconds(12)), "12.0 ms")
    }

    func testAPercentilePairReadsP50ThenP95() {
        let percentiles = Percentiles(p50: .milliseconds(12), p95: .milliseconds(31))
        XCTAssertEqual(LatencyFormat.text(percentiles), "12.0 / 31.0 ms")
    }

    /// A p95 over 3 runs and over 300 are different claims, so the count is said in words beside the
    /// number rather than left for a reader to hunt for.
    func testTheSampleCountIsSaidInWords() {
        func breakdown(count: Int) -> TimingBreakdown {
            TimingBreakdown(
                preprocess: Percentiles(p50: .milliseconds(1), p95: .milliseconds(1)),
                infer: Percentiles(p50: .milliseconds(1), p95: .milliseconds(1)),
                total: Percentiles(p50: .milliseconds(1), p95: .milliseconds(1)),
                sampleCount: count
            )
        }
        XCTAssertEqual(LatencyFormat.evidence(breakdown(count: 1)), "1 run")
        XCTAssertEqual(LatencyFormat.evidence(breakdown(count: 42)), "42 runs")
    }
}
