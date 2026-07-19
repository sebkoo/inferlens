#!/usr/bin/env bash
#
# Produce the vendored TensorFlowLiteC.xcframework release asset (the LiteRT vendoring step,
# ADR-0002). This is the committed, auditable half of the provenance story: it downloads Google's
# own released binary from the dl.google.com URL named verbatim in the TensorFlowLiteC podspec,
# verifies the archive's sha256, extracts the single core xcframework, ASSERTS its slices from
# Info.plist BEFORE anything else (the project's single riskiest assumption — a missing simulator
# slice fails here, loudly, before any engine logic), re-zips it in SPM's required shape, and prints
# the checksum that Package.swift's binaryTarget(url:checksum:) pins.
#
# The bytes are Google's, unmodified — this script adds only a repackage (tar.gz of three frameworks
# -> zip of the one we consume), which SPM's remote binaryTarget requires (it accepts only a .zip
# whose root entry is the .xcframework; Google serves a .tar.gz of Frameworks/). See ADR-0002.
#
# The output zip is git-ignored (Vendor/ is), never committed: publish it as this repo's own tagged
# GitHub release asset, then pin the printed checksum:
#
#   scripts/vendor-litert.sh
#   gh release create litert-<version> Vendor/litert/TensorFlowLiteC.xcframework.zip \
#       --title 'TensorFlowLiteC <version> (vendored)' --notes '<provenance>'
#   # -> paste the asset URL + the printed checksum into Package.swift's binaryTarget
#
# A version bump is a deliberate, reviewed edit of the pins below — VERSION, the opaque per-release
# path segments in URL, and TARBALL_SHA256 — read from the new version's podspec s.source, then a
# re-run of this script (ADR-0002: the runtime version is a benchmarked variable, not a floating
# dependency).
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root, regardless of the caller's working directory

# --- The pins. A bump edits these, then re-runs. -------------------------------------------------
# 2.17.0 is the latest published TensorFlowLiteC (the C-API pod), 2024-07-29 — newer than the 2.14.0
# the ADR quoted, chosen because the runtime is a benchmarked variable. Both the C pod and the Swift
# pod froze at 2.17.0 (nightlies ended 2025), so this is the newest available, not a mid-stream pick.
VERSION="2.17.0"
# The podspec s.source for this version, read from `pod spec cat TensorFlowLiteC` (cross-checked
# against the CocoaPods CDN) 2026-07-18. Google's released binary on a stable dl.google.com URL; the
# release number (32), timestamp, and content hash are per-release and change on a bump.
URL="https://dl.google.com/tflite-release/ios/prod/tensorflow/lite/release/ios/release/32/20240729-115310/TensorFlowLiteC/${VERSION}/0c10b3543e01f547/TensorFlowLiteC-${VERSION}.tar.gz"
# sha256 of that archive, computed 2026-07-18 (80,242,958 bytes; matches the server content-length).
TARBALL_SHA256="9667b476015f136e5b332ce040e12822c4ac6d5c58947882ddc809cdff0fb99e"

# The slices we require. A frozen artifact that lacks either fails here — the ADR-0002 contingency
# (device-only CI) is a decision to take deliberately, never a slice silently missing at link time.
REQUIRED_SLICES=(ios-arm64 ios-arm64_x86_64-simulator)

WORK="Vendor/litert"
TARBALL="$WORK/TensorFlowLiteC-${VERSION}.tar.gz"
XCFRAMEWORK="$WORK/TensorFlowLiteC.xcframework"
ZIP="$WORK/TensorFlowLiteC.xcframework.zip"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$WORK"

# --- 1. Fetch (idempotent: a cached archive whose sha256 already matches is reused). ---------------
if [ -f "$TARBALL" ] && [ "$(sha256_of "$TARBALL")" = "$TARBALL_SHA256" ]; then
  echo "litert: archive cached (sha256 matches)"
else
  echo "litert: fetching TensorFlowLiteC ${VERSION} (~75 MB)"
  curl -fSL --max-time 300 "$URL" -o "$TARBALL.tmp"
  got="$(sha256_of "$TARBALL.tmp")"
  if [ "$got" != "$TARBALL_SHA256" ]; then
    rm -f "$TARBALL.tmp"
    echo "litert: CHECKSUM MISMATCH — refusing a changed upstream archive" >&2
    echo "  expected $TARBALL_SHA256" >&2
    echo "  actual   $got" >&2
    exit 1
  fi
  mv "$TARBALL.tmp" "$TARBALL"
  echo "litert: archive ok (fetched, sha256 verified)"
fi

# --- 2. Extract only the core xcframework (flatten the leading TensorFlowLiteC-<version>/Frameworks/).
rm -rf "$XCFRAMEWORK"
tar -xzf "$TARBALL" -C "$WORK" --strip-components=2 \
  "TensorFlowLiteC-${VERSION}/Frameworks/TensorFlowLiteC.xcframework"

# --- 3. THE GATE: assert the required slices from Info.plist, before any linking. ------------------
available="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$XCFRAMEWORK/Info.plist")"
for slice in "${REQUIRED_SLICES[@]}"; do
  if ! grep -q "LibraryIdentifier = ${slice}\$" <<<"$available"; then
    echo "litert: MISSING SLICE '${slice}' in $XCFRAMEWORK/Info.plist — NO-GO (ADR-0002 riskiest assumption)" >&2
    echo "--- AvailableLibraries ---" >&2
    echo "$available" >&2
    exit 1
  fi
  echo "litert: slice ok — ${slice}"
done

# --- 4. Re-zip the single xcframework in SPM's required shape (.xcframework at the zip root). -------
rm -f "$ZIP"
ditto -c -k --keepParent "$XCFRAMEWORK" "$ZIP"

# --- 5. Print the pins for the release + Package.swift wiring. -------------------------------------
CHECKSUM="$(swift package compute-checksum "$ZIP")"
cat <<EOF

litert: vendored TensorFlowLiteC ${VERSION}
  archive sha256 : ${TARBALL_SHA256}
  zip            : ${ZIP} ($(stat -f '%z' "$ZIP") bytes)
  zip checksum   : ${CHECKSUM}    <- Package.swift binaryTarget(checksum:)

next: publish the zip as a GitHub release asset, then pin its URL + the checksum above.
EOF
