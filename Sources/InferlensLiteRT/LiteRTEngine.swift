// InferlensLiteRT — the TensorFlow Lite implementation of the contract. This is where the
// contract meets its second real engine, driving the TFLite C API directly.
//
// Concurrency (ADR-0005, the whole reason invariant 2 was reserved and then corrected): the engine is
// an `actor`. Its `TfLiteInterpreter*`/`TfLiteModel*` handles are `OpaquePointer`s — non-Sendable, and
// the C API is not thread-safe. They live inside the actor and every C call is SYNCHRONOUS and
// on-actor, with no suspension between reading a handle and the C call returning, so the actor
// serializes all access. That is why this engine needs **zero** `@unchecked Sendable`. The compiler
// does NOT enforce this — `OpaquePointer` is a trivial value, so region isolation would silently let
// it cross a `sending` boundary and a reentrant second `Invoke` could race — so the on-actor
// discipline is manual and documented at the `Invoke` site below.
//
// Cleanup uses RAII, not an actor `deinit`, for a concrete compiler reason (ADR-0005): a nonisolated
// actor `deinit` may not even READ a non-Sendable stored property (`OpaquePointer?` included), and an
// `isolated deinit` (SE-0371) compiles but defers the free onto the actor executor — that async
// teardown raced the test bundle's process shutdown and crashed. So the two C handles live in a tiny
// private `Handles` reference type whose OWN synchronous `deinit` frees them; the actor just holds it,
// and ARC frees it (and the handles) deterministically when the actor is deallocated. At that point the
// actor's refcount is zero, so nothing can hold it to issue a concurrent C call — the free is
// race-free, with ZERO `@unchecked Sendable` and zero unsafe annotations.
//
// Adapt to the model, don't assume it: the input pixel size, element count, and the output length are
// read from the interpreter's own tensors at `loadModel`, exactly as `CoreMLEngine` reads them from the
// model description. Swap the `.tflite` and the engine adapts. The FP32 float MobileNetV2 expects
// float input normalized to [-1, 1] (not baked in — the engine normalizes) and emits a post-softmax
// vector already in 0...1; the raw model carries no label strings, so classes are labelled by index
// (MODEL_PROVENANCE.md).

import Accelerate
import Foundation
import InferlensCore
import TensorFlowLiteC

