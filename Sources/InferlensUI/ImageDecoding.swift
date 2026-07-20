// From a photo the user picked to the `ImageBuffer` the contract takes.
//
// This is the only place in the module that touches an image framework. It exists because
// `ImageBuffer` is deliberately raw bytes — Core owns no image type, so no engine's native buffer
// (`CVPixelBuffer`, a TFLite tensor) can leak into the contract — and something has to do the
// conversion once, on the way in.
//
// WHERE THIS SITS RELATIVE TO THE MEASURED PATH, because it affects a benchmark number. An engine
// OWNS its preprocessing: the contract requires it so that a boundary between `preprocess` and
// `infer` exists to time (ADR-0001), and the model's resize to 224x224 happens inside the engine,
// inside the measured `preprocess` bracket. This file does NOT do that resize. What it does is
// decode the picked photo to an upright RGBA bitmap, bounded at `maximumLongEdge`, before any
// measurement starts.
//
// The bound is a real caveat and is written down rather than hidden: a 12-megapixel photo is
// ~48 MB as `[UInt8]`, and handing that to an engine would make `preprocess` mostly a measurement of
// how large the user's camera is. Bounding it makes the number comparable between runs — and makes
// it a number about a 1024 px input, not about an arbitrary one. Both engines get the identical
// buffer, so the comparison the repo exists to make is unaffected; what is affected is the absolute
// `preprocess` figure, which is why the README's Limitations section now says so.

import CoreGraphics
import InferlensCore
import UIKit

// MARK: - Decoding

public enum ImageDecoder {
    /// The longest edge, in pixels, a picked photo is decoded to. See the file header: this is a
    /// pre-measurement decode bound, not the model's input size.
    public static let maximumLongEdge = 1024

    /// A `UIImage` as row-major RGBA8 bytes, upright, with the long edge at or under the bound.
    ///
    /// Two steps, and the first is not skippable. A `UIImage` carries an orientation that its
    /// `cgImage` does not apply — a photo taken in portrait is commonly stored as landscape plus a
    /// "rotate right" flag — so reading the `CGImage`'s pixels directly classifies a sideways
    /// picture and produces confident nonsense. Drawing the `UIImage` bakes the orientation in.
    ///
    /// - Throws: `.unsupportedInput` when the image has no drawable size, or when a bitmap context
    ///   cannot be made for it. The same error `ImageBuffer`'s own byte-count check throws, because
    ///   from the contract's side these are one thing: this input cannot be used.
    public static func buffer(
        from image: UIImage,
        maximumLongEdge: Int = ImageDecoder.maximumLongEdge
    ) throws(InferenceError) -> ImageBuffer {
        let target = fittedSize(for: image.size, maximumLongEdge: maximumLongEdge)
        guard target.width > 0, target.height > 0 else { throw .unsupportedInput }

        // Scale 1 so the rendered image's pixel size IS the target size; the default follows the
        // screen and would silently produce a 3x buffer on this device and a 2x one on that.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let size = CGSize(width: target.width, height: target.height)
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = upright.cgImage else { throw .unsupportedInput }

        return try bytes(of: cgImage)
    }

    /// The size an image is decoded at: unchanged when it already fits, otherwise scaled down so the
    /// long edge lands exactly on the bound. Never scales UP — enlarging a small photo would invent
    /// pixels and make `preprocess` measure work on data that was not there.
    static func fittedSize(for size: CGSize, maximumLongEdge: Int) -> (width: Int, height: Int) {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return (0, 0) }

        let longEdge = max(width, height)
        guard longEdge > maximumLongEdge else { return (width, height) }

        let scale = Double(maximumLongEdge) / Double(longEdge)
        return (
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// Row-major RGBA8 out of a `CGImage`, via a context this code owns.
    ///
    /// The context is created with `bytesPerRow` exactly `width * 4` rather than letting CoreGraphics
    /// choose: a context is free to pad each row for alignment, and padding would put stride bytes
    /// into an array `ImageBuffer` requires to be exactly `width * height * 4`. The buffer's own
    /// initializer would then throw — correctly, and for a reason that would take an afternoon to
    /// find. Pinning the stride here means the invariant holds by construction.
    static func bytes(of cgImage: CGImage) throws(InferenceError) -> ImageBuffer {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw .unsupportedInput }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let made: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                // premultipliedLast == R,G,B,A in that byte order, which is `PixelFormat.rgba8`.
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard made else { throw .unsupportedInput }

        return try ImageBuffer(width: width, height: height, pixelFormat: .rgba8, bytes: pixels)
    }
}
