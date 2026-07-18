# Security policy

## Scope

Inferlens is an on-device benchmarking artifact. It performs image classification locally
and writes a local ledger; it ships no server and, in v0, makes no network calls at
runtime (the remote fallback is a stub). The realistic security surface is the
supply chain: the checksum-pinned LiteRT `binaryTarget` and the checksum-pinned model
artifacts (see [docs/adr/0002](docs/adr/0002-litert-distribution.md) and
[docs/research/MODEL_PROVENANCE.md](docs/research/MODEL_PROVENANCE.md)).

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub's **Report a vulnerability**
(Security → Advisories) on this repository, rather than opening a public issue. Include
steps to reproduce and the affected commit. We aim to acknowledge within a few days.

## Supply-chain notes

- The LiteRT runtime is a self-hosted re-zip of Google's released `TensorFlowLiteC`
  XCFramework, pinned by `swift package compute-checksum`. The repackaging script is
  committed, so the provenance (Google's bytes, unmodified) is auditable.
- Model artifacts are pinned by checksum in `MODEL_PROVENANCE.md` and fetched at
  bootstrap; a checksum mismatch fails the build.
