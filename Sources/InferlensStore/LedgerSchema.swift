// The ledger's schema and its version ladder.
//
// THE SCHEMA IS THE SPEC. Every rule the ledger claims — append-only, invariant 7, the cold/warm
// axis, confidences in 0...1 — is written here as a CONSTRAINT or a TRIGGER the database itself
// enforces, not as a comment and not as Swift-side politeness. Anything that could only be enforced
// by discipline is labelled as discipline, in plain words, below.
//
// HOW APPEND-ONLY IS ENFORCED — the mechanism, not the adjective:
//
//   1. BEFORE UPDATE and BEFORE DELETE triggers on every table `RAISE(ABORT, …)`. This is the real
//      enforcement. It lives in the FILE, so it holds for any connection that ever opens it — this
//      module, a future one, or `sqlite3` on the command line. An UPDATE or DELETE does not
//      quietly do nothing; it fails the statement and rolls back its transaction, which surfaces as
//      `LedgerError.appendFailed`.
//   2. The Swift API has no update or delete path at all — `RunLedger` exposes `append` and reads.
//      That is a second line, and on its own it would be worth little: it binds only callers who go
//      through this module.
//
//   What these do NOT stop, stated so nobody over-reads the guarantee: `DROP TABLE`, `ALTER TABLE`,
//   a migration in this file (migrations run the same SQL path and are deliberately not
//   trigger-blocked), or anything that replaces or deletes the file on disk. Triggers protect ROWS
//   against mutation, not the schema against a schema change and not the file against a filesystem.
//   Nothing here is tamper-proofing; it is an append-only DISCIPLINE that the database mechanically
//   holds callers to for the operations it can see.
//
// VERSIONING. `PRAGMA user_version` is the applied-version pointer — a single integer in the file
// header, written inside the same transaction as the migration it records, so a half-applied
// migration is impossible: either the DDL and the version bump both commit, or neither does. A
// separate `schema_migrations` audit table was considered and left out; it would duplicate the
// pointer and could disagree with it, and a second source of truth for "what version is this file"
// is the bug it would be trying to prevent.

// MARK: - Migration

/// One version step. `statements` are executed in order, inside one transaction, immediately before
/// `user_version` is set to `version`.
struct Migration: Sendable {
    let version: Int
    let statements: [String]
}

// MARK: - Schema

enum LedgerSchema {
    /// The tables the append-only triggers guard. Kept beside the migration that creates them so a
    /// new table cannot be added without a matching pair of triggers being noticed.
    static let appendOnlyTables = ["runs", "run_classifications", "run_degradations"]

    /// The highest version this build knows. A file above it is `LedgerError.schemaTooNew`.
    static var latestVersion: Int { migrations.map(\.version).max() ?? 0 }

    /// The version ladder, ascending. Migrations are only ever APPENDED — an already-shipped
    /// migration is never edited, because a file that has run it will not run it again and the two
    /// would silently diverge. The thumbs signal, when it lands, is version 2: a new table, appended
    /// here, not a column bolted onto `runs`.
    static let migrations: [Migration] = [
        Migration(version: 1, statements: version1Statements),
    ]

