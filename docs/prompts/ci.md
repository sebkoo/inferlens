# Prompt — build and test in CI

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

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

## What turned out wrong

No hosted image carries both the pinned simulator runtime and the Swift 6.3 toolchain the package
needs. CI keeps the exact toolchain and resolves the newest iOS runtime the image happens to carry
at run time, printing it in the job name and the log rather than assuming a version. The runner also
falsified the steady-state timing check, which measured 10.3x on shared hardware where it passes
locally, so that check now skips on shared CI hardware and gates fully on device.
