import InferlensCore

/// The chain's remote leg: a stub that ALWAYS THROWS (ADR-0010, Decision 1). It is a chain
/// ENTRY, not a conforming engine — the conformance suite runs over the chain, which passes via
/// its real legs, never over this type alone.
///
/// It never returns a canned outcome: a fabricated success would flow through the sink into the
/// ledger and out the NDJSON export as fake eval data. It throws `.backendUnavailable` — the
/// named error a real remote would use, so a future swap is drop-in and the degradation-reason
/// strings do not churn. `loadModel()` throws primarily (an engine that can never infer must not
/// let load succeed — the contract's steady-state clause); `classify` throws as defense-in-depth
/// if ever reached. In the shipping chain it sits last, consulted only after both on-device
/// engines have failed — nearly unreachable, and implying no live remote traffic.
///
/// A stateless value, not an actor: it owns no loaded state because it can never load.
public struct RemoteStubEngine: InferenceEngine {
    /// Never reaches a ledger row — the stub never answers, and the composition maps `.remote`
    /// to this descriptor only for switch exhaustiveness (ADR-0010).
    public let descriptor: ModelDescriptor = .remoteStub

    public init() {}

    public func loadModel() async throws(InferenceError) {
        throw .backendUnavailable
    }

    public func classify(_ image: ImageBuffer) async throws(InferenceError) -> InferenceOutcome {
        throw .backendUnavailable
    }
}

public extension ModelDescriptor {
    /// A named placeholder for the remote stub. MobileNet-shaped so the chain's walk hands the
    /// stub a well-formed buffer if it is ever consulted; no model of this name exists anywhere.
    static let remoteStub = ModelDescriptor(
        name: "remote-stub",
        precision: .fp32,
        inputSize: PixelSize(width: 224, height: 224)
    )
}
