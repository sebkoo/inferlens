# ADR-0004: Commit hygiene — no AI attribution trailers

- Status: Accepted — 2026-07-17
- Deciders: maintainer
- Relates to: `.githooks/commit-msg`, `.github/workflows/ci.yml` (commit-hygiene job),
  CLAUDE.md invariant 9.

## Decision

Commit messages carry no AI attribution trailer — no `Co-Authored-By: …Claude`, no
`Generated with …`, no 🤖. Enforced two ways:

1. A committed `commit-msg` hook (`.githooks/commit-msg`), wired via `core.hooksPath` by
   `make bootstrap` so it activates on every clone without anyone remembering.
2. A CI lint (`commit-hygiene`) over the pushed/PR commit range, so a bypassed hook
   (`git commit --no-verify`) still fails the pull request.

## Rationale (one line)

AI involvement is disclosed in `docs/prompts/` and `CLAUDE.md` — a method, not a
per-commit disclaimer. The trailer is a disclaimer; the prompt ladder is the method. We
ship the method.

## Why an invariant, not a request

This repo already CI-lints exactly-one `@unchecked Sendable` and one-way dependency
direction. An instruction in CLAUDE.md is a hope; a hook plus a CI lint is an invariant.
The same standard applies here.

## Note on the wiring gap (surfaced, not hidden)

`git config core.hooksPath` writes to `.git/config`, which is **not** cloned — so the hook
*file* travels with the repo but the *wiring* does not. `make bootstrap` re-applies the
wiring on every clone, and the CI lint is the backstop for an unwired hook or `--no-verify`.
