// The README's screenshots — the five states and the result — generated, not hand-captured (ADR-0007).
//
// Why a test and not Xcode's preview canvas. The canvas cannot render this package at all — the
// executable target `InferlensApp` wants `ENABLE_DEBUG_DYLIB=YES`, which SPM does not cleanly expose —
// and when it was tried it silently substituted a device: the selector read iPhone 17 Pro / iOS 26.0
// while the scheme said 26.1. A caption naming the wrong OS is an invariant-7 violation printed onto a
// picture, which is far harder to correct later than a line of prose. Rendering here removes the retyping
// step entirely: the device and OS in the manifest below are read from the process that actually drew the
// pixels, so the caption is a checked fact rather than a value someone read off a canvas.
//
// Three properties follow from generating them in the suite:
//   - regeneration is a command, not five manual exports (`bash scripts/gen-screenshots.sh`)
//   - the images cannot silently drift from the views, because the run that renders them is the run that
//     tests the state machine
//   - the device and OS are observed, never asserted
//
// This test SKIPS unless an output directory is handed to it. A developer running the suite normally must
// not be conscripted into producing images, and a test that failed for want of an output directory would
// break the green bar for a non-reason. Skipping is the correct outcome, not a weakened one — the
// assertions below still run in full whenever the directory IS supplied, which is the only time they have
// anything to say.

import SwiftUI
import UIKit
import XCTest

import InferlensCore
@testable import InferlensUI

@MainActor
final class StateScreenshotTests: XCTestCase {
    /// The environment variable carrying the output directory. `xcodebuild` forwards a variable to the
    /// test process only when it is prefixed `TEST_RUNNER_`, so the caller sets
    /// `TEST_RUNNER_INFERLENS_MEDIA_OUT` and the process sees `INFERLENS_MEDIA_OUT`.
    private static let outputVariable = "INFERLENS_MEDIA_OUT"

    /// Point width the states are rendered at. With `scale = 3` this puts the long edge at 1020 px,
    /// inside ADR-0007's 1200 px ceiling with room to spare — deliberately, so the ceiling is never the
    /// thing that decides what an image looks like.
    private static let renderWidth: CGFloat = 300
    private static let renderScale: CGFloat = 3

    /// What is rendered, paired with the file each is written to. The file name is data here, not a
    /// convention held in someone's head: `state-NN-<kebab-case-subject>.png`, NN being the order a
    /// user meets it in a run.
    ///
    /// Five of the six are the states of `InferenceState`. The sixth is the RESULT — the payload the
    /// screen rung added — which is not a state and so cannot be keyed on one: `success` says a result
    /// arrived, and `ClassificationResultView` is what shows it. Rendering it here means the top-3,
    /// the backend and the p50/p95 block are covered by the same "did it actually draw" assertions as
    /// everything else, rather than being the one part of the screen no check ever looks at.
    @MainActor
    private static var subjects: [(file: String, view: AnyView)] {
        [
            ("state-01-idle.png", AnyView(InferenceStateView(state: .idle, onRetry: {}))),
            ("state-02-loading-model.png", AnyView(InferenceStateView(state: .loadingModel, onRetry: {}))),
            ("state-03-inferring.png", AnyView(InferenceStateView(state: .inferring, onRetry: {}))),
            // The degraded case carries a REASON PAIR, not a flag, so the banner can name both ends of
            // the fallback — the same value the ledger row stores (invariant 3).
            (
                "state-04-success-degraded.png",
                AnyView(InferenceStateView(
                    state: .success(degraded: [.fellBack(from: .liteRT, to: .coreML)]),
                    onRetry: {}
                ))
            ),
            ("state-05-failed-retryable.png", AnyView(InferenceStateView(state: .failed(retryable: true), onRetry: {}))),
            ("state-06-result.png", AnyView(resultSubject)),
        ]
    }

