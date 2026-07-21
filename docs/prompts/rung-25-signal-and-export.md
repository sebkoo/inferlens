# Prompt — rungs 25, 26, 29: the signal, the export, and the composition

One prompt drove three rungs — deliberately, because together they are the application-readiness
gate: 25 and 26 complete the thesis loop's signal half, 29 composes the modules into an app. It is
committed under rung 25's name per the ladder's split rule (the earliest rung it drives), in the
rung-15 convention: the instruction verbatim, then honest execution notes on where reality pushed
back. The prompt is the plan; the commits are what happened.

---

## The driving prompt (as received)

> Driving prompt — rungs 25, 26, 29: close the loop, then compose the app
>
> Paste the block below into a FRESH Claude Code session opened at the repo root. Everything it
> needs is on disk and pushed (origin/main = 37f3997); it deliberately carries no session context,
> because the repo's own record is the handoff. Commit it as
> docs/prompts/rung-25-signal-and-export.md during rung 25, per the rung-15 convention.
>
> Read the on-disk record FIRST; work from it, not from this prompt. git log --oneline -20,
> CLAUDE.md (the thesis sentence — these three rungs complete its loop; invariants 3, 4, 7; the
> Process section including the landing order), docs/ROADMAP.md (ladder lines for 25, 26, 29; the
> claims-audit contract WITH BOTH AMENDMENTS — the second one fixes the gate order at
> commit→claims-audit→push; the out-of-order section; the recurring-defect table), ADR-0006,
> ADR-0008 (the closure seam — rung 29 is the composition it deferred), ADR-0009 (the FlagCache
> adapter also lands at composition), Sources/InferlensStore/LedgerSchema.swift (versioned
> migrations + the append-only triggers), Sources/InferlensUI/ClassificationModel.swift and
> ClassificationScreen.swift (where the thumb lands), docs/prompts/rung-15-litert-engine.md (the
> prompt-file format). Verify every line number, ordinal, and count you cite by opening the file —
> this series shipped two ordinal errors and three width overflows by trusting memory.
>
> Rung 25 — feat(ui) + feat(store): thumbs up/down → append to ledger.
>
> The signal is a new APPEND-ONLY table, not a column on runs: a row references its run and never
> mutates it. Non-negotiables, all already enforced or documented in the tree:
>
> The new table joins LedgerSchema's trigger list, so <table>_no_update / <table>_no_delete guard
> it like every other table — the file-level guarantee must not decay to per-table (ADR-0009
> records exactly that decay as the reason the flag cache lives elsewhere).
> The schema version bumps through the EXISTING migration machinery. This is the first migration
> since rung 18 wrote it, so it is also the first real test of it — say so in the commit, and
> leave the sequential-migration proof to rung 30 rather than half-landing it here.
> The UI gains NO new state-machine case (invariant 4: a case needs a producer and a signal;
> thumbs is an action available in success, not a state). The write must never block or fail the
> UI — a signal-write failure is a ledger problem to surface in the ledger's terms, not a
> classification failure.
> Duplicate policy is a decision, not an accident: decide whether a second tap on the same run
> overwrites (it cannot — append-only), appends a superseding row, or is refused, and record the
> choice where the schema is defined. Read-side (export, eval) must know which row wins.
>
> Rung 26 — feat(store): ledger export (NDJSON) for offline eval.
>
> One JSON object per line; the reader is offline eval, so every line must be self-contained — the
> ledger's rows already copy model metadata per run (that was rung 19's ADR argument), and
> invariant 7 rides along: device + OS are columns, so they are in every line by construction.
> Decisions to record at the code: how signals join runs in the export (embedded per run vs a
> second stream — pick for the eval reader, not for the writer), and where the file lands
> (share-sheet from the screen is rung-29 wiring; the store-level API takes a destination and
> stays UI-free). Export is read-only over the ledger; it must not hold the write connection open.
>
> Rung 29 — feat(app): the thin app target composes the modules.
>
> Composition ONLY — CLAUDE.md's word for this target is "thin", and every seam it closes already
> has its shape recorded: the engine chosen per ADR-0001's direction (UI sees the protocol), the
> summarize closure per ADR-0008 ({ try? LatencyRecorder().summarize($0) }, one line, no adapter),
> the FlagCache adapter over DocumentStore per ADR-0009 and the rung-20 test's CachedFlagDocument
> (the shipping version of that private struct belongs HERE, not in a library — the libraries must
> stay ignorant of each other). If composition needs more than a screenful of code, something
> leaked out of a module; stop and say so rather than absorbing it.
>
> Landing, per the amended contract — this order is now written down in ROADMAP: edit →
> width/anchor/A1 gates → commit → claims-audit (the only window where A2 sweeps the message being
> landed) → push. make land RUNG=NN tags HEAD and folds the badge; when doc commits follow the
> feat, retag with git tag -f rung-NN <feat-sha> before pushing. Tags are lightweight: push with
> git push --atomic origin main rung-25 rung-26 rung-29 — never --follow-tags. The claims-audit
> guard now exits 2 on a 1–3 char $1; do not pass inline # comments to ANY command in an
> interactive zsh — they arrive as arguments (reproduced, twice).
>
> Every count you write comes from a run: bash scripts/test-clean.sh (0/1/2 contract, never via
> make test), confirm destination = pinned in the log before quoting, re-measure rather than add —
> the suite is 108/107/1 today and all three rungs move it. CLAUDE.md's count line and the
> ROADMAP's anchored sentence must both be updated in the same docs commit that closes the series.
>
> Bring the evidence bundle, then STOP before push. After the push, re-run claims-audit as the
> judgment and confirm origin's rung-tag count moved 18 → 21.
>
> Standing rules: verify before asserting — open the file. One commit, one concern. No
> AI-attribution trailers. Interview material never enters the tree — NOTES.local.md is
> git-ignored for a reason.
>
> Notes for whoever runs it
>
> Why these three, in this order: 25+26 complete the thesis loop's signal half — the README's
> first sentence becomes fully true, and the "capture user signals for AI evaluation" capability
> becomes demonstrable instead of planned. 29 turns the modules into an app that runs on a phone.
> Together they are the application-readiness gate; 21 (fallback chain), 27 (thermal), 31 (CI)
> proceed in parallel afterward and should not delay anything.
>
> Keep the two-session pattern. The driving session writes; the reviewing session verifies every
> approval against the live tree before clearing it. That loop caught real defects in both
> directions this series — including the reviewer's own.
>
> Rung 25's design moment is the duplicate-signal policy; rung 26's is the join shape. Both are
> cheap to decide up front and expensive to re-decide after export consumers exist. If either
> feels arguable, write the two-paragraph decision record first — this repo's pattern is that the
> decision not to build something is worth as much as the build (ADR-0009 proved it).

