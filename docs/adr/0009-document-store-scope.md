# ADR-0009: What the document store holds — and what it does not

- Status: Accepted — 2026-07-20
- Deciders: maintainer
- Relates to: [ADR-0006](0006-run-ledger-storage.md) (the SQL run ledger),
  [ADR-0001](0001-module-boundaries.md) (module boundaries), the finding recorded against rung 19 in
  `e550986`, and CLAUDE.md's thesis test — a module serving no clause of the loop is cut.

## Context

The ladder's rung 19 reads "document/KV store for model metadata + flag cache (NoSQL)". That is two
things, and only one of them is earned. This ADR decides both halves before any store exists,
because the harder half is the one that gets built by default if nobody writes the decision down.

**The decision not to duplicate is worth as much as the store.**

## Decision 1 — the model-metadata half is DROPPED

A document store will not hold model metadata. The same facts are already recorded in three places,
each doing a job the others cannot, and a store would be a fourth copy with no reader:

| Where | What it holds | Why it is not replaceable |
|---|---|---|
| [MODEL_PROVENANCE.md](../research/MODEL_PROVENANCE.md) | which bytes, from where, at what checksum | build-time and human-readable; it is reviewed in a diff, which a database row is not |
| [`fetch-models.sh`](../../scripts/fetch-models.sh) via `make bootstrap` | the same facts, enforced | fails closed on a mismatched pin — a claim with teeth, not a record of one |
| the ledger row (`LedgerSchema`) | `model_name`, `model_precision`, `model_input_width/height` | copied per run, so a row stays self-contained when the model is swapped |

A fourth copy would have to be written by something and read by something. Nothing reads it: the
engines take a `ModelDescriptor` constructed at composition, the ledger already carries its own copy
per row, and the README's provenance claims point at the Markdown and the script. A store here would
be a module serving no clause of the thesis, which CLAUDE.md cuts.

**The one candidate that is real, and why it is still not this rung's.** `MODEL_PROVENANCE.md`
records that the raw `.tflite` carries no embedded label strings, so `LiteRTEngine` labels classes
by index while the Apple side carries real label strings. A shared ImageNet label table is a genuine
gap that none of the three fills. But the same document assigns that reconciliation to the
cross-model agreement rung, and taking it here would be claiming another rung's subject to justify
this one rather than justifying this one on its own. It is named here so the next reader does not
have to rediscover that it was considered.

## Decision 2 — the flag cache is EARNED, and it is a document store, not a ledger table

Flags must survive a launch. Nothing in the repo persists them:
[InferlensFlags](../../Sources/InferlensFlags/InferlensFlags.swift) is a three-line skeleton, and
the ledger cannot take them. That last clause is the whole argument, and it is structural rather
than stylistic.

**The ledger is append-only in the file, by trigger.** `LedgerSchema` creates
`<table>_no_update` and `<table>_no_delete` triggers that `RAISE(ABORT, …)` for **every** table it
declares, and a test opens its own connection from outside the module to prove an `UPDATE` and a
`DELETE` are refused. A flag cache is the opposite kind of value: it is **overwritten** every time
config is refetched. The two cannot share a database without one of them losing its defining
property:

- Put the cache in a guarded table and every write fails — the cache cannot function.
- Exempt the cache's table from the trigger list and the file-level guarantee decays from "this file
  is append-only" to "some tables in this file are append-only" — a property a reader can no longer
  check by opening the file, which is exactly what ADR-0006 built.
- Append every config refresh as a new row and read the newest — that turns a cache into a log,
  grows without bound, and needs a query and a sort to answer "what is the current value".

The third option is the interesting one, because it *would* work. It is rejected on cost, not
correctness: it pays migrations, a schema, and a query for a value that is one small blob read whole
and written whole.

**So: two stores, and the difference stated plainly.** They answer different questions.

| | The run ledger (SQL) | The document store |
|---|---|---|
| Lifecycle | append-only, immutable | overwritten in place |
| Shape | fixed columns, versioned migrations | schema-free JSON, no migration |
| Access | rows queried, filtered, exported | one document, read whole |
| Value if lost | the eval data — precious | a cache — refetch and continue |

The last row is the one that decides it. Deleting the document store must be a safe recovery action;
deleting the ledger destroys the loop the project exists to close. Storage that differs in whether
losing it is a catastrophe should not be one file.

### The outcome that was available and was not taken

Recording it because it was a live option, not a strawman: if the difference above could not be
articulated, the correct answer was a second SQLite table and no new store at all — deleting the
abstraction rather than adding one. It is not taken because the append-only trigger makes the
conflict a real one rather than a matter of taste.

## What this ADR does NOT decide, and does not read

- It does **not** decide the flag SCHEMA. What keys a flag document holds is the flag-provider
  rung's subject; this one decides only that a document is persisted and by what.
- It does **not** make the store general-purpose. It has exactly one client. A KV store with one
  caller is a file with extra steps, and it is justified here only by the lifecycle conflict above —
  if a second client never appears, that is not a reason to widen it.
- It does **not** survey NoSQL engines. No dependency is added; the store is files on disk holding
  JSON, which is what "document store" means at this scale. Introducing a third-party database to
  cache one document would be the vendor decision ADR-0002 spent a rung avoiding.
- It says nothing about remote config. There is no server; the provider reads local JSON, and the
  cache exists so a later remote fetch has somewhere to land.

## Consequences

- `InferlensStore` gains a second, independent store. It keeps its single dependency —
  `InferlensCore` — declared in `Package.swift`, which is what enforces it today; the CI
  dependency-lint that will fail any arrow toward an engine or back into Core is not yet built.
- The ledger's file-level append-only guarantee is untouched, which is the point of not putting the
  cache in it.
- Rung 19 ships smaller than its ladder line describes. The line stays as written — rung numbers are
  identifiers, and the ladder is not rewritten to match what a rung turned out to be — with this ADR
  as the record of what was cut and why.
