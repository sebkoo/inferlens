// swift-tools-version: 6.3
import PackageDescription

// Inferlens — local SPM workspace. The app target is thin; every capability lives in a
// module, and the dependency direction is one way: app -> modules -> InferlensCore, with
// InferlensCore depending on nothing. See docs/adr/0001-module-boundaries.md.
//
// Rung 02 (build(spm)): the skeleton only — every target is empty and compiles. Contract
// protocols land at rung 03; the vendored LiteRT binaryTarget at rung 09.
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
    ],
    targets: [
        // The contract. Zero dependencies, enforced here and by review.
        .target(name: "InferlensCore"),

        // Engines, stores, flags, UI: each depends only on the contract, never on
        // each other. Cross-engine work (fallback, agreement) lives above them.
        .target(name: "InferlensCoreML", dependencies: ["InferlensCore"]),
        .target(name: "InferlensLiteRT", dependencies: ["InferlensCore"]),
        .target(name: "InferlensStore", dependencies: ["InferlensCore"]),
        .target(name: "InferlensFlags", dependencies: ["InferlensCore"]),
        .target(name: "InferlensUI", dependencies: ["InferlensCore"]),

        // Test support (rung 05+), not a package product: the StubEngine and, from rung 06,
        // the engine-agnostic conformance suite. Depends only on the contract, like an engine.
        .target(name: "InferlensConformance", dependencies: ["InferlensCore"]),

        // Thin app placeholder — composition only. The real iOS app target lands at
        // rung 25; this exists now to exercise the app -> modules -> Core graph.
        .executableTarget(
            name: "InferlensApp",
            dependencies: [
                "InferlensUI",
                "InferlensStore",
                "InferlensFlags",
                "InferlensCoreML",
                "InferlensLiteRT",
            ]
        ),

        // Rung 05: the StubEngine's own smoke tests. Rung 06 adds the suite run against it.
        .testTarget(
            name: "InferlensConformanceTests",
            dependencies: ["InferlensConformance", "InferlensCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
