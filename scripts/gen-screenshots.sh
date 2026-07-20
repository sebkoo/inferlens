#!/usr/bin/env bash
#
# scripts/gen-screenshots.sh — regenerate the README's state screenshots into docs/media/.
#
# The images are a BUILD PRODUCT, not a hand capture (ADR-0007). They are produced by
# StateScreenshotTests, which renders each InferenceState with SwiftUI's ImageRenderer on the pinned
# simulator and writes a capture-manifest.txt recording the device and OS the RUNNING PROCESS reported.
# That manifest is what the README caption is written from, so no device name is ever retyped off a
# scheme string or a preview canvas — which is how a caption came within one commit of asserting iOS
# 26.1 for pixels drawn on 26.0.
#
# This is NOT a gate and carries no 0/1/2 contract: it produces files. The gate over what it produces is
# scripts/media-check.sh; the suite that must stay green is scripts/test-clean.sh. Keeping the three
# separate is deliberate — a generator that could also report "clean" would be judging its own output.
#
# The test SKIPS unless TEST_RUNNER_INFERLENS_MEDIA_OUT is set, so an ordinary `test-clean` run never
# writes an image. xcodebuild forwards a variable to the test process only under that prefix; the
# process itself sees INFERLENS_MEDIA_OUT.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root, regardless of caller's working directory

SCHEME="Inferlens-Package"
PIN_NAME="iPhone 17 Pro"
PIN_OS="26.1"
OUT="$PWD/docs/media"

# The pin is NOT optional here, and this is the one place it differs from test-clean. test-clean may fall
# back to any booted simulator, because a test result is about the code. An IMAGE carries its device and
# OS in a caption, so a fallback would silently produce a picture labelled with hardware that did not draw
# it. If the pin is absent, refuse and say so rather than render something mislabelled.
if ! xcrun simctl list devices available 2>/dev/null | grep -q "$PIN_NAME"; then
  echo "gen-screenshots: pinned simulator '$PIN_NAME' is not available — refusing to render." >&2
  echo "                 An image carries its device in the caption; a fallback would mislabel it." >&2
  exit 1
fi

echo "gen-screenshots: rendering into $OUT"
echo "gen-screenshots: destination = $PIN_NAME / iOS $PIN_OS (pinned, no fallback)"

DD="$(mktemp -d "${TMPDIR:-/tmp}/inferlens-shots.XXXXXX")"
trap 'rm -rf "$DD"' EXIT

TEST_RUNNER_INFERLENS_MEDIA_OUT="$OUT" \
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$PIN_NAME,OS=$PIN_OS" \
  -derivedDataPath "$DD" \
  -only-testing:InferlensUITests/StateScreenshotTests \
  2>&1 | tee "$DD/xcodebuild.log" \
       | grep -E "Executed [0-9]+ test|\*\* TEST (SUCCEEDED|FAILED)|(^|[^a-zA-Z])error:" || true

if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$DD/xcodebuild.log"; then
  echo "gen-screenshots: the render run did not succeed (see $DD/xcodebuild.log)." >&2
  exit 1
fi

echo
echo "gen-screenshots: wrote —"
ls -l "$OUT"/*.png 2>/dev/null | awk '{printf "  %8d bytes  %s\n", $5, $9}' || echo "  (no PNGs written)"
echo
echo "gen-screenshots: provenance (the caption is written FROM this, not from the scheme) —"
sed -n '/^device:/,$p' "$OUT/capture-manifest.txt" 2>/dev/null || echo "  (no manifest)"
