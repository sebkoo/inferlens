# Prompt — the app shell

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

> Driving prompt — the app shell: an installable .app, decided against invariant 5
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

## What turned out wrong

The maintainer reduced the device checkpoint to a simulator run, on record, so the exported rows
carry a simulator identity and nothing claims hardware. The project also needed more than the
prompt's minimum: an explicit `PRODUCT_NAME`, and a phase deleting an auto-embedded copy of the
static framework. A project at the repo root broke the package scheme's bare resolution, which is
why the shell lives under `App/`.
