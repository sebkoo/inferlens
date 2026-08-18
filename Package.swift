// swift-tools-version: 6.3
import PackageDescription

// Inferlens — local SPM workspace. The app target is thin; every capability lives in a
// module, and the dependency direction is one way: app -> modules -> InferlensCore, with
// InferlensCore depending on nothing. See docs/adr/0001-module-boundaries.md.
let package = Package(
    name: "Inferlens",
    platforms: [
        .iOS(.v26),
        // The app is iOS-only; this line exists for `inferlens-eval`, the offline-eval CLI, which
        // has to RUN on a developer's machine. Without a macOS minimum the host build fails on
        // iOS-era stdlib — "'Duration' is only available in macOS 13.0 or newer" — which is the
        // failure the ROADMAP's build-model section already documents. It changes no dependency and
        // no iOS deployment target, so invariant 5 is untouched (ADR-0015, Decision 2).
        //
        // A bare `swift build` on the host still fails, and not because of this: it reaches
        // InferlensLiteRT, whose vendored xcframework carries no macOS slice. The tool is built by
        // product — `swift build --product inferlens-eval`.
        .macOS(.v26),
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
        .library(name: "InferlensRemote", targets: ["InferlensRemote"]),
        .library(name: "InferlensEval", targets: ["InferlensEval"]),

        // The offline eval as a runnable tool; the library above is the subject.
        .executable(name: "inferlens-eval", targets: ["inferlens-eval"]),
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

        // The LatencyRecorder (p50/p95 over cold/warm): turns a session's LatencySamples into
        // the README's Cold/Warm table. Depends on the contract's timing value types only.
        .target(name: "InferlensBench", dependencies: ["InferlensCore"]),

        // The fallback chain: a chain of engines that is itself an engine. Depends on the
        // contract only — the legs arrive as `any InferenceEngine`.
        .target(name: "InferlensFallback", dependencies: ["InferlensCore"]),

        // The chain's remote leg as a real engine: a URLSession actor over the wire contract
        // ADR-0013 documents. Unconfigured it throws; no public endpoint ships.
        .target(name: "InferlensRemote", dependencies: ["InferlensCore"]),

        // The offline eval: reads the exported NDJSON, groups rows by (backend, device, OS),
        // reports p50/p95, and refuses to recommend below a minimum row count.
        .target(name: "InferlensEval", dependencies: ["InferlensBench", "InferlensCore"]),

        // The eval's CLI shim: arguments, a file read, a print, an exit code — no logic.
        .executableTarget(name: "inferlens-eval", dependencies: ["InferlensEval"]),

        // The vendored TensorFlow Lite C runtime: Google's released TensorFlowLiteC.xcframework
        // 2.17.0, re-zipped and self-hosted as this repo's own GitHub release asset, pinned by
        // checksum (ADR-0002; produced by scripts/vendor-litert.sh).
        .binaryTarget(
            name: "TensorFlowLiteC",
            url: "https://github.com/sebkoo/inferlens/releases/download/litert-2.17.0/TensorFlowLiteC.xcframework.zip",
            checksum: "05e47987466a7bab29bc68910bf510c59a2d129812c7fbf1219eaabdced646f9"
        ),

        // Test support, not a package product: the StubEngine and the engine-agnostic
        // conformance suite. Depends only on the contract, like an engine.
        .target(name: "InferlensConformance", dependencies: ["InferlensCore"]),

        // The app target — composition only. The one place allowed to name concrete engines;
        // models are bundled as resources with `.copy` and staged by `scripts/fetch-models.sh`.
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
                "InferlensRemote",
            ],
            resources: [.copy("Models")]
        ),

        // The contract's own spec, including `LabelTable`'s behaviour (bounds, parse, ambiguity).
        .testTarget(
            name: "InferlensCoreTests",
            dependencies: ["InferlensCore"]
        ),

        .testTarget(
            name: "InferlensConformanceTests",
            dependencies: ["InferlensConformance", "InferlensCore"]
        ),

        // The Core ML engine's tests run the engine-agnostic conformance suite against it.
        .testTarget(
            name: "InferlensCoreMLTests",
            dependencies: ["InferlensCoreML", "InferlensConformance", "InferlensCore"]
        ),

        // The LiteRT engine's tests: the vendored binaryTarget actually links, and the
        // engine-agnostic conformance suite runs against the real engine.
        .testTarget(
            name: "InferlensLiteRTTests",
            dependencies: ["InferlensLiteRT", "InferlensConformance", "InferlensCore"]
        ),

        // The run ledger's spec: the schema migrates, a run round-trips, and the append-only
        // triggers refuse an UPDATE and a DELETE.
        .testTarget(
            name: "InferlensStoreTests",
            dependencies: ["InferlensStore", "InferlensCore"]
        ),

        // The UI state machine's spec: the transition table pair by pair, and every refusal.
        .testTarget(
            name: "InferlensUITests",
            dependencies: ["InferlensUI", "InferlensCore"]
        ),

        // The flag provider's spec: the only place `DocumentStore` is shown to satisfy
        // `FlagCache` before the app composes them (ADR-0009).
        .testTarget(
            name: "InferlensFlagsTests",
            dependencies: ["InferlensFlags", "InferlensStore", "InferlensCore"]
        ),

        // The chain's spec: the conformance suite over the chain as one more engine, the walk's
        // hop derivation, and the failure semantics.
        .testTarget(
            name: "InferlensFallbackTests",
            dependencies: ["InferlensFallback", "InferlensConformance", "InferlensCore"]
        ),

        // The remote leg's spec, including the chain ending in it. The loopback server it runs
        // against lives in this target and uses Network, a system framework (ADR-0013).
        .testTarget(
            name: "InferlensRemoteTests",
            dependencies: [
                "InferlensRemote", "InferlensFallback", "InferlensConformance", "InferlensCore",
            ]
        ),

        // The offline eval's spec, including an identity test against `LatencyRecorder` itself.
        // Its fixture is a published release asset, byte for byte, verified by sha256.
        .testTarget(
            name: "InferlensEvalTests",
            dependencies: ["InferlensEval", "InferlensBench", "InferlensCore"],
            resources: [.copy("Fixtures")]
        ),

        // The property spec for the LatencyRecorder aggregation.
        .testTarget(
            name: "InferlensBenchTests",
            dependencies: ["InferlensBench", "InferlensCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
