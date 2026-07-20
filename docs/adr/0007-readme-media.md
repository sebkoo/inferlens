# ADR-0007: README media — screenshots committed under a byte ceiling, video never committed

- Status: Accepted — 2026-07-20; **amended twice the same day, both at first use**, because a policy
  written before any image existed met its first five images. (1) Decision 1: screenshots are a
  generated build product, not a hand capture — the preview canvas could not render and silently
  reported the wrong OS. (2) Decision 3: a set of images carries one caption under two conditions, not
  one caption per image — five identical disclosures read as boilerplate and boilerplate is skipped.
  Both are recorded in the believed / falsified / resulting-rule form this repo uses for corrections.
- Deciders: maintainer
- Relates to: CLAUDE.md invariant 6 (no large binaries in git) — **made precise here**, not excepted;
  invariant 7 (every number carries its device + iOS version); the anti-slop rule that a badge stays
  only if it is verifiable and scoped. [ROADMAP](../ROADMAP.md) rung 36 completes the README with
  visuals; this ADR decides the rules that rung will be held to.

## Context

There are zero media files in this repo today. That is exactly why the policy is being written now:
the cost of deciding is zero while nothing is at stake, and it will not be zero the first time a
screenshot exists and the question is whether *this* one is fine.

The pressure this policy exists to resist is specific. A screenshot reads as **"this works"** to a
non-developer, and it beats the prose next to it every time. This README currently says, in careful
sentences, that two steps of the product loop exist and do not touch each other; one picture of a
result screen would overwrite all of that in a reader's head. The repo's whole method is that a claim
points at the artifact that backs it. An image is a claim whose backing is invisible, so it needs
rules the prose does not.

A second pressure is mechanical. Git keeps every version of every committed file forever. Text
revises cheaply; a re-shot screenshot does not — each re-shoot is a fresh blob at full size, and a
clone pays for all of them. Invariant 6 already forbids "large binaries" without ever saying what
large means, which makes it unenforceable at exactly the moment it matters.

## Decision 1 — screenshots are committed, video never is

| Artifact | Where it lives | Tracked in git |
|---|---|---|
| Screenshot (PNG, optimized) | `docs/media/` | **Yes** |
| Screen recording / video, any container | a GitHub attachment or release asset, linked by URL | **No — never** |

Screenshots are committed because a README that renders only when an external host is up is not a
README, and because a committed image is reviewable in a diff: it arrives through the same gate as
the sentence it sits under. `docs/media/` is the only directory that may hold them, so the ceiling in
Decision 2 has exactly one place to look.

Video is never committed, in **any** container. The rule covers `.mp4`, `.mov`, `.webm`, and `.gif`
by extension regardless of byte count — nothing enforces it today (Decision 4), so this is a rule
review applies, not a mechanism. When the gate lands it will refuse those extensions rather than test
their size, deliberately:

- A 20-second screen recording cannot come near the per-file ceiling below at a quality worth
  posting, so a size test would refuse every real one anyway while implying some hypothetical small
  one would be welcome.
- `.gif` is included because a GIF of a screen recording **is** video — the container is an image
  format, the content is not, and an extension-shaped loophole is how the first 8 MB file gets in.
- An extension check needs no decoder and cannot be argued with at review time.

**Second correction — screenshots are GENERATED, not hand-captured.** Same shape as the first, found
the same way: by trying to use the rule.

- **Believed:** a screenshot is captured by a human from Xcode's preview canvas, and the caption
  records the device and OS that person read off the selector.
- **Falsified by:** the canvas not working and then lying. Xcode cannot render previews in this
  package at all — the executable target `InferlensApp` wants `ENABLE_DEBUG_DYLIB=YES`, which SPM does
  not cleanly expose — and when it was driven anyway the selector read iPhone 17 Pro / **iOS 26.0**
  while the scheme said **26.1**. The caption drafted from the scheme would have asserted 26.1 over
  pixels drawn on 26.0: an invariant-7 violation printed onto a picture, where it is far harder to
  correct than prose. Any process whose final step is a human retyping a device name off a UI has this
  failure available to it.
- **Resulting rule:** the images are a **build product**. They are rendered by
  [`StateScreenshotTests`](../../Tests/InferlensUITests/StateScreenshotTests.swift) on the pinned
  simulator and regenerated with `bash scripts/gen-screenshots.sh`. The device and OS in the caption
  are read from the process that drew the pixels and written to `docs/media/capture-manifest.txt`,
  which is committed beside the images and is the file the caption is written **from**. Nothing is
  retyped.