## Execution notes — where reality pushed back

1. **The flags-at-29 assignment was falsified before a line of composition was written.** The
   prompt assigns "the FlagCache adapter over DocumentStore per ADR-0009 and the rung-20 test's
   CachedFlagDocument" to rung 29. Verification against the tree found that no concrete
   `FeatureFlag` exists anywhere yet — the paywall flag is rung 28's subject — so a provider
   composed at 29 would have an `isEnabled` nothing calls: the same module-with-no-producer
   objection ROADMAP records against rungs 19/20, now at the composition level. Decided with the
   maintainer: the flag wiring lands with rung 28, where the paywall flag gives `isEnabled` its
   first real caller; rung 29's composition carries one line naming the absence as deliberate; and
   the FlagsTests header sentence that promised the adapter to "the app composition rung" is
   corrected to name rung 28 — recorded, not silently edited, the rung-15 way.

2. **The media landing split in two, and the split preserved a decision point the plan had folded
   flat.** The plan had the state-06 fixture gain the thumbs row inside the one docs/media commit.
   Execution found the regeneration came back byte-identical first — the fixture passed no
   `onSignal`, and the view draws no thumbs for a nil handler — so the caption commit landed as
   pure provenance with the disclosure question (a signal control in an image captioned "nothing
   was written") recorded as OPEN in its message. The maintainer then decided — unselected thumbs
   over a no-op handler, the affordance shown while the picture claims nothing recorded — and the
   decision landed as its own commit rather than an amend, so the history keeps the moment the
   question was open. Two commits where the plan drew one, and the second exists because the first
   refused to make a decision in passing.

3. **The keyed sweep fired on its own landing commit's message — mention, not use.** The
   truth-rewrite commit quoted the stale phrases it was removing, and the keyed A2 sweep cannot
   tell a quotation from a claim, so it went red on the very commit that fixed the tree. The same
   class media-check already solved for images by stripping code spans; claims-audit has no such
   stripping. Resolved by rewording the message (an amend, pre-push, so A2 re-swept the reworded
   text) rather than by reading the red as expected — the habit the amended contract exists to
   prevent. Recorded because the next truth-rewrite will meet it again: quote stale claims in a
   landing message by paraphrase, or teach the gate to strip quotation.

4. **The count prediction held, with one asterisk the plan had pre-written.** "All three rungs
   move it" landed as 108 → 123 (rung 25, both halves) → 131 (rung 26) → 132 (rung 29) — but rung
   29's movement came from its store commit; the feat(app) commit itself moves no count, because
   there is no app test target (deliberate — its green bar is the composed app building inside the
   suite run). The plan predicted exactly this shape and asked for it to be recorded rather than
   for a test to be forced into existence.
