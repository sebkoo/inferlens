# Contributing to Inferlens

Thanks for your interest. This repo follows an atomic commit ladder
([docs/ROADMAP.md](docs/ROADMAP.md)); contributions are expected to fit that model.

## Ground rules

- **One rung, one concern.** A change that touches two concerns is split into two.
- **Conventional Commits.** e.g. `feat(core): …`, `build(litert): …`, `docs(method): …`.
- **Every change is green.** `make bootstrap && make lint && make test` must pass.
- **Respect the invariants in [CLAUDE.md](CLAUDE.md)** — especially: no agent-authored
  timing code; exactly one `@unchecked Sendable` (the LiteRT C-handle boundary); no large
  binaries in git; every number carries its device + iOS version.

## Setup

```
make bootstrap   # fetch checksum-pinned models; resolve the LiteRT xcframework
make test        # build + run tests
```

`swift build` alone will not produce a working app — `make bootstrap` fetches the models
first (they are not committed; see [docs/research/MODEL_PROVENANCE.md](docs/research/MODEL_PROVENANCE.md)).

## Pull requests

Fill in the PR template: which rung, which ADR(s), and the green checklist. Keep the
diff reviewable — a reviewer should be able to hold the whole change in their head.

## Decisions

Architectural changes go through an ADR in `docs/adr/`. If you disagree with a decision,
open an issue proposing a superseding ADR rather than working around it in code.
