# ADR-0002: LiteRT / TensorFlow Lite distribution on iOS

- Status: Accepted — 2026-07-17
- Deciders: maintainer
- JD must-haves: "Swift Package Manager" and "TensorFlow Lite".

## Context

The job description names both Swift Package Manager and TensorFlow Lite as must-haves.
Task 0 asked whether both can be satisfied at the same seam on iOS today.

Primary source — Google's canonical iOS quickstart,
`developers.google.com/edge/litert/ios/quickstart` (301 from
`ai.google.dev/edge/litert/ios/quickstart`), fetched 2026-07-17: the general LiteRT /
TensorFlow Lite runtime ships via **CocoaPods** (`TensorFlowLiteSwift`,
`TensorFlowLiteObjC`, subspecs `CoreML`/`Metal`) or a **Bazel source** build only.
**There is no first-party SPM package.**

The `TensorFlowLiteSwift` CocoaPod is **frozen**, not merely slowing: the stable line
stops at 2.17.0 and nightlies ended in 2025, so read in mid-2026 there is no live
release stream. The real choice is therefore not "pod vs binaryTarget." It is a choice
**between two frozen artifacts — the frozen CocoaPod and a frozen, self-hosted
XCFramework — and only the latter can be consumed from Swift Package Manager.** That is
the whole decision.

Out of scope: **LiteRT-LM** (the LLM framework) does ship a first-party Swift/SPM API,
but that is a different product slot — the LLM slot is off-target per the ground-truth
facts. See [docs/research/PRIOR_ART.md](../research/PRIOR_ART.md).

## What the artifact actually is (named, not deferred)

The `TensorFlowLiteC` CocoaPod is a thin pointer, not a build. Its `s.source` is a
first-party Google archive on `dl.google.com`, and it vendors real XCFrameworks. From
the podspec (`tensorflow/tensorflow/lite/ios/TensorFlowLiteC.podspec`, verbatim):

```
s.source = { :http => "https://dl.google.com/tflite-release/ios/prod/tensorflow/lite/release/ios/release/30/20231002-210715/TensorFlowLiteC/2.14.0/883c6fc838e0354b/TensorFlowLiteC-2.14.0.tar.gz" }
core.vendored_frameworks   = 'Frameworks/TensorFlowLiteC.xcframework'
coreml.vendored_frameworks = 'Frameworks/TensorFlowLiteCCoreML.xcframework'
metal.vendored_frameworks  = 'Frameworks/TensorFlowLiteCMetal.xcframework'
```

So the bytes we want — `TensorFlowLiteC.xcframework` — are Google's own released
binary, hosted at a stable `dl.google.com/tflite-release/...` URL. The pod adds nothing
to those bytes but a Podfile entry.

## Decision

InferlensLiteRT depends on Google's released `TensorFlowLiteC.xcframework` as an SPM
`binaryTarget(name:url:checksum:)`, re-hosted by us.

**Why we cannot point `binaryTarget(url:)` at `dl.google.com` directly.** SPM's remote
`binaryTarget` accepts exactly one container shape: a `.zip` whose root entry is the
`.xcframework`. Google serves the wrong container *and* the wrong layout — a `.tar.gz`
(not a `.zip`) bundling three frameworks under a `Frameworks/` directory (not a single
xcframework at the root). SPM will not fetch a `.tar.gz`, and even unpacked the layout
is not what it expects. Repackaging to a single-xcframework `.zip` is therefore
mandatory, not stylistic — it is the same reason `kewlbear/TensorFlowLiteC` re-zips
rather than linking Google's URL. Concretely, the LiteRT vendoring step will:

1. download the `dl.google.com/tflite-release/...TensorFlowLiteC-<version>.tar.gz`
   archive for a chosen version and extract `TensorFlowLiteC.xcframework`;
2. **before any linking**, read the xcframework's `Info.plist` (`AvailableLibraries`)
   and assert an `ios-arm64_x86_64-simulator` slice is present — this is the first gate;
3. re-zip that single XCFramework;
4. publish the `.zip` as **this repository's own tagged GitHub release asset**; and
5. pin its checksum via `swift package compute-checksum` (declared in `Package.swift`
   by the `binaryTarget` wiring).

The extract/repackage step is a committed script, so provenance is auditable. The
Swift-facing engine (`InferlensLiteRT`) is our own thin wrapper over the C API, conforming to the
InferlensCore contract.

**Honest consequence of this:** InferlensLiteRT holds a **frozen, checksum-pinned copy
of Google's released `TensorFlowLiteC` binary** at one chosen version. It does not track
the pod and it does not track Google's future releases. Updating is a deliberate,
reviewed version bump (re-fetch, re-extract, re-zip, re-checksum) — which is exactly
what we want, because the runtime version is a benchmarked variable, not a floating
dependency.

## Rationale

- Keeps the entire build pure SPM — the SPM must-have is satisfied structurally, not by
  a shim. (CocoaPods cannot be consumed from inside an SPM package anyway.)
