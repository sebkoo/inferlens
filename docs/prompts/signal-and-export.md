# Prompt — the thumbs signal, the export, and the composition

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

> Driving prompt — rungs 25, 26, 29: close the loop, then compose the app
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
> Notes for whoever runs it
>
> Why these three, in this order: 25+26 complete the thesis loop's signal half — the README's
> first sentence becomes fully true, and the "capture user signals for AI evaluation" capability
> becomes demonstrable instead of planned. 29 turns the modules into an app that runs on a phone.
> Together they are the application-readiness gate; 21 (fallback chain), 27 (thermal), 31 (CI)
> proceed in parallel afterward and should not delay anything.
>
> Rung 25's design moment is the duplicate-signal policy; rung 26's is the join shape. Both are
> cheap to decide up front and expensive to re-decide after export consumers exist. If either
> feels arguable, write the two-paragraph decision record first — this repo's pattern is that the
> decision not to build something is worth as much as the build (ADR-0009 proved it).

## What turned out wrong

The flag wiring had no caller. No concrete feature flag existed, so a provider composed into the
app would have had an `isEnabled` nothing reads. The wiring was deferred until a real flag exists,
and the composition names the absence. The screenshot regeneration also came back byte-identical,
because the fixture passed no signal handler and the view draws no thumbs for a nil one.