    /// The result, from values typed by hand — no engine ran and no ledger row was written, which is
    /// the sentence ADR-0007 requires the caption to carry verbatim.
    ///
    /// The latency block is present because a readout WITH a device is the only kind this code can
    /// build (invariant 7: `LatencyReadout` carries the machine, so an image of a number without one
    /// cannot be produced by accident).
    @MainActor
    private static var resultSubject: some View {
        ClassificationResultView(
            classifications: [
                Classification(label: "golden retriever", confidence: 0.871),
                Classification(label: "Labrador retriever", confidence: 0.062),
                Classification(label: "kuvasz", confidence: 0.011),
            ],
            backend: .coreML,
            readout: LatencyReadout(
                summary: LatencySummary(
                    cold: TimingBreakdown(
                        preprocess: Percentiles(p50: .milliseconds(4), p95: .milliseconds(6)),
                        infer: Percentiles(p50: .milliseconds(21), p95: .milliseconds(28)),
                        total: Percentiles(p50: .milliseconds(214), p95: .milliseconds(232)),
                        sampleCount: 1
                    ),
                    warm: TimingBreakdown(
                        preprocess: Percentiles(p50: .milliseconds(4), p95: .milliseconds(5)),
                        infer: Percentiles(p50: .milliseconds(19), p95: .milliseconds(26)),
                        total: Percentiles(p50: .milliseconds(23), p95: .milliseconds(31)),
                        sampleCount: 12
                    )
                ),
                device: "iPhone18,1",
                os: "iOS 26.1"
            )
        )
    }

    func testRenderStateScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[Self.outputVariable], !path.isEmpty else {
            throw XCTSkip(
                """
                Skipped: no output directory. Set TEST_RUNNER_\(Self.outputVariable) to generate the \
                README screenshots — `bash scripts/gen-screenshots.sh` does it. Skipping is the intended \
                result for an ordinary suite run; nothing about the views is left unchecked by it, \
                because the other tests in this target check the machine and these only draw it.
                """
            )
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [(file: String, pixels: String, bytes: Int)] = []

        for subject in Self.subjects {
            let data = try render(subject.view)
            let destination = directory.appendingPathComponent(subject.file)
            try data.write(to: destination)

            // Assert the ADR's ceiling HERE, at the point of writing, rather than leaving every check to
            // the media gate. The gate gets a fact about a committed file; this gets it about a file the
            // moment it is produced, when the render settings that caused it are still in reach.
            XCTAssertLessThanOrEqual(
                data.count, 250_000,
                "\(subject.file) is \(data.count) bytes, over ADR-0007's 250,000-byte per-file ceiling."
            )

            let image = try XCTUnwrap(UIImage(data: data), "\(subject.file) is not decodable as an image.")
            let pixelWidth = Int(image.size.width * image.scale)
            let pixelHeight = Int(image.size.height * image.scale)
            XCTAssertLessThanOrEqual(
                max(pixelWidth, pixelHeight), 1200,
                "\(subject.file) long edge is \(max(pixelWidth, pixelHeight)) px, over ADR-0007's 1200 px."
            )

            try assertNothingFailedToRender(image, file: subject.file)

            written.append((subject.file, "\(pixelWidth)x\(pixelHeight)", data.count))
        }

        let total = written.reduce(0) { $0 + $1.bytes }
        XCTAssertLessThanOrEqual(
            total, 2_000_000,
            "The images total \(total) bytes, over ADR-0007's 2,000,000-byte directory ceiling."
        )

        try writeManifest(to: directory, written: written)
    }

    // MARK: - Rendering

