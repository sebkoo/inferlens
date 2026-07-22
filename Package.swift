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

        // The offline eval as a runnable tool. The product is a shim; the library above is the
        // subject (ADR-0015, Decision 2).
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

        // Benchmark aggregation (rung 12): the LatencyRecorder (p50/p95 over cold/warm) turns a
        // session's LatencySamples into the README's Cold/Warm table. Depends on the contract's
        // timing value types only, never an engine — aggregation lives ABOVE the engines (ADR-0001,
        // amended 6 -> 7 modules). The aggregation is agent-written, maintainer-decided (CLAUDE.md
        // invariant 1, third correction).
        .target(name: "InferlensBench", dependencies: ["InferlensCore"]),

        // The fallback chain (rung 21): a chain of engines that is itself an engine. Depends on
        // the contract ONLY — the legs arrive as `any InferenceEngine`, so cross-engine work stays
        // above the engines without this module ever naming one (ADR-0001, amended 7 -> 8
        // modules). It held the remote stub until the remote-leg rung moved that leg out to
        // InferlensRemote, which left this module holding the chain alone (ADR-0013, Decision 6).
        .target(name: "InferlensFallback", dependencies: ["InferlensCore"]),

        // The chain's remote leg as a REAL engine (the remote-leg rung): a URLSession actor over
        // the wire contract ADR-0013 documents. It sits here rather than in InferlensFallback
        // because it is an engine — the stub it replaces lived there precisely because it was not
        // one. Depends on the contract plus Foundation and Accelerate, the same shape as the two
        // on-device engines and for the same reason: an engine owns its preprocessing (ADR-0001,
        // amended 8 -> 9 modules). Unconfigured it throws exactly as the stub did; no public
        // endpoint ships.
        .target(name: "InferlensRemote", dependencies: ["InferlensCore"]),

        // The loop's sixth clause as code (the offline-eval rung): read the exported NDJSON, group
        // rows by (backend, device, OS), report p50/p95, and REFUSE to recommend below a ratified
        // row count. It is the graph's FIRST library -> library arrow — InferlensEval ->
        // InferlensBench — and the arrow is the point rather than a compromise: CLAUDE.md invariant 1
        // makes the percentile, the cold/warm boundary and the warm-up policy ratified choices, and
        // LatencyRecorder is the only place any percentile is computed in this repo. The eval
        // therefore EXECUTES those choices instead of restating them. Legal under the CI dependency
        // lint's rule ("no arrow back toward an engine or into Core") because Bench is neither: it is
        // aggregation over Core's value types, which is exactly what a consumer of aggregation may
        // name. It imports no engine and NOT InferlensStore — the stored tokens are the format
        // (ADR-0001, amended 9 -> 10 modules; ADR-0015).
        .target(name: "InferlensEval", dependencies: ["InferlensBench", "InferlensCore"]),

        // The shim over it: arguments, a file read, a print, an exit code. It holds no logic
        // precisely because it is the one target the simulator suite cannot run.
        .executableTarget(name: "inferlens-eval", dependencies: ["InferlensEval"]),

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
                "InferlensRemote",
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

        // The chain's spec: the conformance suite over the CHAIN as one more engine, the walk's
        // hop derivation, and the failure semantics. The same asymmetry as the engine test
        // targets: the LIBRARY depends only on the contract; the TEST target adds Conformance for
        // the suite and the StubEngine legs. It does NOT depend on InferlensRemote — the chain
        // names no concrete engine in its tests either, and its remote-leg fixture is the in-file
        // failing-on-cue fake (ADR-0013, Decision 6).
        .testTarget(
            name: "InferlensFallbackTests",
            dependencies: ["InferlensFallback", "InferlensConformance", "InferlensCore"]
        ),

        // The remote leg's spec. It depends on InferlensFallback as well as Conformance, because
        // two of its claims are about the leg IN the chain — the suite over a chain ending in a
        // real remote leg, and a walk that steps down twice and is answered over the network.
        // That direction is the right one: a test target may depend on both, while the LIBRARIES
        // never depend on each other (the same asymmetry as InferlensFlagsTests).
        //
        // The loopback server it runs against lives in this target and uses Network, a SYSTEM
        // framework — no package dependency is added, and invariant 5 is untouched (ADR-0013,
        // Decision 2).
        .testTarget(
            name: "InferlensRemoteTests",
            dependencies: [
                "InferlensRemote", "InferlensFallback", "InferlensConformance", "InferlensCore",
            ]
        ),

        // The offline eval's spec. It depends on InferlensEval + InferlensBench + InferlensCore:
        // Bench is named directly because the identity test calls `LatencyRecorder` itself and
        // compares its output to the eval's, which is how "reuse, not reimplementation" is asserted
        // as a fact rather than described in a comment (ADR-0015, Decision 4).
        //
        // Its fixture is a PUBLISHED RELEASE ASSET, byte for byte — the `demo-sim-ac8d402` export,
        // whose sha256 the spec re-computes and compares against the value in the release notes. The
        // shape the tool parses is therefore the shape that actually ships, not the shape a fixture
        // author imagined; `.copy` keeps the bytes exactly as fetched, for the same reason the app's
        // models are copied rather than processed.
        .testTarget(
            name: "InferlensEvalTests",
            dependencies: ["InferlensEval", "InferlensBench", "InferlensCore"],
            resources: [.copy("Fixtures")]
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
