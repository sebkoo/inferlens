# Prompt — rung 38: an index becomes a word the user can judge

The instruction that drove the rung, verbatim, plus honest execution notes on where reality
pushed back — the rung-15 convention: the prompt is the plan; the commits are what happened.
Two of the notes below record the prompt being **wrong on a matter of fact** about the repo, which
is the most useful thing a document like this can preserve.

---

## The driving prompt (as received)

> Read the on-disk record FIRST. git log --oneline -10, CLAUDE.md — the thesis (the signal loop: a
> thumbs press is only evidence if the user could JUDGE what they confirmed; today the screen shows
> class 973, an ImageNet index no user can judge, so the signal measures plausibility-feeling, not
> correctness — that gap is this rung), invariants 6 and 8 (how model-coupled assets are fetched and
> pinned), invariant 3/4 (untouched here). docs/ROADMAP.md: the ladder, the claims-audit contract
> with both amendments, and the rung-37 precedent for APPENDING a new numbered rung with its
> technical reason. ADR-0002 (the pinning pattern), scripts/ bootstrap (where model assets land), the
> result view and ClassificationModel (where class N renders), LedgerSchema/LedgerExport (indices in
> columns — verify, don't assume), the conformance suite, and the committed prompt docs for format.
>
> Step 0 — the decision, before any code. Two questions for the review loop (AskUserQuestion), each
> with what only it provides:
>
> Where does the truth of index→label live? Check the MODELS first: Core ML models often embed class
> labels in their own metadata, and the TFLite distribution may ship a labels file from the same
> source. If either model carries its own table, that table is ground truth and both engines map
> through ONE copy of it — a hand-picked "canonical ImageNet list" from the web risks an off-by-one
> against the model's actual output ordering, and a WRONG word under a thumbs button is worse than an
> index: it makes the signal confidently false. Name the verification that proves ordering (the
> model's own metadata, or a fixture image with a known top-1).
> How does the table reach the app? (a) fetched by make bootstrap, checksum-pinned beside the models
> — keeps model-coupled data on the model path, repo stays artifact-free; (b) committed as a small
> text file — diff-reviewable, no network step, and invariant 6 targets large binaries, which a ~30
> KB text table is not. Either is honest; record the choice and the option not taken (ADR-0009
> discipline — one recorded paragraph in an existing ADR or a short new one, whichever the record
> supports).
>
> Step 1 — the mapping, smallest honest scope. A label-table value type in Core (values only —
> loading is composition's job); the display layer renders the label with the index available (e.g.
> secondary text), and the current class N becomes the EXPLICIT fallback for a missing table or
> out-of-range index. The ledger and the NDJSON export keep indices and do not change: prove it with
> a test that a fixed fixture's export is byte-identical before and after. Both engines flow through
> the same table — screen and ledger state the same fact, cross-engine.
>
> Step 2 — the screen and its fixtures. The six screenshot fixtures now show words: regenerate per
> the recorded procedure, captions and their sha move together, still labeled fabricated values.
> Tests: table length equals the model's output dimension; spot-check known indices against the
> chosen ground truth; the fallback path; the same-table-both-engines seam.
>
> Landing. Append the rung per the rung-37 precedent (next number, technical reason in the ladder
> line: the thumbs signal becomes judgeable — the loop's human surface). Full cadence per commit:
> stage → width → anchor → media-check if fixtures move → claims A1 → test-clean (counts
> re-measured, never added; CLAUDE.md and ROADMAP move together if the suite grows) → commit →
> claims A2. make land RUNG=NN at the feat HEAD, trailing docs untagged, badge derived. STOP before
> push with the bundle, gates labeled by side; git push --atomic origin main rung-NN; judgment run
> after.
>
> Standing rules: interview material never enters the tree; one commit, one concern; no
> AI-attribution trailers; verify before asserting — especially the label ordering, where memory WILL
> lie; the gate must be able to FAIL and print which way it went.
>
> Notes for whoever runs it: Step 0's first question is the rung — a wrong table is the first way this
> repo could ship a confidently false word to a user. The demo re-record is NOT this rung: it's an
> optional follow-up once labels land (the released take stays honest as "what the app showed at
> b1c8fbe").

---

## Execution notes — where reality pushed back

**1. The prompt was wrong about the ledger, and the instruction that depended on it could not be
followed as written.** "LedgerSchema/LedgerExport (indices in columns — verify, don't assume)" and
"The ledger and the NDJSON export keep indices" both assume the ledger stores indices. It does not.
`run_classifications` has a `label TEXT` column and stores whatever string the engine produced —
which for LiteRT rows was the literal text `"class 973"`. The prompt's own "verify, don't assume" is
what caught it, on the first grep.

The consequence is not cosmetic. "The export does not change" had to be re-derived rather than
inherited: what is unchanged is the export's SHAPE, and what necessarily changes is the text LiteRT
rows carry, because the ledger stores what the engine emits and invariant 3 requires the screen and
the row to state the same fact. Had the ledger kept indices and the screen shown words, the two would
have disagreed by construction. The test that landed states the surviving claim exactly — the same
record exported twice, once with indices on the value type and once without, byte-identical — rather
than the claim the prompt asked for.

**2. Both models were checked first, as instructed, and only one of them had anything.** Apple's
`.mlmodel` embeds a 1001-entry class-label vector. Google's pinned archive was re-fetched and listed:
seven members, no labels file, and the `.tflite` carries no **label** strings. The distinction is not
pedantry and the probe is what forces it: the `.tflite` does contain strings — `MobilenetV2` sits at
offset 13,964,480, a tensor/op name — while probes for `tench`, `goldfish` and `background` all
return −1. "Carries no strings" would have been a claim this rung's own evidence falsifies, which is
the kind of overstatement that is easiest to write in the sentence right after a real finding. So
"if either model carries its own table" resolved to exactly one, which settled Step 0's first
question on evidence.

**3. The ordering evidence turned out stronger than a fixture alone, and it arrived from the other
side of the comparison.** Upstream TensorFlow's `label_image` README publishes its output for a
reference image as index/label pairs. Eight of them — 458, 466, 514, 543, 611, 653, 835, 907 — were
checked against the table extracted from **Apple's** model. All eight agree. That is corroboration
from Google's side, independent of the artifact the table came from, and it was available before
running anything. The fixture test still landed, because a sample is not the whole table and because
its ground truth is what the photograph shows rather than what another project printed.

**4. The extractor's first parse was wrong in a way that looked right.** A regex over printable runs
returned 1002 "labels", several beginning with a stray character — `Sgreat white shark`,
`*electric ray`, `#brambling`. Those leading characters were protobuf length bytes that happen to be
printable ASCII (0x53 = 83, 0x2a = 42, 0x23 = 35). The real structure is `0x0a <varint> <utf8>`, and
the committed extractor parses it rather than pattern-matching text. Worth recording because the
wrong version produced a plausible-looking list of roughly the right size — exactly the failure mode
the whole rung is about.

**5. `Character` is not a byte, and a test caught it.** `LabelTable(text:)` first split on the
literal `"\n"`. Swift strings are sequences of grapheme clusters and `"\r\n"` is ONE of them, so a
CRLF file yielded labels like `"background\r\n"` — the separator never matched. The CRLF case in
`LabelTableTests` failed exactly this way, and the fix is `split(whereSeparator: \.isNewline)`. The
shipped file uses LF, so nothing user-facing was ever affected; the test was checking a robustness
claim the parser had not earned.

**6. A finding fell out that has nothing to do with labels, and it is the most interesting thing
here.** The test asserting "the model emits one probability per table row" failed with
`("1000") is not equal to ("1001")`. `CoreMLEngine` reads `classLabelProbs`, a dictionary keyed by
label; the model has 1001 output positions but 1000 distinct labels, because `"crane"` names both
index 135 (the bird) and index 518 (the machine). One class has always been silently dropped. It
could not have been noticed before this rung: it needed a count nobody had taken, over two classes
nobody could tell apart. Recorded in ROADMAP and at the code, not fixed — the repair changes how that
engine talks to Core ML.

**7. The reverse lookup had to refuse rather than guess, for the same reason.** `"crane"` means
`LabelTable.index(of:)` cannot answer for it, so it returns `nil` and the Core ML side shows that one
label with no index. Returning the first position would have put a specific, checkable, wrong number
on screen beside a correct word — a smaller version of the exact failure Step 0 was written to
prevent.

**8. The display shortens what the ledger keeps, and that is a decision, not an accident.** ImageNet
labels are synonym lists up to 121 characters; the view draws the first synonym. Drawing them whole
at this width would ellipsise mid-phrase — the horizontal-truncation failure this repo has already
recorded once. The full string is what the ledger stores, so the screen and the row name the same
class with one of them abbreviated. Stated at the code because "the screen and the ledger say the
same thing" is a rule here and this is the one place they are not character-identical.

**9. Only one screenshot changed.** Five of the six are byte-identical after regeneration, which is
itself evidence the render path is stable; `state-06-result.png` is the only view this rung touched.
Its fixture now carries indices 208, 209 and 223 — the real positions of those three labels, not
invented ones. A README picture showing a fabricated index beside a real label would be the same
confident falsehood the rung exists to prevent, and worse than in the app, because a reader cannot
re-run it.

**10. Ownership had to be corrected before the rung could be written.** ADR-0009 named the label
table "the one candidate that is real" and assigned it to the cross-model agreement rung. Declining
was right, the destination wrong: the agreement rung measures disagreement and needs a shared
vocabulary to express one in, so taking the table there would make its first task building what its
own subject presupposes. Same shape as the rung-37 correction, recorded the same way — ADR-0009's
paragraph stands, annotated.

**11. A warning about this file and the keyed claims-audit.** This rung's keyed sweep targets the
phrasing that says LiteRT names classes positionally. The blockquote above quotes the prompt
verbatim, so a keyed re-run after this file lands can match THIS document by construction. The keyed
gate's job finished, green, on the commit before this one; a red here is the quote, not a regression.