    private static let version1Statements: [String] = [
        // MARK: runs — one row per inference
        """
        CREATE TABLE runs (
            -- Append order, and the ledger's own sequence. AUTOINCREMENT (not bare rowid) so an id
            -- is never reused; rows are never deleted, but the intent is stated in the DDL rather
            -- than resting on that.
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,

            -- Wall clock, milliseconds since the epoch. Orders runs across app launches, which the
            -- monotonic id cannot do on its own. Stored as an integer, not a formatted string, so
            -- range queries in the offline eval are ordinary SQL.
            recorded_at_ms     INTEGER NOT NULL,

            -- CLAUDE.md invariant 7. NOT NULL and non-empty by CHECK: a row that cannot say which
            -- phone and OS produced it is a latency nobody can quote later, so the database refuses
            -- to store one rather than trusting the caller to fill it in.
            device_model       TEXT    NOT NULL,
            os_version         TEXT    NOT NULL,

            -- Which MODEL ran, not just which engine. Without this a latency change cannot be told
            -- apart from a model swap. Precision is here because the two benchmark models are
            -- deliberately at different native precisions (ADR-0003) and that is the first question
            -- any latency gap raises. Input size is what preprocessing actually resized to.
            model_name         TEXT    NOT NULL,
            model_precision    TEXT    NOT NULL,
            model_input_width  INTEGER NOT NULL,
            model_input_height INTEGER NOT NULL,

            -- The engine that ACTUALLY produced the result (the contract's own wording). Read with
            -- run_degradations, this is what makes a fallback legible after the fact — invariant 3,
            -- degradation surfaced and not silent, carried past the screen into the record.
            backend            TEXT    NOT NULL,

            -- The cold/warm axis the README's table is built on. Two columns rather than one
            -- nullable one, so the LoadTiming enum's shape survives the round trip: load_ns is
            -- present exactly when the run was cold, enforced below.
            is_cold            INTEGER NOT NULL,
            load_ns            INTEGER,

            -- The measured split. Nanoseconds as integers: Duration is exact, a float would not be,
            -- and the aggregation these feed (LatencyRecorder) reports observed values, never
            -- interpolated ones.
            preprocess_ns      INTEGER NOT NULL,
            infer_ns           INTEGER NOT NULL,

            CHECK (device_model <> '' AND os_version <> ''),
            CHECK (is_cold IN (0, 1)),
            CHECK (
                (is_cold = 1 AND load_ns IS NOT NULL AND load_ns >= 0)
                OR (is_cold = 0 AND load_ns IS NULL)
            ),
            CHECK (preprocess_ns >= 0 AND infer_ns >= 0),
            CHECK (model_input_width > 0 AND model_input_height > 0)
        )
        """,

        // MARK: run_classifications — the outcome, ordered
        //
        // A child table, not a serialized blob in `runs`. The offline eval's whole job is to ask
        // questions across labels ("where did the two engines disagree on top-1"), and a blob would
        // make every one of those a string-parsing exercise instead of a join.
        """
        CREATE TABLE run_classifications (
            run_id     INTEGER NOT NULL REFERENCES runs(id),
            -- Position in the engine's own descending-confidence order. 0 is top-1. Named `ordinal`
            -- rather than `rank`, which SQLite treats as a window function name in some contexts.
            ordinal    INTEGER NOT NULL,
            label      TEXT    NOT NULL,
            -- The contract's invariant (0...1), restated where it can actually be enforced. The
            -- conformance suite checks engines; this checks what was written down.
            confidence REAL    NOT NULL,
            PRIMARY KEY (run_id, ordinal),
            CHECK (ordinal >= 0),
            CHECK (confidence >= 0.0 AND confidence <= 1.0)
        )
        """,

        // MARK: run_degradations — invariant 3, structured
        //
        // Structured columns rather than an encoded string, for the same reason as above: "how often
        // did LiteRT fall back to Core ML" should be a WHERE clause, not a regex over a text column.
        """
        CREATE TABLE run_degradations (
            run_id       INTEGER NOT NULL REFERENCES runs(id),
            ordinal      INTEGER NOT NULL,
            kind         TEXT    NOT NULL,
            -- Populated exactly for a fallback, enforced below — so a `fellBack` row can never lose
            -- the pair of backends that is the entire content of the claim.
            from_backend TEXT,
            to_backend   TEXT,
            PRIMARY KEY (run_id, ordinal),
            CHECK (ordinal >= 0),
            CHECK (kind IN ('thermallyThrottled', 'fellBack')),
            CHECK (
                (kind = 'fellBack' AND from_backend IS NOT NULL AND to_backend IS NOT NULL)
                OR (kind <> 'fellBack' AND from_backend IS NULL AND to_backend IS NULL)
            )
        )
        """,

        // Reads are "the most recent N runs" and "the children of these runs" — the two the export
        // and the screen will make. The runs index serves the first; the children's composite
        // primary keys already serve the second.
        "CREATE INDEX runs_by_recorded_at ON runs (recorded_at_ms DESC)",
    ] + appendOnlyTriggers(for: appendOnlyTables)

    /// The append-only enforcement, generated per table so a table can never acquire one trigger and
    /// not the other. `RAISE(ABORT, …)` fails the statement and rolls back its transaction; the
    /// message names the table so a caller that hits it knows what it tried to mutate.
    private static func appendOnlyTriggers(for tables: [String]) -> [String] {
        tables.flatMap { table in
            [
                """
                CREATE TRIGGER \(table)_no_update BEFORE UPDATE ON \(table)
                BEGIN SELECT RAISE(ABORT, '\(table) is append-only: UPDATE is refused'); END
                """,
                """
                CREATE TRIGGER \(table)_no_delete BEFORE DELETE ON \(table)
                BEGIN SELECT RAISE(ABORT, '\(table) is append-only: DELETE is refused'); END
                """,
            ]
        }
    }
}
