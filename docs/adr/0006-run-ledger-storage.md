# ADR-0006: the run ledger — raw SQLite3, append-only by trigger, ADR-0005's concurrency pattern reused

- Status: Accepted — 2026-07-19
- Deciders: maintainer
- Implements: [`InferlensStore`](../../Sources/InferlensStore/RunLedger.swift), the `→ ledger` step
  of the product loop. Governed by CLAUDE.md invariants 2 (at most one `@unchecked Sendable`),
  3 (degradation is surfaced, never silent), 5 (no CocoaPods), and 7 (every number carries its
  device + iOS version).

## Context

The product loop is `run → ledger → signal → export → evaluate`. The ledger is the second step and
the one every later step reads. Three decisions had to be made before writing it, and each had a
plausible alternative that would have been worse for a specific, checkable reason.

## Decision 1 — raw SQLite3, not GRDB or SQLite.swift

**The iOS SDK ships SQLite as a system module.** Verified, so nobody repeats the investigation:

```
$ grep SQLite3 "$(xcrun --sdk iphonesimulator --show-sdk-path)/usr/include/module.modulemap"
extern module SQLite3 "SQLite3.modulemap"

$ cat "$(xcrun --sdk iphonesimulator --show-sdk-path)/usr/include/SQLite3.modulemap"
module SQLite3 [system] {
  header "sqlite3.h"
  export *
  ...
  link "sqlite3"
}
```

The `link "sqlite3"` directive means `import SQLite3` both compiles **and** auto-links. So the ledger
costs **zero** package dependencies: nothing was added to `Package.swift`'s dependency list, and the
only change to that file is the new test target.

A wrapper (GRDB, SQLite.swift) would buy type-safe query building and migration bookkeeping. Against
that: this repo's whole premise is that the interesting parts are the ones you can inspect. The
schema below *is* the specification — the constraints and triggers are the argument — and a wrapper
would put a DSL between a reader and the SQL they need to check. It would also be the first
non-vendored source dependency in a repo whose supply-chain story so far is "checksum-pinned or
system" (ADR-0002). The SQL here is ~120 lines of DDL and five statements; that is not a volume of
query building a DSL saves anyone from.

The cost is real and is accepted: manual `sqlite3_bind_*` indexing, and no compile-time check that a
bind index matches a column. The round-trip test is what catches that class of mistake.

## Decision 2 — append-only is enforced by TRIGGERS in the file, not by discipline in the API

Three options were on the table:

| Option | Where it holds | Verdict |
|---|---|---|
| No update/delete method on `RunLedger` | Only for callers who go through this module | Kept, but as the *second* line |
| `sqlite3_set_authorizer` denying UPDATE/DELETE | Only on connections this module opens | Rejected — same blind spot, more machinery |
| `BEFORE UPDATE` / `BEFORE DELETE` triggers that `RAISE(ABORT, …)` | In the FILE, for **every** connection | **Chosen** |

The triggers are the mechanism. They live in the database file, so an UPDATE from a future module, a
different app, or `sqlite3` on the command line is refused the same way — the statement aborts with
`SQLITE_CONSTRAINT` and its transaction rolls back. Two triggers per table, generated from one list
so a table cannot acquire one and not the other.

**Proven, not asserted.** The smoke test opens its own raw `sqlite3` connection to the ledger file —
deliberately *outside* the module — and issues an UPDATE and a DELETE, asserting the result code and
that the row is unchanged. The test was then teeth-tested the way this repo teeth-tests a gate: with
the trigger list removed from the schema, exactly those two tests fail (6 assertion failures) and the
other seven still pass. A test that can only fail when the thing it guards is removed is the standard
the other gates met.

**What this does NOT cover**, stated so nobody over-reads it: `DROP TABLE`, `ALTER TABLE`, a
migration in `LedgerSchema` (migrations run the same SQL path and are deliberately not
trigger-blocked), and anything that replaces or deletes the file on disk. Triggers protect rows
against mutation. They are not tamper-proofing, and the module does not claim to be.

## Decision 3 — concurrency reuses ADR-0005's pattern verbatim

`sqlite3*` is the same species of handle as `TfLiteInterpreter*`: a non-Sendable C pointer with no
thread-safety guarantee, held as an `OpaquePointer`, which is **trivial** — so region-based isolation
will not catch a misuse. [ADR-0005](0005-litert-engine-concurrency.md) already established what to do
about exactly this shape, so nothing was re-derived:

- `RunLedger` is an **actor**, and it serializes every access to the connection.
- Every C call is **synchronous and on-actor** — there is no `await` between reading the connection
  and the call returning. The compiler does not enforce this; the discipline is manual and is
  documented at the call sites, as `LiteRTEngine` documents its `Invoke`.
- The handle is owned by a `final class` (`SQLiteConnection`) that closes it in its **own synchronous
  `deinit`** — RAII, run by ARC at refcount zero. **Not** an `isolated deinit`: this repo already
  disproved that one by runtime crash (ADR-0005, "Cleanup"). `SQLiteStatement` gets the same
  treatment, so an early `throw` between `prepare` and `step` cannot leak a statement.
- `@unchecked Sendable` stays at **zero**. Invariant 2 permits at most one; if the store had seemed
  to need one, the design would have been wrong, not the invariant.

One consequence follows from the actor and is worth naming: the connection is opened
`SQLITE_OPEN_NOMUTEX`, switching SQLite's own serialization off. That is sound **only** because the
actor already provides it — it is a claim about this design, not a performance tweak taken on faith.

## Decision 4 — versioning by `PRAGMA user_version`, migrations appended and never edited

