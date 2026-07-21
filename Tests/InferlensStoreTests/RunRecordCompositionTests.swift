// The composition initializer's spec: what the RunSink closure is handed becomes a record with
// nothing dropped, nothing reordered and nothing summarized on the way — invariant 3's
// verbatim-travel claim, checked where the initializer lives instead of at the app target, which
// has no test target (and needs none while every seam it closes is proven in a library's suite).

import XCTest
import InferlensCore
import InferlensStore

final class RunRecordCompositionTests: XCTestCase {

    func testTheOutcomeTravelsVerbatimIntoTheRecord() {
        let outcome = InferenceOutcome(
            classifications: [
                Classification(label: "golden retriever", confidence: 0.871),
                Classification(label: "Labrador retriever", confidence: 0.062),
                Classification(label: "kuvasz", confidence: 0.011),
            ],
            timing: RunTiming(preprocess: .milliseconds(2), infer: .milliseconds(11)),
            backend: .coreML,
            degradations: [.fellBack(from: .liteRT, to: .coreML)]
        )
        let sample = LatencySample(load: .cold(.milliseconds(214)), run: outcome.timing)
        let model = ModelDescriptor(
            name: "MobileNetV2 (Google, FP32)",
            precision: .fp32,
            inputSize: PixelSize(width: 224, height: 224)
        )
        let device = DeviceIdentity(model: "iPhone17,1", osVersion: "iOS 26.1")
        let recordedAt = Date(timeIntervalSince1970: 1_770_000_000)

        let record = RunRecord(
            outcome: outcome,
            sample: sample,
            model: model,
            device: device,
            recordedAt: recordedAt
        )

        // The vector, verbatim: all three, the engine's order, labels AND confidences — a top-K
        // or a re-sort here would make the exported row a different claim from the run.
        XCTAssertEqual(
            record.classifications.map(\.label),
            ["golden retriever", "Labrador retriever", "kuvasz"]
        )
        XCTAssertEqual(record.classifications.map(\.confidence), [0.871, 0.062, 0.011])

        // Invariant 3: the fallback survives into the row, both ends named.
        XCTAssertEqual(record.degradations, [.fellBack(from: .liteRT, to: .coreML)])
        XCTAssertEqual(record.backend, .coreML, "the backend that ACTUALLY answered")

        // The composition's own three facts land unchanged.
        XCTAssertEqual(record.device, device)
        XCTAssertEqual(record.recordedAt, recordedAt)
        XCTAssertEqual(record.model.name, "MobileNetV2 (Google, FP32)")

        // The sample is the driver's, not re-derived: cold stays cold with its load cost.
        XCTAssertTrue(record.sample.isCold)
    }
}