    /// One state, drawn at a fixed width on an opaque background.
    ///
    /// **Not `ImageRenderer`, and the reason is load-bearing.** `ImageRenderer` rasterizes SwiftUI's own
    /// drawing and cannot draw an animated indeterminate `ProgressView`; rather than failing it
    /// substitutes a placeholder glyph, so `loadingModel` and `inferring` came out with a yellow no-entry
    /// sign where the spinner belongs — the right size, under every byte ceiling, and wrong.
    /// `assertNothingFailedToRender` is what now catches that, and it caught it with 2,398 placeholder
    /// pixels on exactly those two states.
    ///
    /// So the view is hosted in a real `UIWindow` and drawn with `drawHierarchy(_:afterScreenUpdates:)`,
    /// which renders what UIKit actually puts on screen, indicator included. The cost is that this needs a
    /// window and a run-loop turn — which is fine, because it already runs on the pinned simulator, and it
    /// buys the property the whole approach exists for: the image is what the device draws, not what a
    /// rasterizer approximated.
    ///
    /// Opaque on purpose: a transparent PNG renders as a black rectangle in GitHub's dark theme, which
    /// would make the failure state look like a crash.
    private func render(_ subject: AnyView) throws -> Data {
        let view = subject
            .frame(width: Self.renderWidth)
            .padding(20)
            .background(Color(uiColor: .systemBackground))

        let controller = UIHostingController(rootView: view)
        let width = Self.renderWidth + 40

        // Light mode is forced so the images are one set and the caption can name an appearance. Without
        // it the render follows whatever the simulator was last left in, and a re-run could silently
        // produce a dark set under a caption describing the light one.
        controller.overrideUserInterfaceStyle = .light

        // Drop the safe area. A hosting controller in a window inherits the device's safe-area insets —
        // roughly 100pt of status bar and home indicator — and `systemLayoutSizeFitting` dutifully
        // includes them, so the first renders were ~157pt tall for ~60pt of content, with the words
        // stranded in a thin band of white. That is not a phone screenshot; it is a component render with
        // a phone's chrome allowance stamped into it, and the empty space is what forced the text down to
        // an illegible size once the image was scaled to fit a README column.
        controller.safeAreaRegions = []

        // Measure AFTER the view is in a window, not before. `sizeThatFits(in:)` on a hosting controller
        // whose view has never been in a hierarchy under-reports height, and the difference is not a
        // rounding error: it clipped four of the five states, shearing "Loading model…" through the middle
        // of the glyphs. So the window is created generously tall, the view is laid out, and only then is
        // the content measured and the window resized down to it.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2000))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        controller.view.layoutIfNeeded()

        let measured = controller.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let size = CGSize(width: width, height: ceil(measured.height))

        window.frame = CGRect(origin: .zero, size: size)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()

        // One run-loop turn so UIKit materializes the activity indicator before it is drawn. Without it
        // the spinner is laid out but has not yet produced its layers, and the capture is blank where it
        // should be — the same class of wrong image, arrived at a different way.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.renderScale
        format.opaque = true

        // `layer.render(in:)`, NOT `drawHierarchy(_:afterScreenUpdates:)`. drawHierarchy needs the view to
        // be in a hierarchy the window server is actually compositing; in a test bundle with no host app
        // there is no scene, so it returned a uniformly BLACK image for all five states — and the first
        // version of the yellow-placeholder check passed every one of them. Rendering the layer tree works
        // off-screen and draws the activity indicator, which is layer-backed.
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            controller.view.layer.render(in: context.cgContext)
        }

