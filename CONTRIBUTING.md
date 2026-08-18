# Contributing to Inferlens

Thanks for your interest.

## Setup

```
make bootstrap   # fetch checksum-pinned models; resolve the LiteRT xcframework
```

## Tests

```
make test        # build + run the test suite on the iOS simulator
```

## Pull requests

Branch → PR → CI green → squash-merge. Keep the diff reviewable — a reviewer should be
able to hold the whole change in their head.

## Decisions

Architectural changes go through an ADR in `docs/adr/`. If you disagree with a decision,
open an issue proposing a superseding ADR rather than working around it in code.
