// InferlensLiteRT — the TensorFlow Lite implementation of the contract. The vendored
// TensorFlowLiteC xcframework binaryTarget arrives at rung 09 and LiteRTEngine at rung 11,
// actor-isolated behind one @unchecked Sendable boundary
// (docs/adr/0002-litert-distribution.md). Depends only on InferlensCore.
