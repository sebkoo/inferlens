// InferlensLiteRT — the TensorFlow Lite implementation of the contract, in two files. This file's
// `LiteRTRuntime` is the supply-chain smoke surface: a minimal call to the C runtime's version symbol
// that proves the vendored TensorFlowLiteC binaryTarget (ADR-0002) resolved, linked, and runs.
// `LiteRTEngine` (sibling file) is the actor over the `TfLiteInterpreter*` C handle that conforms to
// InferenceEngine. The handle is non-Sendable and the C API is not thread-safe, but every C call is
// synchronous and on-actor, so the whole module needs ZERO @unchecked Sendable (ADR-0005).
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
