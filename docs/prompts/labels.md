# Prompt — an index becomes a word the user can judge

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

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
> Notes for whoever runs it: Step 0's first question is the rung — a wrong table is the first way this
> repo could ship a confidently false word to a user. The demo re-record is NOT this rung: it's an
> optional follow-up once labels land (the released take stays honest as "what the app showed at
> b1c8fbe").

## What turned out wrong

The ledger and the export do not store indices at all; they store whatever text the engine emits,
which for TensorFlow Lite was `class 973`, so the premise of the byte-identical test was the
opposite of the tree. Only Apple's model carries a label table, and the first extractor read
protobuf length bytes as text. The table is derived at bootstrap from that model's own 1001-entry
vector, since published web lists have 1000 entries and the off-by-one puts a wrong word on screen.
