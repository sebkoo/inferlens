## What & why

<!-- One rung, one concern. Link the ROADMAP rung and the ADR(s) this implements. -->

- Rung:
- ADR(s):

## Checklist

- [ ] One concern; commit is a Conventional Commit
- [ ] Green: `make bootstrap && make lint && make test` pass
- [ ] No agent-authored timing code (LatencyRecorder changes are hand-reviewed)
- [ ] At most one `@unchecked Sendable` (the LiteRT C-handle boundary) — CI lint passes
- [ ] No large binaries committed (models / xcframework are checksum-pinned and fetched)
- [ ] Every number in docs carries its device + iOS version
