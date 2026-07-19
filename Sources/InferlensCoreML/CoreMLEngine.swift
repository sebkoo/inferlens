// InferlensCoreML — the Core ML implementation of the contract. This is where the rung-03
// contract meets a real engine instead of the stub.
//
// Everything Core ML — `MLModel`, the `CVPixelBuffer`, the vImage resize, the `classLabelProbs`
// dictionary — is contained in this file. None of it crosses the `InferenceEngine` boundary: what
// crosses is what the contract defines (an `ImageBuffer` in, an `InferenceOutcome` out), both
// already `Sendable`.
//
// Why `MLModel` directly and not Vision: ADR-0001's timing-split constraint. `VNCoreMLRequest`
// fuses resize/crop/normalize into the prediction, leaving no boundary between `preprocess` and
// `infer` to measure. Driving `MLModel` directly makes the engine OWN preprocessing (the resize +
// pixel-buffer build), so the two phases can be timed apart — the whole reason the README's
// Cold/Warm table can carry a preprocess column.
//
// Actor isolation: `MLModel` is a non-`Sendable` class; it lives inside the actor and never leaves
// it, so this engine needs no `@unchecked Sendable`. The LiteRT engine keeps its C handle inside
// its actor the same way, so the repo uses zero `@unchecked Sendable` (ADR-0005). `descriptor` is
// a `nonisolated let` — synchronously readable metadata, the same shape as `StubEngine`.
//
// Nothing about the model is baked in as a literal: the input feature name, the pixel size the
// model requires, and the probabilities-output name are all read from the loaded model's
// description at `loadModel`. Swap the model and the engine adapts, instead of feeding a 224×224
// "image" to a model that wanted something else.

import Accelerate
import CoreML
import CoreVideo
import Foundation
import InferlensCore

