// The supply-chain smoke test. It proves the vendored TensorFlowLiteC binaryTarget — fetched by SPM
// from the live GitHub release URL, checksum-verified against the Package.swift pin, and linked (a
// static framework plus libc++) — actually runs. `TfLiteVersion()` executing on the simulator and
// returning the pinned version is the end-to-end proof: published asset → SPM fetch → checksum →
// link → run.
//
// This is NOT engine conformance. The LiteRTEngine (the actor over the C interpreter handle, with the
// repo's one reserved @unchecked Sendable, conforming to InferenceEngine) and its run against the
// engine-agnostic suite land at the LiteRTEngine rung. This is the narrowest claim: the runtime is
// wired and callable.

import XCTest
@testable import InferlensLiteRT

final class LiteRTBinaryTargetSmokeTests: XCTestCase {
    /// The version pinned + vendored in scripts/vendor-litert.sh and Package.swift's binaryTarget.
    private let pinnedVersion = "2.17.0"

    func testVendoredRuntimeLinksAndReportsPinnedVersion() {
        let version = LiteRTRuntime.version
        // Greppable marker for the xcodebuild test log.
        print("LITERT_RUNTIME_VERSION=[\(version)]")
        XCTAssertFalse(version.isEmpty, "TfLiteVersion() linked but returned an empty string")
        XCTAssertEqual(version, pinnedVersion, "the linked runtime must be the pinned vendored version")
    }
}
