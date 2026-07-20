# docs/media

Screenshots only, 250,000 bytes per file and 2,000,000 bytes for this directory, long edge 1200 px;
video is **never** committed here or anywhere in this repo — it is linked as a GitHub attachment.
The rules, the numbers and where they came from: [ADR-0007](../adr/0007-readme-media.md).

**Naming: `state-NN-<kebab-case-state>.png`**, where `NN` is the order a user meets the state in a run.
The name is not a convention held in someone's head — it is data in
[`StateScreenshotTests`](../../Tests/InferlensUITests/StateScreenshotTests.swift), paired with the state
it renders, so a file and its subject cannot drift apart.

**These files are a build product, not hand captures.** Regenerate them with:

```
bash scripts/gen-screenshots.sh
```

That renders each state on the pinned simulator and rewrites `capture-manifest.txt`, which records the
device, OS, scale and byte size read from the process that drew the pixels. The README's caption is
written from that manifest, so no device name is ever retyped off a scheme string — which is exactly
how a caption came within one commit of claiming iOS 26.1 for pixels drawn on 26.0.

An ordinary `bash scripts/test-clean.sh` writes nothing here: the render test skips unless an output
directory is passed to it.

Nothing yet checks the ceilings on what is committed here — that gate lands next
([ADR-0007, Decision 4](../adr/0007-readme-media.md)). The render test asserts them at the moment each
file is written, which covers these five files and nothing a human drops in by hand.