`user_version` is a single integer in the database header, written **inside the same transaction** as
the DDL it records, so a file is never left between two versions: either the migration and its
version bump both commit, or neither does. A `schema_migrations` audit table was considered and
dropped — it would be a second source of truth for "what version is this file," which is the bug it
would be trying to prevent.

A file whose `user_version` is *above* what the build knows is refused with
`LedgerError.schemaTooNew` rather than opened optimistically: a later version may have moved a column
this build would silently misread.

Migrations are only ever **appended**. An already-shipped migration is never edited, because a file
that has run it will not run it again and the two would diverge without saying so. The thumbs signal,
when it lands, is version 2 — a new table, appended, not a column bolted onto `runs`.

## Decision 5 — where the file lives, and how tests stay out of it

`RunLedger.Location` is an explicit enum, `.file(URL)` or `.inMemory`. The type **hardcodes no path**;
the composition root supplies one, exactly as the engines take their model URL rather than reaching
for `Vendor/Models` themselves. The app's ledger will live under Application Support (a
user-data-class location that is backed up and not purged); that composition lands with the app
target's rung, not here.

Tests never touch a real ledger path, and this is load-bearing rather than tidiness. `test-clean`
guarantees a fresh `-derivedDataPath` per run, which isolates **build products** — it does nothing
about the filesystem. A test that wrote to the app's ledger would leave state that survives into the
next run and would void exactly the isolation `test-clean` exists to provide, in a way a green result
would not reveal. So: every test uses `.inMemory`, except the two that must prove the trigger holds
for an outside connection, which use a per-test directory under `FileManager.temporaryDirectory`
named with a fresh UUID and removed in teardown.

## Typed errors — the engines' rule, applied here

No `sqlite3` result code crosses this module's boundary. `LedgerError` is the only error thrown, the
same way `InferenceError` is the only error an engine throws, and for the same reason: a caller
should be able to handle every failure without linking or understanding SQLite. The mapping happens
in `SQLite.swift`, at the call site that knows what the caller was attempting — `SQLITE_CONSTRAINT`
from an append-only trigger becomes `.appendFailed`, and `SQLITE_*` appears nowhere above that file.

`.readFailed` and `.unreadableRow` are kept distinct on purpose: the query not working and the query
working over wrong data are different bugs, and collapsing them would cost the next reader the
distinction.

## The schema, and why each column is in it

`runs` — one row per inference:

| Column | Why it is in the ledger |
|---|---|
| `id` | Append order and the ledger's own sequence. `AUTOINCREMENT` so an id is never reused. |
| `recorded_at_ms` | Wall clock, orders runs across app launches — which the monotonic id cannot. Integer, so range queries in the offline eval are ordinary SQL. |
| `device_model`, `os_version` | **Invariant 7.** `NOT NULL` *and* non-empty by `CHECK`: a row that cannot say which phone and OS produced it is a latency nobody can quote later, so the database refuses to store one. |
| `model_name`, `model_precision`, `model_input_width/height` | Which **model** ran, not just which engine — otherwise a latency change cannot be told apart from a model swap. Precision travels with it because the two benchmark models are deliberately at different native precisions (ADR-0003), the first question any latency gap raises. |
| `backend` | The engine that **actually** answered, in the contract's own wording. |
| `is_cold`, `load_ns` | The cold/warm axis the README's table is built on. Two columns, paired by `CHECK` so `load_ns` is present exactly when the run was cold — `LoadTiming`'s enum shape expressed in SQL. |
| `preprocess_ns`, `infer_ns` | The measured split. Integer nanoseconds: `Duration` is exact and a float would not be. |

`run_classifications` (`run_id`, `ordinal`, `label`, `confidence`) — the outcome, in the engine's own
descending-confidence order. A child table rather than a serialized blob, because the offline eval's
entire job is to ask questions across labels ("where did the two engines disagree on top-1"), and a
blob would make every one of those a string-parsing exercise instead of a join. The contract's
`0...1` confidence invariant is restated as a `CHECK`, where it can actually be enforced on what was
written down.

`run_degradations` (`run_id`, `ordinal`, `kind`, `from_backend`, `to_backend`) — **invariant 3**.
Degradation is surfaced and never silent, and it has to survive into the ledger, or "the run fell
back" is a UI detail that vanishes the moment the screen redraws. Structured columns rather than an
encoded string, so "how often did LiteRT fall back to Core ML" is a `WHERE` clause and not a regex.
A `CHECK` pairs the backends with the `fellBack` kind, so a fallback row can never lose the pair of
backends that is the entire content of the claim.

The ledger stores exactly the classifications it is handed and truncates **nothing**. An engine
returns the full score vector (1001 classes for MobileNetV2); picking a top-K is the caller's policy
— the UI's top-3, the eval's top-5. A silent truncation inside the ledger would make the exported
row a different claim from the run it describes.

## Consequences

- Reads are N+1 (one query for the runs, one per run for each child table). Deliberate, and scoped: a
  join over a full score vector returns the parent row once per classification and needs
  de-duplicating in Swift, and this read exists to fill a screen with a handful of runs. The export
  rung reads in bulk and will want a different query — that is its rung's problem, not a reason to
  complicate this one now.
- Bind indices are manual and unchecked by the compiler (Decision 1's accepted cost). The round-trip
  test is the guard.
- The document/KV store for model metadata and the flag cache is **not** in this module yet. It is
  its own ladder rung.
- This rung ships a **smoke** suite: migration to v1, the round trip, the trigger teeth, and the
  before-open typed error. The full migration and append-only **invariant** suite — a second
  migration applied over a v1 file, every `CHECK` exercised, concurrent appenders, WAL behaviour — is
  a separate ladder rung and lands in the same test target.