- Puts SPM and TensorFlow Lite at the exact same seam, which is the point the JD tests.
- A pinned-checksum `binaryTarget` is reproducible and supply-chain-auditable, and the
  repackage script documents that the bytes are Google's, unmodified.
- Mirrors the recognizable community pattern (e.g. `kewlbear/TensorFlowLiteC` on Swift
  Package Index) of repackaging this same Google artifact as an SPM binaryTarget —
  while keeping the artifact under our own release + checksum rather than trusting a
  third-party individual's release.

## Is the LiteRT distribution writable? Yes.

Provenance and mechanism are fully specified above. Only three things are produced *when
the LiteRT vendoring step runs*, because they cannot exist earlier: the exact version pin, the final
release-asset URL for our re-hosted `.zip`, and the computed checksum (a checksum cannot
be computed before the `.zip` exists). None of these is a deferred *decision* — they are
outputs of executing the named, decided procedure.

## Consequences and the riskiest assumption

- We own XCFramework updates manually (re-pin on a version bump). Acceptable and
  desirable, per above.
- xcframework slices are per platform + environment + arch (`ios-arm64` device;
  `ios-arm64_x86_64-simulator` simulator), not per iOS version. TFLite has shipped the
  combined `ios-arm64_x86_64-simulator` slice (which includes Apple Silicon) since
  **v2.9.1**; our target is well past that, so the slice is expected to be present. But
  this is issue/search evidence, not a read of the pinned version's `Info.plist` — so
  **the LiteRT vendoring step's first action reads `Info.plist` and asserts the simulator
  slice** (above), and the `binaryTarget` wiring then proves it links on the simulator. If a
  chosen frozen artifact ever
  lacks the slice, the documented contingency is device-only CI for the LiteRT path
  with LiteRT runtime tests gated to on-device `make bench`. This is the
  project's single riskiest assumption, isolated here on purpose: if the slice is
  missing, the LiteRT vendoring step goes red before any engine logic (`InferlensLiteRT`)
  exists.

## Slice check — evidence (2026-07-17)

Artifact inspected: `github.com/kewlbear/TensorFlowLiteC/releases/download/0.0.20250619/TensorFlowLiteC.xcframework.zip` (tag `0.0.20250619`).

Root listing — `ls -1` of the unzipped `TensorFlowLiteC.xcframework/`, verbatim:

```
Info.plist
ios-arm64
ios-arm64_x86_64-simulator
PrivacyInfo.xcprivacy
```

Finding: the `ios-arm64_x86_64-simulator` slice is present (it includes the Apple Silicon
simulator), so the project's single riskiest assumption is **falsified for this repackage**.

Scope of this evidence: the check was run against **kewlbear's repackage, not the
`dl.google.com/tflite-release/...` archive this repo will self-host**. kewlbear repackages
Google's released bytes and does not add slices, so our artifact *should* be identical —
but "should" is precisely what this ADR exists to remove. The LiteRT vendoring step
therefore still reads the
`Info.plist` (`AvailableLibraries`) of **our own** re-zipped xcframework before
extract/zip/host. Today's check made the assumption cheap to falsify; it did not verify the
bytes we will ship.

## Alternatives rejected

- **CocoaPods `TensorFlowLiteSwift`** — frozen and not SPM-consumable (cannot be used
  from inside an SPM package).
- **A third-party community package as a `.package` dependency** — e.g.
  `kewlbear/TensorFlowLiteC`, whose `master` `Package.swift` points `binaryTarget` at its
  own GitHub release `0.0.20250619` with pinned checksums, repackaged (per its README)
  from the official CocoaPod binary. Viable and recognizable, but it adds an individual's
  release to our supply chain; self-hosting the same Google bytes under our own release +
  checksum is a stronger provenance story for a repo whose pitch is disclosed rigor.
- **Bazel build from source** — heavier, and the `TensorFlowLiteC_xcframework` Bazel
  target has documented breakage (broken headers, `tensorflow/tensorflow#95417`); extra
  risk for no provenance gain over freezing Google's own published binary.
- **`binaryTarget(name:path:)` with the XCFramework vendored in-repo** — rejected: the
  ~40 MB+ multi-slice binary would sit permanently in git history, whereas a URL +
  checksum target is resolved and cached by SPM. The same clone-bloat argument applies
  to the two vendor MobileNetV2 models (Apple FP16 + Google FP32, ~23 MB together — large
  enough that committing them is real clone bloat too, not the ~15 MB an earlier draft
  assumed), so it is applied **uniformly**:
  neither the models nor the xcframework is committed. Both are pinned by checksum and
  fetched — the models at `make bootstrap` (source URLs + checksums in
  `MODEL_PROVENANCE.md`), the xcframework by SPM (`binaryTarget(url:checksum:)`). The
  "subject vs dependency" line survives not as commit-vs-fetch but as *where provenance
  is recorded*: the models are the experiment's subject, so their provenance lives in a
  human-readable `MODEL_PROVENANCE.md`; the runtime is a dependency, so its pin lives in
  `Package.swift`. Checksums guarantee identical bytes on every clone either way.
