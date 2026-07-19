#!/usr/bin/env bash
#
# Fetch the pinned, checksum-verified model artifacts into Vendor/Models/ (git-ignored: the models
# are a dependency, not the repo's subject — the bytes are fetched, never committed; ADR-0002).
#
# This script is the machine-readable pin; docs/research/MODEL_PROVENANCE.md is its human-readable
# twin, and the two must agree. Idempotent: a file whose sha256 already matches is left alone. A
# checksum MISMATCH — a silently-changed upstream — fails loudly and leaves nothing behind. That
# failure is the entire point of pinning.
#
# Two sides, two shapes of pin:
#   - Apple FP16 .mlmodel: a direct file download (name | url | sha256).
#   - Google FP32 .tflite: Google publishes it only inside a ~75 MB training-dump .tgz on
#     download.tensorflow.org (there is no standalone .tflite URL). So the archive is fetched, ITS
#     sha256 verified, the single .tflite member extracted, and the MEMBER's sha256 verified too —
#     both pins live in MODEL_PROVENANCE.md. The 78 MB archive is discarded after extract; only the
#     ~14 MB .tflite lands in Vendor/Models and is what the cache check keys on.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root, regardless of the caller's working directory
DEST="Vendor/Models"
mkdir -p "$DEST"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- Direct-file models: name | url | sha256   (Apple's URL HEAD-checked, sha256 computed 2026-07-18)
MODELS=(
  "MobileNetV2FP16.mlmodel|https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2FP16.mlmodel|c76832208ff4c936365f0f2609f7b77f7f1a6caf62b0b429056d5ad7e48635ad"
)

for entry in "${MODELS[@]}"; do
  IFS='|' read -r name url want <<<"$entry"
  path="$DEST/$name"

  if [ -f "$path" ] && [ "$(sha256_of "$path")" = "$want" ]; then
    echo "models: $name ok (cached, sha256 matches)"
    continue
  fi

  echo "models: fetching $name"
  curl -fSL --max-time 300 "$url" -o "$path.tmp"
  got="$(sha256_of "$path.tmp")"
  if [ "$got" != "$want" ]; then
    rm -f "$path.tmp"
    echo "models: CHECKSUM MISMATCH for $name — refusing to install a changed artifact" >&2
    echo "  expected $want" >&2
    echo "  actual   $got" >&2
    exit 1
  fi
  mv "$path.tmp" "$path"
  echo "models: $name ok (fetched, sha256 verified)"
done

# --- Archived model: Google's FP32 .tflite, extracted from its canonical download.tensorflow.org
#     .tgz. The archive URL + sha256 and the extracted member's sha256 are BOTH pinned (verified
#     2026-07-19). Archive OR member mismatch fails loud — the whole point of pinning.
GTFLITE_NAME="mobilenet_v2_1.0_224.tflite"
GTFLITE_SHA256="9f3bc29e38e90842a852bfed957dbf5e36f2d97a91dd17736b1e5c0aca8d3303"
GARCHIVE_URL="https://storage.googleapis.com/download.tensorflow.org/models/tflite_11_05_08/mobilenet_v2_1.0_224.tgz"
GARCHIVE_SHA256="a9fce7e2db6389dfa1e640a9c98a6f29a55e482e463c5f01c377a19806f66ee2"
gpath="$DEST/$GTFLITE_NAME"

if [ -f "$gpath" ] && [ "$(sha256_of "$gpath")" = "$GTFLITE_SHA256" ]; then
  echo "models: $GTFLITE_NAME ok (cached, sha256 matches)"
else
  echo "models: fetching $GTFLITE_NAME via archive (~75 MB download; the extracted .tflite is ~14 MB)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fSL --max-time 600 "$GARCHIVE_URL" -o "$tmp/archive.tgz"

  got_archive="$(sha256_of "$tmp/archive.tgz")"
  if [ "$got_archive" != "$GARCHIVE_SHA256" ]; then
    echo "models: ARCHIVE CHECKSUM MISMATCH for $GTFLITE_NAME — refusing a changed upstream" >&2
    echo "  expected $GARCHIVE_SHA256" >&2
    echo "  actual   $got_archive" >&2
    exit 1
  fi

  tar -xzf "$tmp/archive.tgz" -C "$tmp" "$GTFLITE_NAME"
  got_member="$(sha256_of "$tmp/$GTFLITE_NAME")"
  if [ "$got_member" != "$GTFLITE_SHA256" ]; then
    echo "models: MEMBER CHECKSUM MISMATCH for $GTFLITE_NAME — refusing to install a changed member" >&2
    echo "  expected $GTFLITE_SHA256" >&2
    echo "  actual   $got_member" >&2
    exit 1
  fi

  mv "$tmp/$GTFLITE_NAME" "$gpath"
  echo "models: $GTFLITE_NAME ok (fetched from archive, archive + member sha256 verified)"
fi