public actor LiteRTEngine: InferenceEngine {
    /// Declared metadata for the ledger and UI — readable without `await` or a load, since a
    /// `ModelDescriptor` is a `Sendable` value. The engine does not trust it for preprocessing: the
    /// input size that actually drives the resize is read from the model itself at load.
    public nonisolated let descriptor: ModelDescriptor

    /// The `.tflite` to load. The caller supplies it — the app composes the fetched `Vendor/Models`
    /// URL, the tests pass the same file. The engine hardcodes no path.
    private let modelURL: URL

    /// The owned C handles, or `nil` until `loadModel` succeeds. Held in a reference type so its own
    /// synchronous `deinit` frees them (see `Handles`); a `classify` before then is a typed
    /// `.modelLoadFailed`, never a trap.
    private var handles: Handles?

    /// Shapes read from the model at load — a `Sendable` value. Non-nil iff `handles` is.
    private var shape: Shape?

    /// The table supplied by the composition, as given. Never consulted directly: `acceptedLabels`
    /// is what `classify` reads, and it is set only once the table has been checked against the
    /// model this engine actually loaded.
    private let labels: LabelTable?

    /// The table, once it has EARNED the right to name this model's classes: non-nil only when a
    /// table was supplied and its count equals the model's output width. `nil` otherwise, which
    /// sends every class to `LabelTable.fallbackLabel(for:)`.
    ///
    /// A size check rather than a trust exercise. A 1000-entry list against this 1001-wide output is
    /// the exact off-by-one that ImageNet tables invite (index 0 is TF-slim's background class), and
    /// it does not announce itself: every lookup succeeds and every word is one class off. Refusing
    /// the whole table on a count mismatch is what makes that failure loud — the screen falls back
    /// to `"class 653"`, which is unreadable but true, instead of showing a confident wrong word.
    ///
    /// It is a refusal, not a thrown error: a table that does not fit is a labelling problem, and a
    /// model that classifies correctly should not be turned into a dead app by one. What the count
    /// check does NOT read is ORDERING — a wrong table of the right length passes it. Ordering is
    /// established by the fixture test in Tests/InferlensLiteRTTests, not here.
    private var acceptedLabels: LabelTable?

    /// Owns the two `TfLiteInterpreter*`/`TfLiteModel*` handles and frees them in its own synchronous
    /// `deinit`. A plain (non-actor) class, so its `deinit` may read its own non-Sendable stored
    /// properties freely; held only inside the actor and never shared, so it needs no Sendable
    /// conformance. ARC runs this `deinit` when the actor is deallocated — deterministic and race-free
    /// at refcount zero (ADR-0005). Interpreter freed first, then the model it was created from.
    private final class Handles {
        let model: OpaquePointer
        let interpreter: OpaquePointer
        init(model: OpaquePointer, interpreter: OpaquePointer) {
            self.model = model
            self.interpreter = interpreter
        }

        deinit {
            TfLiteInterpreterDelete(interpreter)
            TfLiteModelDelete(model)
        }
    }

    /// The input/output shape resolved from the model. `Sendable` (a `PixelSize` and an `Int`), and it
    /// never leaves the actor.
    private struct Shape: Sendable {
        /// The pixel size the model's input tensor requires; preprocessing resizes to this.
        let inputSize: PixelSize
        /// Number of float elements in the output tensor (e.g. 1001 for this model).
        let outputCount: Int
        /// Float elements in the input tensor: W · H · 3 (RGB). The `3` is validated at load.
        var inputElementCount: Int { inputSize.width * inputSize.height * 3 }
    }

    /// - Parameters:
    ///   - labels: how to name this model's output positions. `nil` — the default — keeps the
    ///     engine's original behaviour exactly: every class is `"class N"`. The composition supplies
    ///     the table derived from the pinned `.mlmodel` at `make bootstrap`; tests that care about
    ///     shape rather than words pass nothing.
    public init(
        modelURL: URL,
        descriptor: ModelDescriptor = .googleMobileNetV2FP32,
        labels: LabelTable? = nil
    ) {
        self.modelURL = modelURL
        self.descriptor = descriptor
        self.labels = labels
    }

    // MARK: - Load

    /// Create the model + interpreter, allocate tensors, read the I/O shapes from the model, and warm
    /// up — so the engine is at steady-state speed by the time this returns (the contract's obligation
    /// that `loadModel` may not defer work into the first `classify`).
    ///
    /// Every error path frees exactly the handles it created and returns WITHOUT storing anything, so a
    /// failed load leaves `handles` and `shape` both `nil` and no `Handles` is ever created — no handle
    /// is freed on the error path and again when a (never-created) `Handles` is released (ADR-0005, the
    /// single-free property).
    ///
    /// Default interpreter options (`nil`): thread count and the delegate (XNNPACK / Core ML / Metal)
    /// are benchmark variables pinned at the on-device bench rung; the simulator run validates shape,
    /// not latency, so nothing is configured here.
    public func loadModel() async throws(InferenceError) {
        guard let loadedModel = TfLiteModelCreateFromFile(modelURL.path) else {
            throw InferenceError.modelLoadFailed
        }

        guard let loadedInterpreter = TfLiteInterpreterCreate(loadedModel, nil) else {
            TfLiteModelDelete(loadedModel)
            throw InferenceError.modelLoadFailed
        }

        guard TfLiteInterpreterAllocateTensors(loadedInterpreter) == kTfLiteOk else {
            TfLiteInterpreterDelete(loadedInterpreter)
            TfLiteModelDelete(loadedModel)
            throw InferenceError.modelLoadFailed
        }

        let resolvedShape: Shape
        do {
            resolvedShape = try resolve(interpreter: loadedInterpreter)
            try warmUp(interpreter: loadedInterpreter, shape: resolvedShape)
        } catch {
            TfLiteInterpreterDelete(loadedInterpreter)
            TfLiteModelDelete(loadedModel)
            throw error
        }

        handles = Handles(model: loadedModel, interpreter: loadedInterpreter)
        shape = resolvedShape
        // The table is checked against the model that was actually loaded, not against a constant:
        // the engine adapts to its model everywhere else, and labelling is no exception.
        acceptedLabels = labels.flatMap { $0.count == resolvedShape.outputCount ? $0 : nil }
    }

    /// Read the input and output tensors and validate this is a model this engine can drive: a float32
    /// image input `[1, H, W, 3]` and a float32 output. A quantized or oddly-shaped model is
    /// `.modelLoadFailed`, not a wrong guess.
    private func resolve(interpreter: OpaquePointer) throws(InferenceError) -> Shape {
        guard TfLiteInterpreterGetInputTensorCount(interpreter) >= 1,
              let input = TfLiteInterpreterGetInputTensor(interpreter, 0),
              TfLiteTensorType(input) == kTfLiteFloat32,
              TfLiteTensorNumDims(input) == 4
        else { throw InferenceError.modelLoadFailed }

        let batch = Int(TfLiteTensorDim(input, 0))
        let height = Int(TfLiteTensorDim(input, 1))
        let width = Int(TfLiteTensorDim(input, 2))
        let channels = Int(TfLiteTensorDim(input, 3))
        guard batch == 1, height > 0, width > 0, channels == 3 else {
            throw InferenceError.modelLoadFailed
        }
        // The buffer we build must match the tensor's byte size exactly (TfLiteTensorCopyFromBuffer's
        // requirement); assert the model agrees with our W·H·3·4 before we ever copy into it.
        guard TfLiteTensorByteSize(input) == width * height * channels * MemoryLayout<Float>.stride else {
            throw InferenceError.modelLoadFailed
        }

        guard TfLiteInterpreterGetOutputTensorCount(interpreter) >= 1,
              let output = TfLiteInterpreterGetOutputTensor(interpreter, 0),
              TfLiteTensorType(output) == kTfLiteFloat32
        else { throw InferenceError.modelLoadFailed }

        let outputCount = TfLiteTensorByteSize(output) / MemoryLayout<Float>.stride
        guard outputCount > 0 else { throw InferenceError.modelLoadFailed }

        return Shape(inputSize: PixelSize(width: width, height: height), outputCount: outputCount)
    }

    /// One throwaway `Invoke` on a zeroed input so the first real `classify` is steady-state. A failure
    /// here means the model cannot actually run — surfaced as a load failure, which is what it is.
    private func warmUp(interpreter: OpaquePointer, shape: Shape) throws(InferenceError) {
        guard let input = TfLiteInterpreterGetInputTensor(interpreter, 0) else {
            throw InferenceError.modelLoadFailed
        }
        let zeros = [Float](repeating: 0, count: shape.inputElementCount)
        let copied = zeros.withUnsafeBytes { buffer in
            TfLiteTensorCopyFromBuffer(input, buffer.baseAddress, buffer.count)
        }
        guard copied == kTfLiteOk, TfLiteInterpreterInvoke(interpreter) == kTfLiteOk else {
            throw InferenceError.modelLoadFailed
        }
    }

    // MARK: - Classify

    public func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        guard let handles, let shape else { throw InferenceError.modelLoadFailed }
        let interpreter = handles.interpreter

        // The contract's cancellation checkpoint (ADR-0014, Decision 3). INVARIANT 1: above the
        // timing split, the only site outside every bracket — `inferStart` closes `preprocess` and
        // opens `infer` in one clock read, so a check between the phases would be measured. None
        // after `inferEnd`: a completed compute is never retroactively cancelled.
        //
        // This is also the ONLY point at which this engine can notice. `TfLiteInterpreterInvoke` is
        // synchronous and on-actor by design (ADR-0005, and the SAFETY note below), so once it is
        // running there is no suspension point at which anything could interrupt it — which is
        // precisely why the contract promises cooperation and not pre-emption.
        guard !Task.isCancelled else { throw InferenceError.cancelled }

        // --- Timing split. Measurement brackets — agent-written, human-reviewed per invariant 1
        // (rung 15): the ContinuousClock reads bracketing preprocess and the compute call. Percentile
        // aggregation, the cold/warm split, and the warm-up policy belong to the LatencyRecorder
        // (rung 12), agent-written and maintainer-decided there; this is only the raw per-run signal.
        //   preprocess = raw bytes → the model's native input (resize + RGB + normalize + tensor copy)
        //   infer      = TfLiteInterpreterInvoke, ALONE
        //
        // SAFETY (load-bearing, ADR-0005): The `TfLiteInterpreter*` is a non-thread-safe C resource. It
        // is touched only synchronously inside this actor with NO suspension between handle access and
        // Invoke completion, so the actor serializes all access. The compiler does NOT enforce this —
        // `OpaquePointer` is trivial, so region isolation would silently let it cross a `sending`
        // boundary and a reentrant second Invoke could race. This discipline is manual: there is no
        // `await` anywhere between the handle read above and Invoke returning.
        let clock = ContinuousClock()

        let preprocessStart = clock.now
        let inputFloats = try preprocess(image, to: shape.inputSize)
        guard let input = TfLiteInterpreterGetInputTensor(interpreter, 0) else {
            throw InferenceError.inferenceFailed
        }
        let copied = inputFloats.withUnsafeBytes { buffer in
            TfLiteTensorCopyFromBuffer(input, buffer.baseAddress, buffer.count)
        }
        guard copied == kTfLiteOk else { throw InferenceError.inferenceFailed }

        let inferStart = clock.now
        guard TfLiteInterpreterInvoke(interpreter) == kTfLiteOk else {
            throw InferenceError.inferenceFailed
        }
        let inferEnd = clock.now
        // --- end timing split

        return InferenceOutcome(
            classifications: try classifications(
                interpreter: interpreter, outputCount: shape.outputCount, labels: acceptedLabels
            ),
            timing: RunTiming(
                preprocess: preprocessStart.duration(to: inferStart),
                infer: inferStart.duration(to: inferEnd)
            ),
            backend: .liteRT
            // No `degradations`: a plain LiteRT run is clean. Thermal throttling and the fallback chain
            // write degradations from ABOVE the engine (the composition layer), never here.
        )
    }

    // MARK: - Preprocessing (owned by the engine, timed as `preprocess`)

    /// Resize the incoming image to the model's required size and convert it to the normalized RGB
    /// float vector the model expects. `vImageScale` is the same resize the Core ML engine uses, so the
    /// two engines share a resize filter — otherwise a benchmark confound (recorded in
    /// BENCHMARK_METHOD.md). Normalization to [-1, 1] is the documented preprocessing for this float
    /// model; it is not baked into the graph, so the engine does it.
    private func preprocess(_ image: ImageBuffer, to size: PixelSize) throws(InferenceError) -> [Float] {
        let scaled = try scale(image, to: size)
        let (rOffset, gOffset, bOffset) = rgbOffsets(for: image.pixelFormat)
        var floats = [Float](repeating: 0, count: size.width * size.height * 3)
        var out = 0
        for pixel in stride(from: 0, to: scaled.count, by: 4) {
            floats[out] = Float(scaled[pixel + rOffset]) / 127.5 - 1.0
            floats[out + 1] = Float(scaled[pixel + gOffset]) / 127.5 - 1.0
            floats[out + 2] = Float(scaled[pixel + bOffset]) / 127.5 - 1.0
            out += 3
        }
        return floats
    }

    /// Scale the raw `ImageBuffer` to the model's size, keeping its 4-channel byte order. vImage does
    /// the scale; the RGB extraction and normalization happen in `preprocess`.
    private func scale(_ image: ImageBuffer, to size: PixelSize) throws(InferenceError) -> [UInt8] {
        var destination = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let sourceRowBytes = image.width * image.pixelFormat.bytesPerPixel
        let destinationRowBytes = size.width * 4

        var failure: InferenceError?
        image.bytes.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destinationBytes in
                guard let sourceBase = source.baseAddress, let destinationBase = destinationBytes.baseAddress else {
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
                if vImageScale_ARGB8888(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags)) != kvImageNoError {
                    failure = .inferenceFailed
                }
            }
        }
        if let failure { throw failure }
        return destination
    }

    /// Where R, G, B sit within a 4-byte source pixel. A `switch`, not a default: a future
    /// `PixelFormat` must force a decision here, not silently take the wrong branch.
    private func rgbOffsets(for format: InferlensCore.PixelFormat) -> (r: Int, g: Int, b: Int) {
        switch format {
        case .rgba8: (0, 1, 2) // R,G,B,A
        case .bgra8: (2, 1, 0) // B,G,R,A
        }
    }

    // MARK: - Output (mapped from the output tensor)

    /// Copy the output tensor and map it to the contract's classifications, sorted by confidence
    /// descending. The full vector is returned, not a top-N: "top labels" is any prefix a consumer
    /// takes. The model emits post-softmax probabilities already in 0...1, so there is no clamp — a
    /// value outside the range would be real signal the conformance suite should catch, not something
    /// to quietly repair.
    ///
    /// The raw `.tflite` has no embedded labels (MODEL_PROVENANCE.md), so the WORDS come from the
    /// supplied table and the INDEX comes from the output vector's own position. Both travel on the
    /// `Classification`: the index is the model's raw identity for the class, the label is a
    /// rendering of it, and keeping both means a word on screen can be traced back to the number
    /// that produced it. With no accepted table every class falls back to `"class N"` — this
    /// engine's behaviour before labels existed.
    private func classifications(
        interpreter: OpaquePointer, outputCount: Int, labels: LabelTable?
    ) throws(InferenceError) -> [Classification] {
        guard let output = TfLiteInterpreterGetOutputTensor(interpreter, 0) else {
            throw InferenceError.inferenceFailed
        }
        var scores = [Float](repeating: 0, count: outputCount)
        let copied = scores.withUnsafeMutableBytes { buffer in
            TfLiteTensorCopyToBuffer(output, buffer.baseAddress, buffer.count)
        }
        guard copied == kTfLiteOk else { throw InferenceError.inferenceFailed }

        var results: [Classification] = []
        results.reserveCapacity(scores.count)
        for (index, score) in scores.enumerated() {
            results.append(Classification(
                label: labels?.label(at: index) ?? LabelTable.fallbackLabel(for: index),
                confidence: score,
                index: index
            ))
        }
        results.sort { $0.confidence > $1.confidence }
        return results
    }

    // Cleanup is RAII: the `Handles` reference type (above) frees the C resources in its own
    // synchronous `deinit` when ARC releases it at actor deallocation. There is no actor `deinit` —
    // a nonisolated actor `deinit` cannot read the non-Sendable handles, and an isolated one crashed
    // on deferred teardown (ADR-0005).
}

public extension ModelDescriptor {
    /// Google's MobileNetV2, FP32 — the artifact `make bootstrap` fetches (see MODEL_PROVENANCE.md).
    /// Declared metadata for the ledger; the engine reads the model's real input size at load, so a
    /// model swap adapts without editing this value.
    static let googleMobileNetV2FP32 = ModelDescriptor(
        name: "MobileNetV2 (Google, FP32)",
        precision: .fp32,
        inputSize: PixelSize(width: 224, height: 224)
    )
}
