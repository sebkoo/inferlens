// InferlensStore — the persistence side of the product loop's `run → ledger` step.
//
// Two stores live here, and they answer different questions:
//   - the APPEND-ONLY SQL run ledger (`RunLedger`) — one row per inference, schema versioned by
//     migration. `LedgerExport` serializes it to NDJSON, which is what the offline eval reads.
//   - the DOCUMENT store (`DocumentStore`) — schema-free JSON on disk, read whole and OVERWRITTEN
//     whole. It holds the feature-flag cache and nothing else.
//
// The split is structural, not stylistic. The ledger is append-only in the FILE, by trigger; a cache
// is overwritten on every refresh, so it cannot live in a database whose triggers refuse UPDATE
// without either failing every write or decaying the file-level guarantee into a per-table one.
// ADR-0009 also records what the document store does NOT hold: model metadata, whose facts already
// live in MODEL_PROVENANCE.md, in fetch-models.sh's checksum enforcement, and in the ledger row —
// a fourth copy with no reader is a module serving no clause of the thesis, which CLAUDE.md cuts.
//
// Dependency direction (ADR-0001): InferlensStore -> InferlensCore, plus Foundation and the
// platform's SQLite3 system module. No engine, no UI, and nothing points back the other way. The
// ledger persists Core's value types (`ModelDescriptor`, `Backend`, `LatencySample`,
// `Classification`, `DegradationReason`) — it does not invent a parallel vocabulary for them.
//
// SQLite3 is a SYSTEM module in the SDK, not a package dependency: `usr/include/module.modulemap`
// declares `extern module SQLite3`, and `SQLite3.modulemap` carries `link "sqlite3"`, so `import
// SQLite3` both compiles and auto-links with nothing added to Package.swift's dependency list
// (ADR-0006).
//
// Concurrency: `RunLedger` is an `actor` and its `sqlite3*` never leaves it — the same shape
// ADR-0005 settled for the LiteRT C handle, reused rather than re-derived. Every C call is
// synchronous and on-actor; cleanup is RAII in a small reference type's own `deinit`, never an
// `isolated deinit` (this repo disproved that one by runtime crash). The module ships **zero**
// `@unchecked Sendable` (CLAUDE.md invariant 2).
//
// Typed errors: no SQLite result code crosses this module's boundary. A `SQLITE_CONSTRAINT` from
// `sqlite3_step` becomes a `LedgerError` case, exactly as no Core ML or TFLite error crosses
// `InferenceEngine`'s `InferenceError`.