public actor CoreMLEngine: InferenceEngine {
    /// Declared metadata for the ledger and UI — readable without `await` or a load, since a
    /// `ModelDescriptor` is a `Sendable` value. The engine does not trust it for preprocessing: the
    /// input size that actually drives the resize is read from the model itself at load.
    public nonisolated let descriptor: ModelDescriptor

    /// The `.mlmodel`/`.mlpackage` to compile and load. The caller supplies it — the app composes
    /// the fetched `Vendor/Models` URL, the tests pass the same file. The engine hardcodes no path.
    private let modelURL: URL

    /// Everything a prediction needs, resolved at load from the model's own description. `nil`
    /// until `loadModel` succeeds; a `classify` before then is a typed `.modelLoadFailed`, never a
    /// trap.
    private var ready: Ready?

    /// What one prediction needs — every field read from the model, none assumed.
    private struct Ready {
        let model: MLModel
        /// The image input's feature name (e.g. `"image"`), from `inputDescriptionsByName`.
        let inputName: String
        /// The pixel size the model's image input requires, from its `MLImageConstraint`.
        let inputSize: PixelSize
        /// The classifier's probability-dictionary output name, from `predictedProbabilitiesName`.
        let probabilitiesName: String
    }

    public init(modelURL: URL, descriptor: ModelDescriptor = .appleMobileNetV2FP16) {
        self.modelURL = modelURL
        self.descriptor = descriptor
    }

    // MARK: - Load

    /// Compile → load → warm up, so the engine is at steady-state speed by the time this returns —
    /// the contract's obligation that `loadModel` may not defer work into the first `classify`.
    ///
    /// The warm-up (one throwaway prediction) is load's job, not `classify`'s: Core ML performs its
    /// first-prediction compilation — on device, the Neural Engine lowering — on the first
    /// `predict`. If that happened inside the first real `classify`, run 1 would be many times run 2
    /// and the conformance suite's steady-state check would (correctly) reject the engine.
    ///
    /// Compute units are pinned to `.all` (ANE included) — the choice that governs device latency,
    /// recorded in the commit body. On the simulator there is no ANE to warm, so this proves shape,
    /// not steady-state; the device bench is where the warm-up and the latency table are validated.
    public func loadModel() async throws(InferenceError) {
        let compiledURL: URL
        do {
            // The synchronous `compileModel(at:)` is deprecated in this SDK; the async form is the
            // one to use (read from MLModel+MLModelCompilation.h for Xcode 26.6).
            compiledURL = try await MLModel.compileModel(at: modelURL)
        } catch {
            throw InferenceError.modelLoadFailed
        }

        let model: MLModel
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw InferenceError.modelLoadFailed
        }

        let resolved = try resolve(model)
        try warmUp(resolved)
        ready = resolved
    }

    /// Read the image input (name + required pixel size) and the probabilities-output name from the
    /// model — the "adapt to the model, don't assume" part. A model with no image input, or no
    /// probability output, is not one this engine can drive: `.modelLoadFailed`, not a wrong guess.
    private func resolve(_ model: MLModel) throws(InferenceError) -> Ready {
        let description = model.modelDescription

        guard let imageInput = description.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = imageInput.value.imageConstraint
        else { throw InferenceError.modelLoadFailed }

        guard let probabilitiesName = description.predictedProbabilitiesName
        else { throw InferenceError.modelLoadFailed }

        return Ready(
            model: model,
            inputName: imageInput.key,
            inputSize: PixelSize(width: constraint.pixelsWide, height: constraint.pixelsHigh),
            probabilitiesName: probabilitiesName
        )
    }

    /// One throwaway prediction on a blank input so the first real `classify` is warm. A failure
    /// here means the model cannot actually run — surfaced as a load failure, which is what it is.
    private func warmUp(_ resolved: Ready) throws(InferenceError) {
        let blank = try blankPixelBuffer(size: resolved.inputSize)
        do {
            let features = try MLDictionaryFeatureProvider(
                dictionary: [resolved.inputName: MLFeatureValue(pixelBuffer: blank)]
            )
            _ = try resolved.model.prediction(from: features)
        } catch {
            throw InferenceError.modelLoadFailed
        }
    }

    // MARK: - Classify

    public func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        guard let ready else { throw InferenceError.modelLoadFailed }

        // --- Timing split. Measurement brackets — agent-written, human-reviewed per invariant 1
        // (rung 10; relabelled at rung 15, the prior "hand-written" label being unverified). Two
        // clock reads bracket the two phases the engine owns; there is no cleverness here and
        // nothing is aggregated. This is the raw per-run signal, not the benchmark: percentile
        // aggregation and the cold/warm split belong to the LatencyRecorder (agent-written, maintainer-decided).
        //   preprocess = raw bytes → the model's native input (resize + BGRA pixel buffer + feature
        //                provider)
        //   infer      = the prediction call, alone
        // That boundary is ADR-0001's whole point and the reason this engine drives MLModel directly.
        let clock = ContinuousClock()

        let preprocessStart = clock.now
        let features = try makeFeatures(from: image, using: ready)
        let inferStart = clock.now
        let prediction = try predict(features, with: ready.model)
        let inferEnd = clock.now
        // --- end timing split

        return InferenceOutcome(
            classifications: try classifications(from: prediction, named: ready.probabilitiesName),
            timing: RunTiming(
                preprocess: preprocessStart.duration(to: inferStart),
                infer: inferStart.duration(to: inferEnd)
            ),
            backend: .coreML
            // No `degradations`: a plain Core ML run is clean. Thermal throttling and the fallback
            // chain write degradations from ABOVE the engine (the composition layer), never here.
            //
            // No load timing either: the contract deliberately keeps load out of the outcome — the
            // LatencyRecorder composes the cold/warm axis when it observes `loadModel`. (The rung-10
            // brief mentions a `LoadTiming` on the outcome; the rung-03 `InferenceOutcome` has no
            // such field, so this follows the contract and flags the discrepancy rather than
            // inventing one.)
        )
    }

    /// The synchronous prediction, isolated in a non-`async` method so overload resolution picks
    /// Core ML's synchronous `prediction(from:)` — in an `async` context its async overload would
    /// win, and the timing split would then bracket a suspension point instead of one blocking call.
    private func predict(_ features: MLFeatureProvider, with model: MLModel) throws(InferenceError) -> MLFeatureProvider {
        do {
            return try model.prediction(from: features)
        } catch {
            throw InferenceError.inferenceFailed
        }
    }

    // MARK: - Preprocessing (owned by the engine, timed as `preprocess`)

    /// Resize the incoming image to the model's required size and wrap it as the model's input
    /// feature. The entire conversion lives here, inside the timed `preprocess` phase; nothing is
    /// deferred into the framework.
    private func makeFeatures(from image: ImageBuffer, using ready: Ready) throws(InferenceError) -> MLFeatureProvider {
        let pixelBuffer = try pixelBuffer(from: image, size: ready.inputSize)
        do {
            return try MLDictionaryFeatureProvider(
                dictionary: [ready.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)]
            )
        } catch {
            throw InferenceError.inferenceFailed
        }
    }

    /// Scale the raw `ImageBuffer` into a 32BGRA `CVPixelBuffer` of the model's size — the pixel
    /// format Core ML image inputs take. vImage does the scale; then, only for an RGBA source, a
    /// channel permute reaches BGRA byte order. The model bakes in mean/std normalization, so this
    /// stops at the pixel format and size.
    private func pixelBuffer(from image: ImageBuffer, size: PixelSize) throws(InferenceError) -> CVPixelBuffer {
        let buffer = try emptyBGRABuffer(width: size.width, height: size.height)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destinationBase = CVPixelBufferGetBaseAddress(buffer) else {
            throw InferenceError.inferenceFailed
        }
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let sourceRowBytes = image.width * image.pixelFormat.bytesPerPixel
        let permuteMap = channelPermuteToBGRA(from: image.pixelFormat)

        var failure: InferenceError?
        image.bytes.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else {
                failure = .unsupportedInput
                return
            }
            // vImage only reads the source, so a mutable pointer over the immutable bytes is safe.
            var sourceBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: sourceBase),
                height: vImagePixelCount(image.height),
                width: vImagePixelCount(image.width),
                rowBytes: sourceRowBytes
            )
            var destinationBuffer = vImage_Buffer(
                data: destinationBase,
                height: vImagePixelCount(size.height),
                width: vImagePixelCount(size.width),
                rowBytes: destinationRowBytes
            )
            guard vImageScale_ARGB8888(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                failure = .inferenceFailed
                return
            }
            if let permuteMap {
                // In-place permute: a struct copy so the two pointer args are distinct variables
                // (exclusivity), both aimed at the same pixel memory.
                var inPlace = destinationBuffer
                guard vImagePermuteChannels_ARGB8888(&inPlace, &destinationBuffer, permuteMap, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                    failure = .inferenceFailed
                    return
                }
            }
        }
        if let failure { throw failure }
        return buffer
    }

    /// A 32BGRA pixel buffer wants bytes in B,G,R,A order. A `.bgra8` source already is (`nil` = no
    /// permute); an `.rgba8` source is R,G,B,A, so swap channels 0 and 2. A `switch`, not a
    /// default: a future `PixelFormat` (Core's `.gray8` seam) must force a decision here, not
    /// silently take the wrong branch.
    private func channelPermuteToBGRA(from format: InferlensCore.PixelFormat) -> [UInt8]? {
        switch format {
        case .bgra8: nil
        case .rgba8: [2, 1, 0, 3]
        }
    }

    /// An empty IOSurface-backed 32BGRA buffer. IOSurface backing is what lets Core ML hand the
    /// pixels to the ANE without a copy on device.
    private func emptyBGRABuffer(width: Int, height: Int) throws(InferenceError) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            if status == kCVReturnAllocationFailed { throw InferenceError.outOfMemory }
            throw InferenceError.inferenceFailed
        }
        return pixelBuffer
    }

    /// A zeroed buffer for the load-time warm-up. Content is irrelevant — the prediction is
    /// discarded; it exists only to pay the first-prediction cost during load.
    private func blankPixelBuffer(size: PixelSize) throws(InferenceError) -> CVPixelBuffer {
        let buffer = try emptyBGRABuffer(width: size.width, height: size.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * size.height)
        }
        return buffer
    }

    // MARK: - Output (mapped from the classifier's probability dictionary)

    /// Map the classifier's probability dictionary (label → probability) to the contract's
    /// classifications, sorted by confidence descending. The full label set is returned, not a
    /// top-N: "top labels" is then any prefix a consumer takes, and the engine bakes in no UI
    /// concern. Softmax probabilities are already in `0...1` with each ≤ 1, so there is no clamp —
    /// a value outside the range would be real signal the conformance suite should catch, not
    /// something to quietly repair.
    private func classifications(from prediction: MLFeatureProvider, named name: String) throws(InferenceError) -> [Classification] {
        guard let value = prediction.featureValue(for: name), value.type == .dictionary else {
            throw InferenceError.inferenceFailed
        }
        let probabilities = value.dictionaryValue // [AnyHashable: NSNumber], label → probability
        var results: [Classification] = []
        results.reserveCapacity(probabilities.count)
        for (key, probability) in probabilities {
            guard let label = key as? String else { continue }
            results.append(Classification(label: label, confidence: probability.floatValue))
        }
        results.sort { $0.confidence > $1.confidence }
        return results
    }
}

public extension ModelDescriptor {
    /// Apple's MobileNetV2, FP16 — the artifact `make bootstrap` fetches (see MODEL_PROVENANCE.md).
    /// This is declared metadata for the ledger; the engine reads the model's real input size at
    /// load, so a model swap adapts without editing this value.
    static let appleMobileNetV2FP16 = ModelDescriptor(
        name: "MobileNetV2 (Apple, FP16)",
        precision: .fp16,
        inputSize: PixelSize(width: 224, height: 224)
    )
}