That makes the ceilings in Decision 2 a rule about a build product rather than about a screenshot,
which is a widening, not a contradiction — and the test asserts them at the moment each file is
written, so an oversized image fails the suite before it can reach the gate. The generator is
deliberately not a gate and carries no 0/1/2 contract: a generator that also reported "clean" would be
judging its own output.

Committing the output rather than treating it as ephemeral is the deliberate half. A README that
depends on files nobody has is worse than a README with no images, and an image referenced but absent
is a broken claim in the most visible place in the repo.

**Accepted cost, stated plainly:** an attachment URL lives outside the repo. It is not
checksum-pinned, it can rot, and a fork does not carry it. That is tolerable only because of
Decision 3's last rule — no claim in this repo may rest on a media file — so a dead video link costs
a reader an illustration, never a piece of evidence.

## Decision 2 — invariant 6 gets numbers, derived from this tree

Invariant 6 says no large binaries. It has never said what large is, and a 200 KB PNG and a 20 MB mp4
are not the same object. Two ceilings, both derived from what this repo actually weighs today rather
than picked for looking reasonable:

```
$ git ls-files | wc -l                  ->  64 files tracked
$ git ls-files -z | xargs -0 wc -c      ->  393,845 bytes total
$ largest tracked file                  ->  README.md, 36,339 bytes
$ du -sh .git                           ->  2.9 MB
```

| Rule | Value | Why this number |
|---|---|---|
| Per file, `docs/media/*` | **250,000 bytes** | ~7× the largest text file in the repo (`README.md`, 36 KB), and roughly 2× what an optimized PNG of one iPhone screen of flat SwiftUI content actually weighs once downscaled. Generous enough that hitting it means something is wrong — an un-downscaled capture, a screenshot of a photo, a PNG that should have been re-encoded — not that the ceiling is tight. |
| `docs/media/` total | **2,000,000 bytes** | ~5× the entire tracked tree today, and below the current `.git` object store, so media can never become the largest thing a clone pays for. At the ceiling it admits 8 files; Decision 5's sequence calls for 5, which leaves room for re-shoots without room for a gallery. |
| Long edge | **≤ 1200 px** | A README image is displayed at a few hundred points wide. Beyond 1200 px on the long edge nothing is visible that was not visible before, and the bytes are pure cost. This is what keeps the per-file ceiling generous rather than binding. |

Bytes are decimal (250,000, not 256 × 1024) so that the number in this table, the number in the gate,
and the number `ls -l` prints are the same number and nobody has to ask which.

**What these ceilings do not bound, named rather than left to be discovered.** Both are limits on the
*working tree*, and the check that will apply them (Decision 4) reads the working tree. Git history is
cumulative, so five files re-shot four times each cost the clone twenty blobs while the checkout never
leaves 2 MB. No working-tree check can see that. The actual
defence against history growth is the never-commit-video rule plus re-shooting only when the screen
genuinely changed — a discipline, not a gate, and recorded here as a discipline so it is not later
mistaken for something the check covers.

## Decision 3 — captions, which is where the honesty lives

Every image in this repo must carry a caption, and the caption is load-bearing. No image exists yet,
so this is the shape the first one is required to arrive in:

```markdown
![Top-3 result with the fallback banner shown](../media/result-degraded.png)

*iPhone 17 Pro, iOS 26.1, built from `9b54c52`. TensorFlow Lite was unavailable; Core ML answered.*
```

Three rules:

1. **Alt text is required and non-empty.** It is what a screen reader announces and the only part of
   an image a `grep` can read — which also makes it the only part a future claims-audit sweep can
   catch when it goes stale.

2. **Device, iOS version, and the commit it was built from.** Invariant 7 says every number carries
   its hardware and OS. A screenshot of a latency figure is a number, and a picture of one is not
   exempt because the digits happen to be pixels. The short sha is here for a reason invariant 7 does
   not cover: prose can be corrected in place, but an image showing a screen that no longer exists is
   indistinguishable from a current one unless it says which commit it came from.

   **A consequence that trips a gate, named so nobody treats it as a failure.** A caption citing a
   commit that is in the same push makes [`claims-audit`](../../scripts/claims-audit.sh) exit 1 before
   that push: its dead-sha check asks whether the sha is reachable from `origin/main`, and it is not
   yet. The finding is *true* when it fires, so the gate is not wrong and must not be loosened. The
   resolution is the push itself — after it, the sha resolves and the gate returns clean, which is the
   run that counts. Any first-time image whose caption names its own view-code commit has this
   property. Confirmed on this ADR's own first use: exit 1 before the push naming `da3c81a`, clean
   after.

   **Which commit, settled.** The sha names the commit that produced the **view code**, not the commit
   that added the image file. The claim a caption makes is "this is what the code at this sha
   renders" — so it must point at the code, which is the thing a reader can check out and re-render.
   The image's own commit says only when someone got around to capturing it, which answers a question
   nobody asked. A consequence worth stating: the two are never the same commit, because the image
   cannot exist until after the code does.

