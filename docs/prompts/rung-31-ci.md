# Prompt — rung 31: build+test in CI

The instruction that drove the rung, verbatim, plus honest execution notes on where reality pushed
back — the rung-15 convention: the prompt is the plan; the commits are what happened. This rung has
that pushback in unusual quantity, because the design fell out of what the runner actually carried
rather than what the recon predicted, and the runner overturned the load-bearing assumption twice.

This is also where the rung's **keyed claim** retires to. The claim audited out of the tree at this
rung — that *nothing automated builds or tests on push until rung 31* — survives here as the verbatim
record of what it was. A keyed re-run of the pattern quoted in the landing section below will match
THIS file by construction; that is intended, and the landing section states how the sweep is read
around it.

---

## The driving prompt (as received)

> Read the on-disk record FIRST. git log --oneline -6, CLAUDE.md's anti-slop section — rung 31 is
> already NAMED there: "a generic CI | passing badge… stays off the page until that coverage actually
> runs (rung 31)" — this rung exists to earn that sentence's condition, on the badge rule's own terms
> (verifiable and scoped: a reader clicks through to the workflow and sees exactly what it covers). The
> commit-hygiene workflow + its badge are the structural precedent. ROADMAP ladder line 31's exact text
> (scope to IT — the make lint/test stub wiring is Harness-backlog, not this rung, unless the line says
> otherwise), the claims contract, scripts/test-clean.sh (its 0/1/2 contract and pinned destination are
> the single source of truth CI should call, not duplicate), scripts/fetch-models.sh (what bootstrap
> fetches, from where, with what pins — CI runs it cold), and README's "nothing automated builds or
> tests on push until rung 31" sentence, which this rung retires as its keyed claim.
>
> Step 0 — feasibility BEFORE design, facts before the AskUserQuestion. The pinned pair is iPhone 17 Pro
> / iOS 26.1. Recon the GitHub Actions macOS runner images (the runner-images manifest is public): which
> image carries which Xcode, and does any bundled simulator runtime include iOS 26.1 with an iPhone 17
> Pro device type? Only THEN bring the maintainer the options, each with its cost measured not guessed:
>
> Runner has the pinned pair → CI runs bash scripts/test-clean.sh verbatim — the same gate, same
> contract, zero drift.
> Runner lacks it → (a) install the runtime in-workflow (xcodebuild -downloadPlatform iOS — weigh the
> multi-GB download against macOS minute billing and flake risk, with actions/cache if viable), or (b)
> run on the nearest available OS with the deviation IN THE NAME — the workflow and badge label carry
> the actual OS, and the README sentence distinguishes what CI runs from what the counted suite ran
> (every number carries its device + OS; CI's pair is CI's fact). A silent OS substitution under a badge
> implying the pin is the exact lie the badge rule exists to block.
> Simulators unusable at all → a build-only workflow, named as such, and the test badge stays unearned —
> record why.
>
> Decide also: triggers (push to main; concurrency cancel-in-progress; macOS minutes are billed 10x —
> one workflow, no matrix vanity), and whether bootstrap's fetches are cached (keyed on the checksums
> themselves, so a pin change busts the cache by construction).
>
> Step 1 — the workflow, smallest honest scope. One yml: checkout → (cache) → make bootstrap (fails
> closed on any pin) → the test invocation Step 0 ratified → artifact the xcodebuild log on failure. No
> signing (package scheme only; the app shell is not CI's subject). If test-clean needs a destination
> seam for CI, make it an explicit, defaulted env override — a reviewed change to a trust-path script,
> one line, documented at the site.
>
> Step 2 — the badge, only after green exists. Sequencing is the release-first rule transplanted: push
> the WORKFLOW first, watch the first run go green on origin, THEN land the badge + README-sentence
> commit — the badge never points at a run that hasn't happened. Badge form per the precedent: scoped
> name, linked to its own workflow file. Keyed claim for the series: until rung 31|nothing automated
> builds — retired when its quotation enters the prompt doc.
>
> Landing. Rung 31 lands out of numeric order (27–30 open) — the out-of-order entry's technical reason:
> it is trust infrastructure the badge rule already names, with no code dependency on the open rungs.
> Feat = the workflow commit, tagged rung-31 via the recorded convention; the badge/README commit trails
> untagged. Full cadence per commit; counts do not move (CI adds no tests — if the suite count line
> stays untouched, say nothing; never re-anchor without re-measuring). STOP before each push with the
> bundle — including the iteration pushes, marked as such; git push --atomic origin main rung-31 when the
> feat lands; post-push judgment includes the LIVE workflow run URL and its conclusion.
>
> Standing rules: interview material never enters the tree; one commit, one concern; no AI-attribution
> trailers; verify before asserting — the runner manifest, not memory, decides what OS exists; every
> gate prints which way it went.
>
> Notes for whoever runs it: Step 0's recon is the rung — the design falls out of what the runner image
> actually carries. If option 2(b) lands, resist any wording that lets a reader think CI runs the pinned
> pair; the deviation belongs in the badge label itself. And the standing interrupt rule holds: an
> interview invitation pauses this rung mid-iteration without regret — a half-landed workflow on a branch
> of one commit is recoverable; a flubbed interview is not.

---

## Execution notes — where reality pushed back

**1. The prompt's feasibility tree keyed on the simulator; the runner's real constraint was the
toolchain.** Step 0's three branches all turned on one question — does the runner carry iPhone 17 Pro /
iOS 26.1. The recon answered yes (the GA macos-15 image has both), and every CI run resolved that
destination cleanly, so the recon held. But the package would not build. Run 1 failed at package
resolution: the selected Xcode 26.1.1 ships Swift 6.2.1, and `Package.swift`'s swift-tools-version is
6.3. Run 2's fail-loud probe then established the harder fact — no GA macos-15 Xcode (≤ 26.3, all Swift
6.2.3) provides Swift 6.3 at all; it first ships in Xcode 26.6. The axis that decided the rung was one
the tree did not enumerate. "The runner manifest, not memory, decides what OS exists" was the prompt's
own rule, and it caught the wrong assumption twice — each run cheaper than the guess it retired.

