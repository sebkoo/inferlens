# CLAUDE.md — Inferlens

## What this is

On-device image classification for iOS (Swift 6.3, iOS 26) that logs every inference to an
append-only SQLite ledger so Core ML and TensorFlow Lite can be compared on a real iPhone.
Loop: run → ledger → thumbs → export → eval → choose backend → run.

## Build and test

- `make bootstrap` first: fetches checksum-pinned models and derives the label table into
  `Sources/InferlensApp/Models`, which holds only a `.gitkeep` until it runs.
- Tests: `bash scripts/test-clean.sh` (fresh DerivedData, iPhone 17 Pro / iOS 26.5 simulator).
  Never `swift test` on the host: `InferlensLiteRT`'s xcframework carries no macOS slice.
- App: `open App/Inferlens.xcodeproj`, run on the simulator. A device run needs
  `App/Signing.local.xcconfig` with `DEVELOPMENT_TEAM`; it is git-ignored, and a clean clone
  builds unsigned.
- Eval CLI: `swift build --product inferlens-eval && .build/debug/inferlens-eval <export.ndjson>`

## Architecture rules

- Dependency direction: App → modules → InferlensCore. Core imports nothing. Engines never
  import each other. UI depends on Core and the engine protocol only. Eval → Bench is the one
  library-to-library edge.
- Zero `@unchecked Sendable`. LiteRT's C handles stay on-actor. Adding one needs an ADR.
- The fallback chain is a value: `FallbackEngine` walks an ordered array of legs. Degradation is
  data that reaches the screen and the ledger unchanged.
- UI state is an enum. Every case needs a real producer and a real consumer.
- Pure SPM. No second dependency manager. No unpinned binaries. No model or xcframework bytes
  in git.
- Every latency figure carries device and OS. Simulator numbers are labelled where they appear
  and never fill the results table. Invented or typed latency figures never appear in docs or
  screenshots.
- Timing brackets, the percentile definition, the cold/warm boundary, and the warm-up policy are
  maintainer decisions: propose a change, never make it silently.

## Writing rules (docs, comments, commits)

- README ≤ 150 lines, ≤ 4 badges, no paragraph explaining badges, captions ≤ 1 sentence.
- No self-referential prose about honesty or evidence ("this repo never claims", "checkable, not
  typed", "the built truth", "in one breath", "which is why", "the X is the point"). Show
  evidence in tables and links.
- No process jargon in user-facing text: rung, ladder, gate, teeth-tested, invariant N,
  ratified, keyed claim, harness backlog.
- Comments explain why, never restate what. No banners, no correction chronicles. File headers
  ≤ 5 lines. Target comment/code ratio ≤ 0.3 per file. Long rationale goes in an ADR (≤ 80
  lines) with one link from the code.
- Conventional Commits. Subject ≤ 72 chars, body ≤ 10 lines. Rationale belongs in the PR
  description.
- Banned words: revolutionary, seamless, blazing fast, cutting-edge, leverage, game-changing,
  robust, powerful, elegant, simply, effortlessly.
- Use plain product nouns: engine, fallback, ledger, export, eval, flag.

## Process

- Branch → PR → CI green → squash-merge. The maintainer commits; the agent proposes a diff and
  a commit message and does not run git commit or git push.
- Follow-ups and findings go to GitHub Issues, not into ROADMAP.md or code comments.
- Never commit interview notes, job-description text, or recruiter mail. NOTES.local.md is
  git-ignored scratch.
- Built with an AI coding agent as a pair; disclosed in README ("How this was built") and
  docs/process.md.