3. **A SwiftUI preview is not a run, and must say so.** Any image rendered from a preview or from
   constructed values carries this sentence verbatim in its caption:

   > rendered from fabricated values; no engine ran, nothing was written to the ledger.

   The state-machine views are built precisely so that every state can be drawn without a device that
   has thermally throttled ([`InferenceStateView`](../../Sources/InferlensUI/InferenceStateView.swift)).
   That is good design and a standing hazard: it means a convincing screenshot of a degraded result
   can be produced today, before any engine has ever run behind that screen. The sentence is
   mandatory and verbatim so that a reader never has to infer which kind of image they are looking
   at, and so the disclaimer cannot be softened by whoever is posting.

   **First correction — one set-level caption, not one per image.** Recorded in the shape this repo
   records corrections, because it is the same shape as the invariant-1, -2 and -4 corrections: a rule
   written before the thing it governs existed, falsified the first time it was used.

   - **Believed:** every image carries the sentence in its own caption. Written when there were zero
     images, where "every image" and "the image" were the same case.
   - **Falsified by:** rendering the first set of five. Literal compliance puts five identical
     sentences in five adjacent cells, and a sentence repeated five times in a row reads as
     boilerplate — which is skipped. The rule would have been satisfied to the letter while defeating
     its entire purpose, which is that a reader cannot mistake a preview for a run. A disclosure
     nobody reads is decoration, and decoration presented as a safeguard is the failure this repo
     keeps catching elsewhere.
   - **Resulting rule:** images presented as a **set** carry **one** caption covering the set, under
     two conditions, both of which exist to stop the exemption being abused:
     1. It sits **visually adjacent** to the images — immediately above or below them. Never a
        footnote, never a link, never below a fold or a scroll.
     2. It **names its own scope inside the sentence** ("all five of these are rendered from
        fabricated values…"), so it cannot be misread as describing only the nearest image.

   A single image is still a set of one and carries its own caption. The per-image obligations of
   rule 2 — device, iOS version, sha — collapse into the set caption only when they are identical
   across the set; an image shot on different hardware or a different commit leaves the set and
   captions itself.

**And the rule the other three exist to serve: no claim in this repo may rest on a media file.**
Media illustrates a claim the text already makes and already backs with a link to a file, a test, or
a commit. If deleting every image would weaken an argument, the argument was resting on the picture
and needs its evidence written down instead. This is what makes an external video link survivable
(Decision 1) and what keeps a screenshot from quietly becoming the proof that something works.

## Decision 4 — a gate will enforce it, landing with the first screenshot, not now

A size and policy check over `docs/media/` is the natural **fifth script gate**, alongside
[claims-audit](../../scripts/claims-audit.sh), [anchor-check](../../scripts/anchor-check.sh) and
[test-clean](../../scripts/test-clean.sh). It does not exist — `scripts/media-check.sh` is a name this
ADR reserves, not a file. When it lands it will carry the same exit-code contract — `0` clean, `1`
findings, `2` could not run — and be invoked as `bash scripts/media-check.sh`, never through `make`,
which flattens that contract to a bare 2.

**It is not built now, and that is the decision, not an omission.** There are zero media files, so
today the check would pass over an empty set on every run. A gate that cannot fail is not a gate —
the same objection this repo raises against a `make` target that echoes a TODO and exits 0 — and a
green check over nothing is worse than no check, because it reads as coverage.

The trigger is exact: **the check lands in the same commit as the first committed screenshot.** What
it will enforce, split by what is actually machine-checkable:

| Checkable by the gate | Review-only |
|---|---|
| Per-file ≤ 250,000 bytes, named file and actual size in the failure | Whether the caption's device and iOS are *true* |
| `docs/media/` total ≤ 2,000,000 bytes | Whether an image still shows the current screen |
| No `.mp4`/`.mov`/`.webm`/`.gif` tracked anywhere in the repo | Whether a preview image is honestly labelled as one |
| Long edge ≤ 1200 px (`sips -g pixelWidth -g pixelHeight`) | |
| Every image reference in Markdown has non-empty alt text | |
| Every file in `docs/media/` is referenced by at least one Markdown file (no orphans) | |

The right-hand column is not a gap to be closed later by a cleverer regex. A gate can confirm that a
caption *says* iPhone 17 Pro; only a human can confirm the screenshot came from one. Writing that
down here is the difference between a check with known scope and a check mistaken for a guarantee.

**Teeth test, as the standing condition of the gate counting at all.** It will not ship until it has
been made to fail on purpose: plant a file over the ceiling and confirm it is refused **by name and
with its size**, exit 1; plant an `.mp4` and confirm it is refused by extension, exit 1; then remove
both.
Until that has been done and recorded, the gate is not counted in the README's gate table. The README
counts five gates with four teeth-tested today; this one arriving would make it six and five, and the
count moves only when the plant has actually been run.

A `.gitignore` entry for the video extensions lands with the gate, in the same commit, as
belt-and-braces — not before, since without the gate it would be the only thing standing between the
policy and a `git add -f`, and a single unenforced ignore line reads as more protection than it is.

## Decision 5 — the sequence, so nothing is shot before it is real

Each step's artifacts do not exist until the code that produces them exists. Written as a sequence so
that "we could take a screenshot now" is answered by the schedule rather than re-argued:

- **Now — policy only.** No images. No README change claiming visuals exist. This ADR is a decision,
  not a feature.
- **After the wire rung lands** — the first real screenshots, one per user-visible step: picking an
  image, the model loading, inferring, a result with degradation shown, and the thumbs signal
  recorded. Those five steps become the user stories this repo does not have yet, and they do not
  exist until a run produces them. A screenshot of a step is downstream of the step working, never a
  preview of it.
- **When the loop closes** — exactly **one** video: a single uninterrupted pass from picking an image
  to the ledger row. *Uninterrupted* is the entire claim. A cut is where a chain with a gap hides, so
  a video assembled from clips would assert precisely the thing this repo has been careful not to
  assert while the steps do not touch. One take, no edits, or no video.
- **After the on-device bench rung** — the comparison table with numbers in it, and any screenshot of
  those numbers carries its device and iOS by Decision 3, the same as the table does by invariant 7.

## A contradiction this ADR creates, named rather than left to be found

[ROADMAP](../ROADMAP.md) rung 36 reads "add the 20s GIF". Decision 1 forbids a tracked `.gif`
outright, so that wording and this ADR cannot both stand. This ADR is the later decision and
supersedes it: rung 36's artifact is the single uninterrupted video of Decision 5, hosted as an
attachment and linked, not a committed GIF.

The ROADMAP line is **not** edited in this commit — that is its own doc commit against the ladder,
which is the index everything else is downstream of, **pushed alongside this one** so the
contradiction never exists on origin. Recorded here so the contradiction is legible as
a decision with a pending edit rather than read as drift, the same disposition as the rung 26 → 31
correction and the `37fbc1e` exit-code correction already in that file.

## Consequences

- One directory, one ceiling, one gate: `docs/media/` is the only place an image may live, which is
  what makes the total in Decision 2 checkable at all.
- The README stays text-only until the wire rung lands. Every phase currently marked partly built
  keeps having to say so in sentences, which is the correct cost.
- A reader who wants to see the app working before the loop closes cannot, and the honest answer is
  that there is nothing to see yet — not a preview render dressed as a run.
- The gate is deferred, so between now and the first screenshot this policy is held by review alone.
  That window is the price of not shipping a check with nothing to check, and it is bounded by
  Decision 4's trigger being a commit, not a date.

## Alternatives rejected

- **Commit the video too, under a bigger ceiling.** Rejected: there is no ceiling that admits a
  watchable 20-second recording and still leaves invariant 6 meaning anything, and the bytes are
  permanent in history for an artifact that is decoration by Decision 3's last rule.
- **Reference screenshots externally as well, so the repo carries no binaries at all.** Rejected: a
  README whose images 404 is worse than one with none, and an externally hosted image never passes
  through review — it can be swapped after the fact for something the diff never saw.
- **Build the media gate now, so the policy is enforced from the start.** Rejected on this repo's own
  standard: with zero files it would pass unconditionally and could not be teeth-tested, which is the
  empty-`make`-target failure recorded in [CLAUDE.md](../../CLAUDE.md) wearing a different hat.
- **No policy until the first screenshot.** Rejected: that is the moment the decision is most
  expensive and least neutral, with a specific image already in hand arguing for itself.
