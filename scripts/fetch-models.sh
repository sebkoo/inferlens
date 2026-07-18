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
# The Google MobileNetV2 FP32 .tflite is DEFERRED to rung 15 (the LiteRT engine), where the LiteRT
# path is built; pinning it now would be speculative. See MODEL_PROVENANCE.md.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root, regardless of the caller's working directory
DEST="Vendor/Models"
mkdir -p "$DEST"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# name | url | sha256   (Apple's URL HEAD-checked live and sha256 computed 2026-07-18)
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
