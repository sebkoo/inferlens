// InferlensRemote — the chain's remote leg, as a real engine over a documented wire contract
// (ADR-0013).
//
// This module depends on InferlensCore plus Foundation and Accelerate — the same shape as the two
// on-device engines, and for the same reason: an engine owns its preprocessing, so it needs an
// image path. It does not depend on InferlensFallback and never will; the chain holds legs as
// `any InferenceEngine` and names no concrete engine (ADR-0001).
//
// It replaces `RemoteStubEngine`, which lived in the fallback module precisely because it was NOT
// a conforming engine. This one is: it passes the engine-agnostic conformance suite against the
// loopback server the test target stands up. Composed with no endpoint it throws exactly as the
// stub did, which is what the shipped app does — no public endpoint ships (ADR-0013, Decision 3).
//
// Concurrency (ADR-0005, invariant 2): an actor holding a `URLSession` (a Sendable reference) and
// value configuration. No C handle, no non-Sendable state, no `deinit` obligation — nothing here
// could want an `@unchecked Sendable`, and the repo's count stays at zero.

import Accelerate
import Foundation
import InferlensCore

/// An `InferenceEngine` that classifies over the network.
///
/// The wire contract is ADR-0013 Decision 1, and that ADR is its source of truth — not this file.
/// What crosses: a preprocessed `224x224x3` float32 RGB tensor normalized to `[-1, 1]`. What comes
/// back: `{"model": String, "top": [{"index": Int, "confidence": Float}]}`.
public actor RemoteEngine: InferenceEngine {
    /// Declared metadata, fixed at init like every engine's.
    ///
    /// It names the leg, not the server's model — which this engine cannot know until a response
    /// arrives, and does not persist when one does. `precision` describes the tensor the contract
    /// puts on the wire (float32), not whatever weights answer it. The response's `model` field is
    /// where the server's own identity lives; storing it is a ledger column with no caller yet
    /// (ADR-0013, Decision 1).
    public nonisolated let descriptor: ModelDescriptor = .remote

    /// `nil` means UNCONFIGURED, and that is the shipped composition. It is not a defensive
    /// gesture: with no endpoint the engine throws `.backendUnavailable` from `loadModel()`, which
    /// is byte-for-byte the behaviour the stub had and the reason it had it — an engine that can
    /// never infer must not let load succeed, or it lies through the contract's steady-state
    /// clause (ADR-0010, Decision 1, still standing).
    private let endpoint: URL?

    /// One table, all three legs (ADR-0012). The wire carries indices; the words come from here,
    /// so a fallback onto this leg changes the backend line and never the vocabulary. With no
    /// table every class falls back to `"class N"`, exactly as the other two engines do.
    private let labels: LabelTable?

    private let session: URLSession

    /// Set by `loadModel()`. `classify` before a successful load is a driver error, refused as
    /// `.modelLoadFailed` — the same refusal the chain makes, for the same reason: guessing is
    /// worse than throwing.
    private var isLoaded = false

    /// - Parameters:
    ///   - endpoint: where to POST. `nil` leaves the engine unconfigured and always-throwing.
    ///   - labels: the shared index → word table; `nil` degrades to `"class N"`.
    ///   - timeout: how long one request may take before it is abandoned.
    ///
    ///     **10 seconds, and the reason is the user's, not the network's.** This leg is consulted
    ///     only after BOTH on-device engines have already failed, so someone has been waiting
    ///     through two failures by the time it runs. A leg that hangs is worse for them than a leg
    ///     that fails, because failing is what surfaces the retry `InferenceError.isRetryable`
    ///     promises. Documented rather than ratified: it is a product choice, and it touches none
    ///     of invariant 1's biasable measurement choices — not the percentile definition, not the
    ///     cold/warm boundary, not the warm-up policy (ADR-0013, Decision 4).
    public init(endpoint: URL?, labels: LabelTable? = nil, timeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.labels = labels

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout.seconds
        configuration.timeoutIntervalForResource = timeout.seconds
        session = URLSession(configuration: configuration)
    }

    /// Validates that an endpoint is configured, and makes NO network call.
    ///
    /// INVARIANT 1 — ADR-0013, Decision 5, maintainer-ratified. Rung 12's boundary is reused
    /// verbatim, not extended: cold is the first run after a load, its `total` carrying the load
    /// cost. For a leg with no model to read, no graph to build and no accelerator to warm, that
    /// load cost is approximately zero, and saying so is the honest report. Connection setup is
    /// therefore inside `infer` on the first run, where the round trip is — not hidden, and not
    /// moved somewhere flattering.
    ///
    /// A preflight request here was the alternative and was refused: it would give `load_ns` a
    /// SECOND meaning (handshake time beside model-load time, in one column, told apart only by
    /// which backend the row names), which is a new biasable choice invariant 1 forbids
    /// introducing without its own ratification.
    ///
    /// The contract's steady-state obligation is met by construction rather than by work: there is
    /// nothing this engine could defer into the first `classify`, because there is nothing to load.
    public func loadModel() async throws(InferenceError) {
        guard endpoint != nil else { throw .backendUnavailable }
        isLoaded = true
    }

    public func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        guard let endpoint, isLoaded else { throw .modelLoadFailed }

        // --- Timing split. Measurement brackets — agent-written, human-reviewed per invariant 1;
        // the ratified biasable choices (percentile, cold/warm, warm-up) live in the
        // LatencyRecorder and in ADR-0013 Decision 5, not here. This is the raw per-run signal.
        //   preprocess = raw bytes → the wire body (resize + RGB + normalize + serialize + request)
        //   infer      = the round trip, ALONE
        // `inferEnd` is read immediately after the transfer returns and BEFORE the status code is
        // checked or the body is decoded, so response handling never lands inside the measurement
        // — the same boundary the LiteRT engine holds around Invoke.
        let clock = ContinuousClock()

        let preprocessStart = clock.now
        let body = try preprocess(image, to: descriptor.inputSize)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.inputDescription, forHTTPHeaderField: "X-Inferlens-Input")
        request.httpBody = body

        let inferStart = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A timeout, a refused connection and a dropped socket are all the same fact to the
            // caller: no result came back. `.backendUnavailable` is retryable, which is true of
            // all three. ADR-0013 Decision 4 records the cost — they are indistinguishable in the
            // record, because `InferenceError` carries no payload and a failed walk writes no row.
            throw .backendUnavailable
        }
        let inferEnd = clock.now
        // --- end timing split

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw .backendUnavailable
        }
        let decoded = try Self.decode(data)

        return InferenceOutcome(
            classifications: try classifications(from: decoded),
            timing: RunTiming(
                preprocess: preprocessStart.duration(to: inferStart),
                infer: inferStart.duration(to: inferEnd)
            ),
            backend: .remote
            // No `degradations`: answering over the network is not itself a degradation. The hop
            // that says the chain had to come this far is derived by the chain from its own walk
            // (`.fellBack(from: .coreML, to: .remote)`), above the engine — never written here.
        )
    }

    // MARK: - The wire contract (ADR-0013, Decision 1 — that ADR is the source of truth)

    /// Stated on the wire so a server cannot silently assume a different normalization and answer
    /// with confident nonsense. The client owns preprocessing; this header is what it declares.
    static let inputDescription = "224x224x3;float32;rgb;[-1,1];little-endian"

    private struct Response: Decodable {
        struct Entry: Decodable {
            let index: Int
            let confidence: Float
        }

        /// The server's own model identity. Read and not persisted — see `descriptor`.
        let model: String
        let top: [Entry]
    }

    private static func decode(_ data: Data) throws(InferenceError) -> Response {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw .backendUnavailable
        }
        return decoded
    }

    /// Map the response to the contract's classifications.
    ///
    /// Two things happen here that the LiteRT engine deliberately does NOT do, and the difference
    /// is the trust boundary rather than an inconsistency. That engine reads a pinned local model
    /// and neither sorts defensively nor range-checks, because an out-of-range probability there
    /// would be real signal the conformance suite should catch. This one reads bytes from another
    /// machine, so it validates: a response is untrusted input, and shipping a contract violation
    /// into the ledger because a server sent one is not a defect worth preserving.
    ///
    /// It VALIDATES rather than repairs — an out-of-range confidence throws, it is never clamped.
    /// Clamping would fabricate a number nobody produced, which is the same ban ADR-0010 wrote
    /// against a canned success.
    private func classifications(
        from response: Response
    ) throws(InferenceError) -> [Classification] {
        var results: [Classification] = []
        results.reserveCapacity(response.top.count)
        for entry in response.top {
            guard (0...1).contains(entry.confidence), entry.index >= 0 else {
                throw .backendUnavailable
            }
            results.append(Classification(
                label: labels?.label(at: entry.index)
                    ?? LabelTable.fallbackLabel(for: entry.index),
                confidence: entry.confidence,
                index: entry.index
            ))
        }
        // Sorted here rather than trusted from the wire: "sorted by confidence descending" is an
        // invariant this engine owes the contract, and owing it means enforcing it.
        results.sort { $0.confidence > $1.confidence }
        return results
    }

    // MARK: - Preprocessing (owned by the engine, timed as `preprocess`)

    /// Resize to the contract's input size and convert to the normalized RGB float vector the wire
    /// carries. `vImageScale` and the `[-1, 1]` normalization are character-for-character what
    /// `LiteRTEngine.preprocess` does, deliberately: three engines that resize differently would be
    /// a benchmark confound (BENCHMARK_METHOD.md), and the point of this leg is to be comparable.
    ///
    /// This is the THIRD copy of that resize in the repo. Recorded as a finding against a shared
    /// preprocessing seam in docs/ROADMAP.md rather than fixed here — extracting one is
    /// cross-engine work touching two shipped engines' measured brackets, which is its own rung
    /// with its own review, not a side effect of adding a leg.
    private func preprocess(
        _ image: ImageBuffer, to size: PixelSize
    ) throws(InferenceError) -> Data {
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
        // Little-endian float32, which the header declares. Every platform this ships on is
        // little-endian, so this is a statement of the contract rather than a conversion.
        return floats.withUnsafeBytes { Data($0) }
    }

    /// Scale the raw `ImageBuffer` to the contract's size, keeping its 4-channel byte order. vImage
    /// does the scale; the RGB extraction and normalization happen in `preprocess`.
    private func scale(_ image: ImageBuffer, to size: PixelSize) throws(InferenceError) -> [UInt8] {
        var destination = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let sourceRowBytes = image.width * image.pixelFormat.bytesPerPixel
        let destinationRowBytes = size.width * 4

        var failure: InferenceError?
        image.bytes.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destinationBytes in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destinationBytes.baseAddress
                else {
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
                if vImageScale_ARGB8888(
                    &sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags)
                ) != kvImageNoError {
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
}

public extension ModelDescriptor {
    /// The chain's remote leg. It replaces `remoteStub`, which was named for a type that no longer
    /// exists (ADR-0013, Decision 3). The composition maps `.remote` to this for the exhaustive
    /// switch that picks a ledger row's model; with no endpoint configured it still never reaches
    /// a row, because the leg still never answers.
    static let remote = ModelDescriptor(
        name: "remote",
        precision: .fp32,
        inputSize: PixelSize(width: 224, height: 224)
    )
}

private extension Duration {
    /// `Duration` is the contract's unit; `URLSessionConfiguration` wants a `TimeInterval`. One
    /// conversion, in one place, at the boundary that needs it.
    var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) * 1e-18
    }
}
