# Issues to file

Twenty drafts lifted out of the old roadmap, one per finding or harness item. File them by hand
and delete this file; nothing links to it.

## Deduplicate overlapping model loads

Two runs started before either load returns can both call `loadModel()`, and the cold sample then
carries whichever load finished last. Cancellation supersedes runs rather than serializing them,
on purpose: awaiting a superseded run would queue the new photo behind a compute that cannot be
interrupted. A shared load task closes it, with the second run awaiting the first's load instead
of starting its own, and it also stops a model being loaded twice.
Files: `Sources/InferlensUI/ClassificationModel.swift`.

## Give every exported NDJSON line a schema version

The export carries no version field. The reader gates on a required key set instead, which
refuses a line missing a key or carrying an unknown one but cannot tell "newer" from "wrong".
A `schema_version` key per line would fix that, and it needs a rule for what an absent version
means, because the two published exports predate the key and a strict gate would refuse the
whole existing corpus on the day it shipped.
Files: `Sources/InferlensStore/LedgerExport.swift`, `Sources/InferlensEval/ExportedRow.swift`.

## The eval corpus is four rows, so the tool can only refuse

`inferlens-eval` parses both published exports and prints a refusal: one backend, one machine,
one warm row per file. The machinery is real and tested; it says nothing about which backend is
faster. It needs twenty warm rows for each of two backends on one device and OS, which the device
benchmark produces. The signal half is thinner still, at three rows across the whole corpus, so
the verdict weighs latency only and says so in its output.
Depends on: the device benchmark.

## Extract the shared preprocessing seam

`LiteRTEngine`, `CoreMLEngine` and `RemoteEngine` each carry their own vImage resize, RGB
extraction and normalization. They are identical by discipline, because three engines that
resized differently would be a benchmark confound, and nothing compares them. A change to one
copy leaves the other two compiling, passing, and measuring a different image. The seam cannot
live in Core, which depends on nothing and this needs Accelerate, so it is either a new module or
a shared internal target: a boundary decision that wants an ADR. Until then, a change to any
engine's resize or normalization is a change to all three.

## Steady-state timing is skipped on shared CI hardware

The conformance suite asserts run 1's compute is within 4x of run 2's, which catches a lazy-load
engine. On a hosted runner it measured 10.3x for Core ML, where the emulated first inference pays
a compile cost warm-up does not cover. The gate now splits into per-engine timing tests that skip
on shared CI hardware and gate fully at 4x locally and on device. Recorded so the skip is visible;
file only if you want the device-side gating tracked.
Status: resolved by scoping; the threshold is unchanged everywhere it runs.

## Loading and classifying looked identical on screen

Both states rendered the same spinner with one differing label, though a cold start happens once
per launch and inference repeats per photo. The load is now a full-width card with the subtitle
"First run only", and inference is a compact inline row, so they differ in shape before a reader
reaches the text. Found by rendering the five states side by side, which no assertion in the repo
could have produced.
Status: closed at the screen change; file only as a record.

## `InferenceEvent.reset` has no emitter

Nothing in the app emits `.reset`; only tests do. Using it would strand the screen, because
`idle` means "nothing is loaded" to the transition table while a driver that has run once holds a
loaded engine, so a reset lands in a state whose only exit draws a load that never happens. The
real fix teaches the machine a notion of "loaded", which is a state-machine change rather than a
screen change. Choosing another photo is legal from `success` and `failed`, so nothing is blocked.
Files: `Sources/InferlensUI/InferenceState.swift`.

## The export button can lag the first run

`ComposedScreen` refreshes `canExport` when the ledger opens and on every state change, while
`ClassificationModel` appends a finished run in an unstructured task nothing awaits before the
state becomes `success`. After the first run of a fresh install the button can stay disabled
though the row is already written, until a later state change refreshes it. The thumbs path does
not race, because it awaits the pending append first. The fix belongs in the composition: refresh
after the pending append completes.
Files: `Sources/InferlensApp/InferlensApp.swift`.

## Core ML loses one class to a dictionary key

`CoreMLEngine` reads `classLabelProbs`, a dictionary keyed by label. The model has 1001 output
positions and 1000 distinct labels, because "crane" names both index 135 and index 518, so two
positions collapse onto one key and one probability never reaches the engine. The engine has
always returned 1000 classifications rather than 1001. The fix reads the raw output vector
positionally. The count is asserted in `CoreMLLabelTests` meanwhile.
Files: `Sources/InferlensCoreML/CoreMLEngine.swift`.

## The ledger stores no class index

`Classification` carries the model's output index, the screen shows it, and the ledger has no
column for it, so a classification read back out of a row has `index == nil` even when the one
written had an index. The deferral is deliberate: the ledger records the word a person judged,
and a migration wants a caller. The first caller is cross-model agreement, where comparing label
strings compares renderings and "cornet" against "cornet, horn, trumpet, trump" is a formatting
difference dressed as a disagreement.
Files: `Sources/InferlensStore/LedgerSchema.swift`.

