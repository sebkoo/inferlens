// The thinnest possible layer over the C API: RAII ownership of the two resources that must be
// released, and typed-throwing helpers so no `sqlite3` result code escapes this file.
//
// This is not a query builder and is not trying to become one. It exists for two reasons only:
//
//   1. RAII. `sqlite3*` must be closed and every `sqlite3_stmt*` must be finalized, on every path
//      including the throwing ones. Both are owned by a small `final class` whose OWN synchronous
//      `deinit` releases the handle at refcount zero — the pattern ADR-0005 settled for the LiteRT
//      C handle, reused verbatim rather than re-derived. Not an `isolated deinit`: this repo already
//      disproved that one by runtime crash.
//   2. Result-code containment. Every helper takes the `LedgerError` to raise, so the mapping from
//      C to typed error happens at the call site that knows what the caller was trying to do, and
//      `SQLITE_*` never appears above this file.
//
// SAFETY (load-bearing, the same manual discipline as ADR-0005): `OpaquePointer` is a TRIVIAL
// value, so region-based isolation will not catch a handle escaping an actor — the compiler cannot
// enforce what follows. These classes are non-`Sendable`, are stored only inside `RunLedger`'s actor
// isolation, and are never passed out of it; every C call below is synchronous, with no suspension
// between reading a handle and the call returning, so the actor serializes all access to the
// connection. The connection is additionally opened `SQLITE_OPEN_NOMUTEX`, which is only sound
// BECAUSE of that serialization. Zero `@unchecked Sendable` (CLAUDE.md invariant 2).

import Foundation
import SQLite3

/// Tells SQLite to copy a bound string immediately. Required here: a Swift `String` bridged to a
/// `const char *` is only valid for the duration of the call, so `SQLITE_STATIC` would leave the
/// statement pointing at freed memory. Computed rather than a global `let` so no shared mutable-ish
/// state exists at file scope.
private var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// Owns one `sqlite3*` and closes it in its own synchronous `deinit`.
final class SQLiteConnection {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        // close_v2 rather than close: it releases the connection even if a statement somehow
        // outlived it, instead of returning SQLITE_BUSY and leaking the handle.
        sqlite3_close_v2(handle)
    }

    /// Run one or more statements with no result rows (DDL, transaction control, pragmas).
    func exec(_ sql: String, orThrow failure: LedgerError) throws(LedgerError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure }
    }

    /// Run a statement whose failure is not actionable — only `ROLLBACK` on an already-failing path,
    /// where the original error is what the caller needs and a rollback failure would mask it.
    func execIgnoringResult(_ sql: String) {
        _ = sqlite3_exec(handle, sql, nil, nil, nil)
    }

    /// Compile a statement. The returned wrapper finalizes it when it goes out of scope.
    func prepare(_ sql: String, orThrow failure: LedgerError) throws(LedgerError) -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement
        else {
            if let statement { sqlite3_finalize(statement) }
            throw failure
        }
        return SQLiteStatement(handle: prepared)
    }

    /// The row id the last successful INSERT on this connection assigned.
    var lastInsertedRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}

/// Owns one `sqlite3_stmt*` and finalizes it in its own synchronous `deinit`, so an early `throw`
/// between `prepare` and `step` cannot leak it.
final class SQLiteStatement {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    // MARK: - Bind (1-indexed, as SQLite counts parameters)

    func bind(_ value: Int64, at index: Int32, orThrow failure: LedgerError) throws(LedgerError) {
        guard sqlite3_bind_int64(handle, index, value) == SQLITE_OK else { throw failure }
    }

    func bind(_ value: Int, at index: Int32, orThrow failure: LedgerError) throws(LedgerError) {
        try bind(Int64(value), at: index, orThrow: failure)
    }

    func bind(_ value: Double, at index: Int32, orThrow failure: LedgerError) throws(LedgerError) {
        guard sqlite3_bind_double(handle, index, value) == SQLITE_OK else { throw failure }
    }

    func bind(_ value: String, at index: Int32, orThrow failure: LedgerError) throws(LedgerError) {
        guard sqlite3_bind_text(handle, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw failure
        }
    }

    /// Binds `NULL` when the value is absent — the `load_ns` column on a warm run, and the backend
    /// pair on a non-fallback degradation.
    func bind(optional value: Int64?, at index: Int32, orThrow failure: LedgerError) throws(LedgerError) {
        if let value {
            try bind(value, at: index, orThrow: failure)
        } else {
            guard sqlite3_bind_null(handle, index) == SQLITE_OK else { throw failure }
        }
    }

    func bind(optional value: String?, at index: Int32, orThrow failure: LedgerError) throws(LedgerError) {
        if let value {
            try bind(value, at: index, orThrow: failure)
        } else {
            guard sqlite3_bind_null(handle, index) == SQLITE_OK else { throw failure }
        }
    }

    // MARK: - Step

    /// Advance one row. Returns `true` when a row is available, `false` at the end of the result
    /// set. Anything else — including a `SQLITE_CONSTRAINT` from an append-only trigger — is the
    /// caller's typed error.
    @discardableResult
    func step(orThrow failure: LedgerError) throws(LedgerError) -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure
        }
    }

    // MARK: - Read (0-indexed, as SQLite counts columns)

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    /// `nil` for a `NULL` column, so a caller can tell "absent" from "empty string" — the difference
    /// between a warm run and a corrupt one.
    func text(at column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: bytes)
    }

    func optionalInt64(at column: Int32) -> Int64? {
        isNull(at: column) ? nil : int64(at: column)
    }
}