**2. No single hosted image carries both Swift 6.3 and the iOS 26.1 runtime.** macos-15 (GA) has the
pinned sim but tops out at Swift 6.2.3; macos-26 (preview) has Xcode 26.6 / Swift 6.3.3 — the same build
(17F113) this repo builds with locally — but only iOS 26.2 / 26.4 / 26.5, no 26.1. The two facts the
counted suite holds together on one machine are split across two runner images, and the rung had to
choose which to keep exact.

**3. The ratified resolution: exact where the failure lives, disclosed where the deviation lives.** The
toolchain is non-negotiable — without Swift 6.3 nothing compiles — so CI takes the exact-toolchain
runner (macos-26 / Xcode 26.6, byte-identical to local). The sim OS is negotiable — CI checks
correctness, not the device latency the bench rung owns — so CI runs the nearest sim macos-26 carries
(iPhone 17 Pro / iOS 26.5) and names the deviation in the workflow, the job name, and the README, kept
distinct from the counted suite's iOS 26.1. This is the prompt's own option 2(b) — "the nearest
available OS with the deviation IN THE NAME" — applied to the axis the tree had keyed on the wrong thing
for. Decided through the review loop, each path's cost read off the manifest rather than guessed.

**4. test-clean gained exactly one defaulted, documented seam — proven locally before it was trusted.**
`INFERLENS_SIM_NAME` / `INFERLENS_SIM_OS` default to the counted pin, so an unset run is byte-for-byte
the prior invocation; local behavior is unchanged by construction. The CI path itself was run green
locally first, on this machine's identical Xcode 26.6 / Swift 6.3.3 at the resolved override (iPhone 17
Pro / iOS 26.5, the newest iPhone 17 Pro it carries), before the workflow was believed. The seam is loud
— the script prints the destination it resolved — and reviewed at the site, so invariant 7 holds:
nothing silently tests a different OS.

**5. The deviation is designed to retire, and the condition is written down.** The seam's DEFAULT is the
counted pin; the override exists only because macos-26 lacks iOS 26.1. When a single hosted image ships
both Swift 6.3 and the iOS 26.1 runtime, deleting the resolve step restores test-clean's default and CI
runs the exact iPhone 17 Pro / iOS 26.1 — the deviation retires with a one-line removal, no other change.
Reconvergence is structural, not a promise to remember.

**6. This file and the keyed sweep.** The rung's keyed pattern is quoted in the driving prompt above and
in the landing section below, so a keyed re-run matches THIS document by construction. The built-in
claims-audit does not carry this pattern — it is keyed-only — so the standing gate that runs in the
cadence and in CI stays clean; only a manual keyed re-run with this exact pattern names this file. That
match is the quotation, read the way the cross-document-pointer spec reads a marked historical quote:
leave it, confirm the marker. None of it is a bare present-tense assertion that no automated build runs
— which is what the sweep exists to catch, and which is exactly what this rung removed from the tree.

---

## Landing — the keyed claim retires here

The rung's keyed pattern, quoted for the record so its retirement is verifiable rather than asserted
(**do not "correct" the quoted pattern or sentence — they are the record of what was retired**):

> `until rung 31|nothing automated builds`

The sentence it retired was the README's *nothing automated builds or tests on push until rung 31*, gone
from the tree at this rung and replaced by the scoped build+test badge and the CI-deviation wording. A
keyed re-run — `bash scripts/claims-audit.sh 'until rung 31|nothing automated builds'` — will name this
file and only this file; that is the quotation, not a regression.

Feat: the workflow commit, tagged `rung-31` (`f8553fe`). Two CI-iteration commits (the toolchain
overturns) and the README/badge commit and this prompt doc trail it, untagged, per the tag convention.
No suite count moved — CI adds no tests. First green run:
https://github.com/sebkoo/inferlens/actions/runs/29888268920 (success).
