# Prompt — rung 37: the app shell, decided against invariant 5

The instruction that drove the rung, verbatim, plus honest execution notes on where reality
pushed back — the rung-15 convention: the prompt is the plan; the commits are what happened.
One warning to a future reader: the blockquote below quotes this rung's keyed claims-audit
regex literally, so re-running the gate with that key matches THIS file by construction — see
execution note 9 before reading such a red as a finding. The keyed gate's job finished, green,
on the roadmap commit before this file landed.

---

## The driving prompt (as received)

> Driving prompt — the app shell: an installable .app, decided against invariant 5
>
> Paste into a FRESH Claude Code session at the repo root (origin/main = 2dbe8c7, 22 rung tags,
> badge 22/37, suite 142/141/1, zero @unchecked annotations). Commit as the fourth entry in
> docs/prompts/ during the series (rung-15 convention: verbatim + execution notes).
>
> Read the on-disk record FIRST. git log --oneline -15, CLAUDE.md — invariant 5 ("No CocoaPods.
> The build is pure SPM.") is the one this series touches, and invariant 7 (every number carries
> device + iOS) is the one it finally feeds; the Process section's landing order. docs/ROADMAP.md:
> find the launchability raise recorded at the rung-29 landing (search "launchability" /
> "installable") and read its exact wording — it says the shell is an invariant-5-touching
> DECISION, not a chore, and names which rung owns it. The claims-audit contract with both
> amendments. ADR-0002 (how the one binary dependency is pinned), ADR-0010 § Consequences (the
> composition this shell will host), Sources/InferlensApp/InferlensApp.swift (the composed app
> that builds but does not launch), scripts/test-clean.sh (the package scheme the shell must NOT
> break), and the three committed prompt docs for format. Verify every claim by opening the
> file — this method's whole record says memory lies.
>
> Step 0 — ADR-0011: what the shell IS, and what invariant 5 becomes. The maintainer decides via
> the review loop before any file lands. The honest options, each named with what it alone
> provides:
>
> A committed minimal .xcodeproj wrapping the local package: zero new tools, the standard
> signing/run path, diff-noisy project file. Invariant 5 then needs its wording precised the
> recorded way (the "exactly one" → "at most one" precedent): the invariant's TARGET was
> dependency management — CocoaPods, checksummed binaries — not the existence of an app shell;
> say so, and state what still fails review (any second dependency manager, any unpinned binary).
> A generated project (XcodeGen or tuist, spec committed, project git-ignored): clean diffs, but
> a new tool dependency that make bootstrap must pin and fetch — weigh it against the
> bootstrap-fails-closed discipline.
> Not deciding is also recorded: if the demo can be produced another way this month, the raise
> stays open — but the device-measurement rungs still need an installable app, so deferral only
> moves the date. Name what unblocks each option.
>
> Whichever lands: bash scripts/test-clean.sh keeps running the PACKAGE scheme untouched — the
> shell adds a run/install path, it must not become a second build system for the tests. The rung
> number comes from the ROADMAP raise, not from this prompt; if it lands out of numeric order,
> the out-of-order section gets its entry with the TECHNICAL reason (the measurement rungs
> require an installable app — that is the reason on record; nothing else belongs in the tree).
>
> Step 1 — the shell itself, smallest honest scope. One app target wrapping the existing
> composition (InferlensApp.swift moves or is referenced — decide in the ADR; the composition
> code itself does not change). Bundle identifier, deployment target = the pinned OS the suite
> already names, the Models resources path proven by make bootstrap (the rung-29 copy step). No
> new capabilities, no App Store metadata, no icons beyond the minimum the build demands — each
> of those is later work with its own justification.
>
> Step 2 — the first device run is a MANUAL checkpoint, and its numbers are the prize. Signing is
> the maintainer's (personal team is fine); the session prepares, the human installs and runs.
> What the run produces, in order of value: (1) the first LEDGER ROWS whose DeviceIdentity is a
> real phone — invariant 7's columns finally carrying device truth; (2) the on-screen p50/p95 for
> the demo recording; (3) the export tapped ON DEVICE, NDJSON off the phone — the loop end to end
> on hardware. Any number quoted anywhere states backend + device + OS from the row itself. What
> this step does NOT produce: bench-grade measurements — that is the measurement rungs' subject,
> with their own ratified path; do not let a hand-run number be dressed as one. README/LIMITATIONS
> sentences that said "no device numbers exist" move to the truth the rows now carry, with the
> same anchored-to-its-moment discipline the suite counts use.
>
> Landing. The amended contract order per commit; keyed claim for the series (≥4 chars, quoted):
> not.{0,12}installable|no device (number|row) — retire it when its own quotation enters the
> prompt doc, per the recorded rule. make land RUNG=NN at the feat HEAD, trailing docs untagged,
> badge derived. STOP before push with the bundle, gates labeled by side. Push --atomic with the
> tag; judgment run after.
>
> Standing rules: interview material never enters the tree — the demo recording is an OUTPUT of
> this series, never a justification inside it; one commit, one concern; verify before asserting;
> the gate must be able to FAIL and print which way it went.
>
> Notes for whoever runs it
> Step 0 is the series. The shell is an afternoon once ADR-0011 is decided; decided silently, it
> is the first invariant broken without a record — and invariant 5's whole value is that its
> exceptions are written. Bring the three options to the review loop as an AskUserQuestion.
> The device rows are the application-readiness payoff. After this series the JD's two open
> gaps — a demo on hardware, latency with device provenance — are commits and rows, not plans.
> The eval-CLI boundary revision (README's "not code here") stays OUT of this series; it is its
> own ADR when real data exists to evaluate.
> Signing cannot be automated and should not be faked. The prompt prepares everything up to the
> human step and says so plainly — a checklist item, not a workaround.

## The mid-series maintainer decision (as received)

> Maintainer decision: the device checkpoint is SKIPPED — proceed on the simulator. Consequences,
> all of them stated:
>
> The checkpoint becomes a SIMULATOR run through the shell: install+launch the App product on the
> pinned sim, classify ≥1 photo, tap thumbs, tap Export; pull the NDJSON via simctl from the app
> container and verify the rows carry the SIMULATOR DeviceIdentity (the existing
> never-poses-as-a-phone guard is the proof). Screen-record it — that recording is the demo for
> now.
> Commit 4 SHRINKS: only the installable-class sentences move (the .app exists; installs and runs
> on the simulator through the shell; the device slice builds unsigned). The no-device-numbers
> sentences REMAIN TRUE and stay. Therefore the keyed claim shrinks to 'not.{0,12}installable'
> only — the 'no device (number|row)' alternatives retire UNUSED, with an execution note: a keyed
> pattern that outlives its rewrite is the counts bug in regex form.
> Commit 5: the raise closes as SHELL-delivered (the rung's ladder line is the shell, and it
> exists); the device run is recorded as the OPEN half, owned by the measurement rungs —
> prediction vs delivery stated, the recorded-correction way.
> Execution notes gain: the checkpoint was reduced to simulator BY MAINTAINER DECISION — a
> decision on record, not a silent skip.
> Nothing anywhere claims hardware. The rows exported are simulator rows and say so in their own
> columns — invariant 7 doing its job either way.

## Execution notes — where reality pushed back

1. **"names which rung owns it" — the raise did not, and the ambiguity became Step 0's second
   question.** On disk the raise names rung 36 only as the rung that would HIT the gap first;
   rung 36's ladder line is the README's completion, so a `rung-36` tag on a shell commit would
   have made the derived status block claim unfinished work. Brought to the review loop beside
   the shell options; the maintainer chose a NEW ladder line — rung 37, Measurement phase, every
   "00–36" range phrase moved in the same edit — so the rung number now genuinely comes from the
   ROADMAP, which is what the prompt asserted all along. The raise's closure records the
   correction as prediction vs ownership, and ADR-0011 cites the future rung-31 lint clause
   ("every `rung-*` tag names a real ladder rung") as the reason a 36-tag was refused.

2. **The repo-root trap was probed, not assumed — and the probe outdid the prediction.** With the
   project temporarily copied to the repo root, `xcodebuild -list` (no `-project` flag, the shape
   of test-clean's invocation) stopped resolving the package workspace and picked the project —
   whose `relativePath = ".."` local-package reference then resolved OUTSIDE the repo entirely
   ("the package manifest at '/Users/…/dev/Package.swift' cannot be accessed"). A root-placed
   shell would not merely hide the `Inferlens-Package` scheme; it would not even build. The shell
   lives under `App/` for exactly this reason, and `test-clean` ran green with the project in the
   tree — 142 counted / 141 run / 1 skipped, re-measured from the log, unchanged.

3. **A minimal project is minimal until the defaults stop covering for it.** Two corrections the
   build forced, both now in the pbxproj: `PRODUCT_NAME` must be set explicitly (without it the
   product resolved to a literal "`.app`" and the build failed on "Multiple commands produce");
   and TensorFlowLiteC — a STATIC framework whose binary is a Mach-O OBJECT — defeats the build
   system's static/dynamic detection, so a dead copy was auto-embedded into the bundle and failed
   the final Validate step on its missing Info.plist. A named script phase deletes the dead copy
   before Validate (its code is already linked into the app binary); the sizes in its comment are
   measured — 23 MB device slice, 51 MB two-arch simulator slice — after an estimated "~35 MB"
   proved wrong in both directions.

4. **The checkpoint was reduced to a SIMULATOR run BY MAINTAINER DECISION — on record, never a
   silent skip.** What the simulator run through the installed shell produced: four ledger runs
   (cold and warm, LiteRT answering), a thumbs DOWN superseded by an UP on the same run — the
   append-only supersede semantics demonstrated live, history kept — the export tapped in the
   app, the share sheet presented, and the NDJSON pulled from the app container. Every exported
   row carries `Simulator (iPhone18,1)` and `iOS 26.1` in its own columns: the `DeviceIdentity`
   guard labels the simulator as such, so no row can pose as a phone. The screen recording is an
   OUTPUT kept outside the tree (ADR-0007: the repo carries no video bytes); no simulator number
   is quoted as a device number anywhere.

5. **The keyed claim shrank mid-series, and half of it retired UNUSED.** The device-row rewrites
   the `no device (number|row)` alternatives were minted for never happened — those sentences
   remain true and stayed — so the alternatives were dropped from the key at the docs rewrite:
   a keyed pattern that outlives its rewrite is the counts bug in regex form (the maintainer's
   words, kept). One neighbouring sentence — "measured in device numbers" — was in the rewrite
   list but never matched the regex; it moved by hand, and no keyed green is cited as evidence
   for it.

6. **A finding against the composition, found by driving the thing.** `ComposedScreen`'s
   `canExport` refresh races the unstructured run-append task (`pendingRunAppend`) that nothing
   awaits before the state becomes `success` — after the FIRST run of a fresh install the export
   button can stay disabled although the row is in the ledger. Recorded in ROADMAP as real by
   construction and unobserved in this drive, with the attribution kept honest: the taps that
   missed did so because the Simulator window maps device points at an offset the session first
   modelled wrongly (the accessibility tree's content group, at (186,170) sized 402×874, settled
   it); the thumbs path awaits the pending append, which is why both verdicts landed.

7. **Counts re-measured, never added — and one was stale from before this rung.** The README said
   "ten ADRs" in one place and "eight ADRs" in another; the directory held ten before ADR-0011
   and holds eleven after. Both sites now say eleven by counting. The "eight" predates this
   series — the drift the cross-document pointer check (Harness backlog) exists to catch.

8. **The raise's own heading carried the keyed phrase, and the closure rewrote it.** The heading
   asserted the gap in the exact words the keyed sweep owns, so it could never sweep clean while
   the heading stood. The closure commit rewrote the heading, kept the original assertion in the
   body as history, and the keyed sweep's last authoritative run — fully green over tree,
   messages and shas — happened at that commit, before this file landed.

9. **This file re-arms the key by construction.** The blockquote above quotes
   `not.{0,12}installable|no device (number|row)` literally, so any keyed re-run from here
   matches this file — the ROADMAP three-way classification's third case (a historical quote,
   left in place), exactly as rung-21's note 3 recorded for its own key. The operative gate from
   the closure commit onward is the unkeyed run.