## Model metadata already lives in three places

`MODEL_PROVENANCE.md` records which bytes at what checksum, `fetch-models.sh` enforces the same
facts and fails closed, and each ledger row copies the model name, precision and input size so it
stays self-contained. A key-value store for model metadata would be a fourth, and the flag cache
is the only half clearly earned. The label-table gap that once looked like a candidate was closed
on the model path instead.
Status: resolved by ADR-0009 and ADR-0012; file only as a record.

## Wire a standing shell-build gate

The Xcode shell is proven by hand: build for the simulator and unsigned for the device slice,
compare the bundled model bytes to the fetched originals, install and launch on the simulator,
and re-run `test-clean` with the project in the tree. That last step matters because a
root-placed project enters xcodebuild's container discovery and breaks the bare
`-scheme Inferlens-Package` resolution, which is why the shell lives under `App/`. Script it with
the 0/1/2 exit contract and run it in CI.

## Check cross-document pointers

Nothing verifies that a reference in prose names something that exists: a file path that moved,
or an identifier no longer in the tree. The motivating case was a wrong CI reference repeated in
eleven prose sites across a workflow, `CLAUDE.md` and the README, which no gate saw. A sweep must
be case-insensitive, cover the root dotfiles as well as the source directories, and classify each
hit as a stale reference, a legitimate tag name, or a historical quote to leave alone.
Related: `scripts/anchor-check.sh` covers the in-page anchor half already.

## Audit claims written ahead of their implementation

A claim written before the thing it describes exists is the one most likely to be wrong, because
nothing has forced it to be true yet. Every correction so far came from new work touching an old
assumption rather than from sequential review: a contract file describing a recorder four steps
before it was built, a flags module describing wiring it never got, a Core ML comment labelling
the brackets hand-written when they were not. For each doc comment describing something not yet
built, check it against what was built, then correct or delete it.

## Give `make lint` real teeth in CI

`make lint` runs `swiftformat --lint` and `swiftlint` locally but nothing enforces it on a push,
and `make test` routes through `make`, which collapses a recipe failure to a bare 2 and erases
the difference between a gate that fired and one that could not run. Run the linters in the
build workflow, and keep the script's 0/1/2 exit contract intact wherever the suite is invoked.
Files: `Makefile`, `.github/workflows/build.yml`.

## Prove the commit-message workflow rejects a bad message

The commit-message lint runs in CI and nothing has ever forced it to refuse a bad message, so its
green is untested. To close it: push a branch whose head commit breaks one rule, confirm the run
fails, and delete the branch. It cannot be done on `main` without pushing the bad commit there.
Files: `.github/workflows/commit-lint.yml`.

## Exercise the could-not-run branch of every script gate

The script gates share one exit contract: 0 clean, 1 findings, 2 could not run. Only
`test-clean`'s has been driven down every path, and doing that found a real bug, where a build
failure returned 1 for a run in which no test executed. `anchor-check` and `media-check` both
have a could-not-run branch nothing has ever forced. Force each, with a non-git working directory
and a missing tool, and confirm the exit is 2 and distinguishable from both a pass and a finding.
Files: `scripts/anchor-check.sh`, `scripts/media-check.sh`.

## Give each gate a negative control

Each gate has been checked by planting the failure it exists to catch, and each fired. Only
`media-check` also has a control that must not be flagged, a well-formed image with alt text
asserted to be left alone beside the offenders. Without one, a gate that refused everything
unconditionally would pass that check and nothing in the record would show it. `anchor-check`
needs a correct in-page anchor that must not be reported, and `test-clean` needs a passing suite
stated as a control rather than assumed from green runs.

## The gates sweep `git ls-files`, so untracked files are skipped

`anchor-check` and `media-check` enumerate their corpus with `git ls-files`, so an untracked file
is never swept and the gate reports clean without saying what it did not read. Observed while
landing an ADR: both gates reported clean over 18 Markdown files, the new file was staged, and
they read 19. Either count untracked Markdown and name it, or exit 2, because a scope the gate
cannot cover should be loud rather than absent. Exit 2 rather than 1: an unswept file is the gate
declining to claim coverage, not a finding.

## Sweep a stale claim across all three surfaces, not just the tree

One false claim once took twelve edits to retract, and three sites were invisible to a working
tree `grep -r`: a claim inside a commit message, a short-sha reference alive locally but dead on
origin, and stale text a rebase resurrected after the sweep had passed. Any check for a retracted
claim has to read the tree, `git log --format=%B`, and referenced shas. The old `claims-audit.sh`
did this and was deleted with the rest of the process machinery; what it was built for is still
real, so record the requirement rather than the script.
