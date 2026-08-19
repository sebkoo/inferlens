# ADR-0016: AI disclosure lives in the docs, not in commit trailers

- Status: Accepted — 2026-08-18. Supersedes [ADR-0004](0004-commit-hygiene.md).
- Deciders: maintainer
- Relates to: [README.md](../../README.md) ("How it was built"), [docs/process.md](../process.md),
  `.github/workflows/commit-lint.yml`.

## Summary

- Decision: disclosure of AI involvement lives in the README and `docs/process.md`; commit trailers
  are the committer's choice and nothing lints them.
- Why: a reader learns more from one paragraph and a page of prompts than from a per-commit
  disclaimer, and automation that strips attribution reads as concealment.
- Consequences: the `commit-msg` hook and the trailer grep are gone; the commit lint now checks
  format only.

## Decision

The README says in three sentences that the code was written with an AI coding agent as a pair, who
owns which decisions, and where to read more. `docs/process.md` carries the longer version: what
each prompt asked for and where it turned out wrong. Nothing in the repo inspects commit messages
for attribution, and a contributor may add or omit a trailer as they prefer.

## What replaces the old enforcement

ADR-0004 enforced a no-trailer rule with a committed `commit-msg` hook wired by `make bootstrap`
plus a CI grep. Both are deleted. `.github/workflows/commit-lint.yml` keeps the part that is about
readable history: a Conventional Commits prefix, a subject within 72 characters, and body lines
within 100. `make bootstrap` no longer sets `core.hooksPath`, so a clone gets no hooks it did not
ask for.