        window.isHidden = true
        return try XCTUnwrap(image.pngData(), "The rendered subject has no PNG data.")
    }

    // MARK: - Did it actually draw?

    /// Fail if the renderer gave up on part of the view and drew its placeholder instead.
    ///
    /// This check exists because the first version of this test shipped two broken images and nothing
    /// noticed. `ImageRenderer` cannot draw an animated indeterminate `ProgressView`; instead of failing,
    /// it substitutes a bright yellow "prohibited" glyph — so `state-02` and `state-03` were written,
    /// were the right pixel size, were under every byte ceiling, and passed every assertion, while showing
    /// a "no entry" sign where the spinner belonged. A human looking at the file is what caught it, and a
    /// human looking is not a check.
    ///
    /// The test is narrow and deliberately so: this view hierarchy is greyscale, black, and system blue.
    /// Saturated yellow appears nowhere in it, so a strongly yellow pixel means something was substituted
    /// for content. A general "does this look right" assertion is not available at any reasonable cost;
    /// an assertion that catches THE failure that actually happened is, and it is what the repo's other
    /// teeth tests are — the specific plant, not a theory of all plants.
    private func assertNothingFailedToRender(_ image: UIImage, file: String) throws {
        let cgImage = try XCTUnwrap(image.cgImage, "\(file) has no bitmap to inspect.")
        let width = cgImage.width
        let height = cgImage.height

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            "Could not create a bitmap context for \(file)."
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var yellowPixels = 0
        var distinctColors = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            // Saturated yellow: red and green both high, blue clearly low.
            if red > 200, green > 150, blue < 100 { yellowPixels += 1 }
            distinctColors.insert(UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
        }

        XCTAssertEqual(
            yellowPixels, 0,
            """
            \(file) contains \(yellowPixels) saturated-yellow pixels, which this view hierarchy never \
            draws. That is the renderer's "cannot draw this" placeholder — almost certainly a \
            ProgressView it refused to rasterize. The image would have shipped a no-entry sign where the \
            spinner belongs.
            """
        )

        // The check above was written first and was too narrow: it caught a placeholder glyph and passed a
        // COMPLETELY BLANK image, because a blank image contains no yellow. An all-black capture then
        // shipped and the suite stayed green. The two below are what an "is this actually drawn" check has
        // to say, and they are general where the yellow test is specific.
        XCTAssertGreaterThan(
            distinctColors.count, 10,
            """
            \(file) contains only \(distinctColors.count) distinct colours — it is a flat rectangle, not a \
            rendering. Antialiased text alone produces dozens. The capture path drew nothing.
            """
        )

        // The top-left pixel is background, and the render forces light mode, so it must be near-white.
        // This is the assertion that catches an all-black capture specifically: a hierarchy drawn with no
        // live window comes back black, which is uniform AND dark, and "uniform" alone would not say which
        // failure it was.
        let corner = (red: Int(pixels[0]), green: Int(pixels[1]), blue: Int(pixels[2]))
        XCTAssertTrue(
            corner.red > 200 && corner.green > 200 && corner.blue > 200,
            """
            \(file)'s background pixel is rgb(\(corner.red), \(corner.green), \(corner.blue)), not the \
            near-white this renders on in forced light mode. An all-black capture means the view was \
            drawn without a live window and produced nothing.
            """
        )

        // Nothing may touch the bottom edge. A view measured too short renders its content clipped —
        // "Loading model…" sheared off mid-glyph — and that is invisible to every check above: the image
        // is the right size, has hundreds of colours, has a white background, and is WRONG. The last row
        // of pixels is background in a correctly sized render and contains ink in a clipped one, which
        // makes this the cheapest possible statement of "the content fits".
        let lastRow = (height - 1) * width * 4
        var inkOnBottomEdge = 0
        for column in 0 ..< width {
            let index = lastRow + column * 4
            if Int(pixels[index]) < 200 || Int(pixels[index + 1]) < 200 || Int(pixels[index + 2]) < 200 {
                inkOnBottomEdge += 1
            }
        }
        XCTAssertEqual(
            inkOnBottomEdge, 0,
            """
            \(file) has \(inkOnBottomEdge) non-background pixels on its bottom edge — the content is \
            CLIPPED. The view was measured shorter than it draws, so a caption describes a screen whose \
            last line is sheared in half.
            """
        )
    }

    // MARK: - Provenance

    /// Write down what actually drew the pixels.
    ///
    /// This is the file the README's caption is written FROM. Every value is read out of the running
    /// process — the simulator's own model identifier and OS version — so nobody retypes a device name
    /// off a scheme string or a canvas selector, which is exactly how the 26.0-vs-26.1 mismatch happened.
    /// Invariant 7 applied at its source rather than at the point of quoting.
    private func writeManifest(
        to directory: URL,
        written: [(file: String, pixels: String, bytes: Int)]
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        let device = environment["SIMULATOR_DEVICE_NAME"] ?? "unknown (not a simulator run)"
        let modelIdentifier = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown"
        let system = UIDevice.current.systemName
        let version = UIDevice.current.systemVersion

        var lines = [
            "# Generated by StateScreenshotTests. Do not edit — regenerate with scripts/gen-screenshots.sh.",
            "#",
            "# Read from the process that rendered the pixels, NOT from the scheme or the canvas. The",
            "# README caption is written from these values (ADR-0007, invariant 7).",
            "",
            "device: \(device)",
            "model-identifier: \(modelIdentifier)",
            "os: \(system) \(version)",
            "render-scale: \(Int(Self.renderScale))x",
            "render-width-points: \(Int(Self.renderWidth))",
            "",
            "files:",
        ]
        for entry in written {
            lines.append("  \(entry.file)  \(entry.pixels) px  \(entry.bytes) bytes")
        }
        lines.append("")
        lines.append("total-bytes: \(written.reduce(0) { $0 + $1.bytes })")
        lines.append("")

        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("capture-manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
