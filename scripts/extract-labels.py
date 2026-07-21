#!/usr/bin/env python3
#
# Derive the ImageNet label table from Apple's MobileNetV2 .mlmodel — the model's OWN embedded
# class labels, which are the ground truth for what index N means.
#
# Why the model and not a published list. A hand-picked "canonical ImageNet list" from the web is
# almost always 1000 entries with no background class, while both models here emit 1001 (index 0 is
# TF-slim's background). Mapping a 1001-wide output through a 1000-entry list shifts every label by
# one, and a WRONG word under a thumbs button is worse than a bare index: it makes the signal
# confidently false. The .mlmodel is already checksum-pinned (MODEL_PROVENANCE.md), so deriving from
# it adds no upstream that can rot and no second thing to trust.
#
# What this does NOT read: it does not verify that the TFLite model's output ordering matches this
# table. Nothing in this file could — the .tflite carries no label strings at all. That claim is
# established by evidence outside this script (the 8-point cross-check against upstream TensorFlow's
# published label_image output, recorded in MODEL_PROVENANCE.md) and proved end to end by the
# fixture test in Tests/InferlensLiteRTTests. This script only extracts; it does not certify.
#
# Output is newline-delimited, one label per line, index 0 first. Deterministic: the same pinned
# .mlmodel always yields byte-identical output, which is what lets make bootstrap pin the DERIVED
# file's sha256 too.
#
# Usage: extract-labels.py <model.mlmodel> <out.txt> [--expect-count N]

import sys


def parse_varint(buf, i):
    """Protobuf base-128 varint. Returns (value, index-after)."""
    result = 0
    shift = 0
    while i < len(buf):
        byte = buf[i]
        result |= (byte & 0x7F) << shift
        i += 1
        if not byte & 0x80:
            return result, i
        shift += 7
        if shift > 63:
            break
    raise ValueError("truncated varint")


def chain_at(buf, start):
    """Parse a maximal run of consecutive `0x0a <len> <utf8>` records beginning at `start`.

    0x0a is protobuf tag 1, wire type 2 (length-delimited) — the field number a Core ML
    StringVector uses for its repeated `vector` of strings. Returns (labels, index-after).
    """
    labels = []
    position = start
    while position < len(buf) and buf[position] == 0x0A:
        try:
            length, after_length = parse_varint(buf, position + 1)
        except ValueError:
            break
        end = after_length + length
        if length == 0 or end > len(buf):
            break
        try:
            text = buf[after_length:end].decode("utf-8")
        except UnicodeDecodeError:
            break
        # A class label is a printable single line. Rejecting control characters keeps the scan
        # from wandering into weight blobs that happen to begin with 0x0a.
        if any(ord(c) < 0x20 for c in text):
            break
        labels.append(text)
        position = end
    return labels, position


def extract(path):
    """The longest such chain in the file is the class-label vector.

    Chosen over searching for a known first label ("background") so the extractor does not bake in
    an assumption about which ordering the model uses — it finds the label vector structurally, and
    the caller asserts the count.
    """
    with open(path, "rb") as handle:
        data = handle.read()

    best = []
    position = 0
    while position < len(data):
        if data[position] != 0x0A:
            position += 1
            continue
        labels, after = chain_at(data, position)
        if len(labels) > len(best):
            best = labels
        # Skip past the chain we just consumed; a chain never starts inside itself.
        position = after if after > position else position + 1
    return best


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: extract-labels.py <model.mlmodel> <out.txt> [--expect-count N]\n")
        return 2

    model_path, out_path = argv[1], argv[2]
    expected = None
    if "--expect-count" in argv:
        expected = int(argv[argv.index("--expect-count") + 1])

    labels = extract(model_path)

    if len(labels) < 2:
        sys.stderr.write(
            "labels: found no class-label vector in %s — the model is not a classifier, or its\n"
            "        encoding changed. Refusing to write a table this script cannot justify.\n" % model_path
        )
        return 1

    if expected is not None and len(labels) != expected:
        sys.stderr.write(
            "labels: COUNT MISMATCH in %s — expected %d labels, extracted %d.\n"
            "        The model's label vector changed shape. Every index would shift, so every word\n"
            "        under a thumbs button would be wrong. Refusing to write it.\n"
            % (model_path, expected, len(labels))
        )
        return 1

    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(labels) + "\n")

    sys.stderr.write("labels: extracted %d labels from %s\n" % (len(labels), model_path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
