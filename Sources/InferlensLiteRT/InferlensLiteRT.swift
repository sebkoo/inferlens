// InferlensLiteRT — the TensorFlow Lite implementation of the contract. This rung wires the vendored
// TensorFlowLiteC binaryTarget (ADR-0002) and proves the supply chain runs: a minimal call to the C
// runtime's version symbol, nothing more. The engine itself — a LiteRTEngine actor owning the
// non-Sendable TfLiteInterpreter* C handle behind the repo's ONE reserved @unchecked Sendable
// boundary, conforming to InferenceEngine — is the LiteRTEngine rung, not this one. There is zero
// @unchecked Sendable here.
//
// TensorFlowLiteC is a STATIC framework (Mach-O MH_OBJECT); Package.swift links libc++ on this target
// so its C++ runtime symbols resolve. Depends, like every engine, only on InferlensCore — plus its
// own runtime.

import TensorFlowLiteC

/// The linked TensorFlow Lite C runtime. At this rung it exposes only its version — the smoke surface
/// that proves the checksum-pinned binaryTarget resolved, verified, linked, and runs.
public enum LiteRTRuntime {
    /// The runtime version, from the C symbol `TfLiteVersion()` (Headers/c_api.h:
    /// `extern const char* TfLiteVersion(void)`). A non-empty value equal to the pinned version is the
    /// end-to-end proof — published asset → SPM fetch → checksum → link → run. Not part of the
    /// `InferenceEngine` contract.
    public static var version: String {
        guard let cVersion = TfLiteVersion() else { return "" }
        return String(cString: cVersion)
    }
}
