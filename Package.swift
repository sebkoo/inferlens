// swift-tools-version: 6.3
import PackageDescription

// Inferlens — local SPM workspace. The app target is thin; every capability lives in a
// module, and the dependency direction is one way: app -> modules -> InferlensCore, with
// InferlensCore depending on nothing. See docs/adr/0001-module-boundaries.md.
//
// Rung 02 (build(spm)): the skeleton only — every target is empty and compiles. Contract
// protocols land at rung 03; the vendored TensorFlowLiteC binaryTarget lands with the LiteRT
// vendoring step (ADR-0002), wired below.
let package = Package(
    name: "Inferlens",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(name: "InferlensCore", targets: ["InferlensCore"]),
        .library(name: "InferlensCoreML", targets: ["InferlensCoreML"]),
        .library(name: "InferlensLiteRT", targets: ["InferlensLiteRT"]),
        .library(name: "InferlensStore", targets: ["InferlensStore"]),
        .library(name: "InferlensFlags", targets: ["InferlensFlags"]),
        .library(name: "InferlensUI", targets: ["InferlensUI"]),
        .library(name: "InferlensBench", targets: ["InferlensBench"]),
        .library(name: "InferlensFallback", targets: ["InferlensFallback"]),
    ],
    targets: [
        // The contract. Zero dependencies, enforced here and by review.
        .target(name: "InferlensCore"),

        // Engines, stores, flags, UI: each depends only on the contract, never on
        // each other. Cross-engine work (fallback, agreement) lives above them.
        .target(name: "InferlensCoreML", dependencies: ["InferlensCore"]),
        .target(
            name: "InferlensLiteRT",
            dependencies: [
                "InferlensCore",
                // The vendored TensorFlow Lite C runtime, checksum-pinned below.
                "TensorFlowLiteC",
            ],
            linkerSettings: [
                // TensorFlowLiteC is a STATIC framework (Mach-O MH_OBJECT); its C++ runtime symbols
                // must be satisfied at link time, or the consumer fails with undefined std::__1
                // symbols. This setting propagates to every product that links InferlensLiteRT.
                .linkedLibrary("c++"),
            ]
        ),
        .target(name: "InferlensStore", dependencies: ["InferlensCore"]),
        .target(name: "InferlensFlags", dependencies: ["InferlensCore"]),
        .target(name: "InferlensUI", dependencies: ["InferlensCore"]),

        // Benchmark aggregation (rung 12): the LatencyRecorder (p50/p95 over cold/warm) turns a
        // session's LatencySamples into the README's Cold/Warm table. Depends on the contract's
        // timing value types only, never an engine — aggregation lives ABOVE the engines (ADR-0001,
        // amended 6 -> 7 modules). The aggregation is agent-written, maintainer-decided (CLAUDE.md
        // invariant 1, third correction).
        .target(name: "InferlensBench", dependencies: ["InferlensCore"]),

        // The fallback chain (rung 21): a chain of engines that is itself an engine, plus the
        // always-throwing remote stub it ends in (ADR-0010). Depends on the contract ONLY — the
        // legs arrive as `any InferenceEngine`, so cross-engine work stays above the engines
        // without this module ever naming one (ADR-0001, amended 7 -> 8 modules).
        .target(name: "InferlensFallback", dependencies: ["InferlensCore"]),

        // The vendored TensorFlow Lite C runtime: Google's released TensorFlowLiteC.xcframework
        // 2.17.0, re-zipped single-xcframework and self-hosted as this repo's own GitHub release
        // asset, pinned by checksum (ADR-0002; produced by scripts/vendor-litert.sh). SPM fetches and
        // checksum-verifies it at build — there is no make-bootstrap step for the runtime. Only
        // InferlensLiteRT depends on it; the engine over its C API lands at the LiteRTEngine rung.
        .binaryTarget(
            name: "TensorFlowLiteC",
            url: "https://github.com/sebkoo/inferlens/releases/download/litert-2.17.0/TensorFlowLiteC.xcframework.zip",
            checksum: "05e47987466a7bab29bc68910bf510c59a2d129812c7fbf1219eaabdced646f9"
        ),

        // Test support (rung 05+), not a package product: the StubEngine and, from rung 06,
        // the engine-agnostic conformance suite. Depends only on the contract, like an engine.
        .target(name: "InferlensConformance", dependencies: ["InferlensCore"]),

        // The app target — composition only, per CLAUDE.md's word "thin". It is the ONE place
        // allowed to name concrete engines and to depend on Bench: the ADR-0008 summarize closure
        // (`{ try? LatencyRecorder().summarize($0) }`) is composed here, which is why the arrow
        // app -> Bench exists at all.
        //
        // Models are bundled as resources with `.copy`, NOT `.process`: CoreMLEngine compiles the
        // raw `.mlmodel` at runtime, and coremlc processing differs across build systems — the app
        // must ship the same bytes `make bootstrap` verified. The directory holds a `.gitkeep`
        // only; `scripts/fetch-models.sh` stages the checksum-verified files into it, and the
        // global `*.mlmodel` / `*.tflite` ignore patterns keep them untracked (invariant 6).
        .executableTarget(
            name: "InferlensApp",
            dependencies: [
                "InferlensUI",
                "InferlensStore",
                "InferlensFlags",
                "InferlensCoreML",
                "InferlensLiteRT",
                "InferlensBench",
                "InferlensFallback",
            ],
            resources: [.copy("Models")]
        ),

        // Rung 05: the StubEngine's own smoke tests. Rung 06 adds the suite run against it.
        // The contract's own first test target. Core was protocols and field-holding value types
        // until the label table arrived, and there was nothing in it a test could be wrong about —
        // which is why this target did not exist before. `LabelTable` has behaviour (bounds, the
        // parse, the refusal to resolve an ambiguous label), so it gets a spec. Depends on
        // InferlensCore and nothing else, which is the same claim the module makes about itself.
        .testTarget(
            name: "InferlensCoreTests",
            dependencies: ["InferlensCore"]
        ),

        .testTarget(
            name: "InferlensConformanceTests",
            dependencies: ["InferlensConformance", "InferlensCore"]
        ),

        // The Core ML engine's tests run the SAME engine-agnostic suite against the real engine —
        // so this test target depends on InferlensConformance, while the InferlensCoreML LIBRARY
        // above does not (the library depends only on InferlensCore + the Core ML framework). That
        // asymmetry is the point: the suite lands in a test, never in the shipped engine.
        .testTarget(
            name: "InferlensCoreMLTests",
            dependencies: ["InferlensCoreML", "InferlensConformance", "InferlensCore"]
        ),

        // The LiteRT tests: the supply-chain smoke test (the vendored TensorFlowLiteC binaryTarget —
        // fetched from the live release URL, checksum-verified, linked static + libc++ — actually runs)
        // AND, from rung 15, the engine-agnostic conformance suite run against the real LiteRTEngine —
        // so this test target also depends on InferlensConformance + InferlensCore, while the
        // InferlensLiteRT LIBRARY depends only on InferlensCore + TensorFlowLiteC. That asymmetry is the
        // point: the suite lands in a test, never in the shipped engine.
        .testTarget(
            name: "InferlensLiteRTTests",
            dependencies: ["InferlensLiteRT", "InferlensConformance", "InferlensCore"]
        ),

        // The run ledger's smoke test: the schema migrates, a run round-trips through SQLite, and
        // the append-only triggers refuse an UPDATE and a DELETE. Depends on InferlensStore +
        // InferlensCore only — a ledger is persistence over the contract's value types, not an
        // engine, so Conformance has no place here. The migration and append-only INVARIANT suite
        // is its own ladder rung; this target is where it will land.
        .testTarget(
            name: "InferlensStoreTests",
            dependencies: ["InferlensStore", "InferlensCore"]
        ),

        // The UI state machine's spec: the transition table pair by pair (legal moves AND every
        // refusal), and the proof that no case is decoration. Depends on InferlensUI +
        // InferlensCore only — NOT an engine and NOT Conformance. That is the claim under test as
        // much as anything: the machine is a pure function over two enums, so it needs no model
        // file, no engine and no device capability to be driven through all five of its states.
        .testTarget(
            name: "InferlensUITests",
            dependencies: ["InferlensUI", "InferlensCore"]
        ),

        // The flag provider's spec. It depends on InferlensFlags, InferlensStore AND InferlensCore
        // — the same asymmetry as the conformance targets: the LIBRARIES never depend on each other
        // (InferlensFlags cannot import InferlensStore), but a TEST target may depend on both, which
        // is the only place `DocumentStore` can be shown to satisfy `FlagCache` before the app
        // target composes them (ADR-0009).
        .testTarget(
            name: "InferlensFlagsTests",
            dependencies: ["InferlensFlags", "InferlensStore", "InferlensCore"]
        ),

        // The chain's spec: the conformance suite over the CHAIN as one more engine (never over
        // the remote stub alone — ADR-0010), the walk's hop derivation, and the failure
        // semantics. The same asymmetry as the engine test targets: the LIBRARY depends only on
        // the contract; the TEST target adds Conformance for the suite and the StubEngine legs.
        .testTarget(
            name: "InferlensFallbackTests",
            dependencies: ["InferlensFallback", "InferlensConformance", "InferlensCore"]
        ),

        // Rung 12: the property spec for the LatencyRecorder aggregation. Depends on
        // InferlensBench + InferlensCore only — NOT Conformance; this is a value-aggregation spec,
        // not an engine-conformance run.
        .testTarget(
            name: "InferlensBenchTests",
            dependencies: ["InferlensBench", "InferlensCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
