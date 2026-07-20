// The document store: schema-free JSON documents on disk, read whole and written whole.
//
// This is the NoSQL half of `InferlensStore`, and it is deliberately much smaller than its ladder
// line describes. ADR-0009 dropped the model-metadata half — those facts already live in
// MODEL_PROVENANCE.md, in `fetch-models.sh`'s checksum enforcement, and in the ledger row, and a
// fourth copy would have no reader. What is left is the flag cache, which is earned because flags
// must survive a launch and nothing else here persists them.
//
// WHY THIS IS NOT A TABLE IN THE LEDGER, which is the question a reviewer should ask first. The
// ledger is append-only IN THE FILE: `LedgerSchema` creates `<table>_no_update` and
// `<table>_no_delete` triggers that `RAISE(ABORT, …)` for every table it declares, and a test proves
// it from outside the module. A cache is the opposite kind of value — it is OVERWRITTEN on every
// refresh. Storing it there would either fail every write, or force the cache's table out of the
// trigger list and decay a file-level guarantee into a per-table one that a reader can no longer
// check by opening the file. Full argument, including the option that was available and not taken
// (a second SQLite table, deleting this abstraction rather than adding it): ADR-0009.
//
// Deliberately NOT general-purpose. It has exactly one client. A KV store with one caller is a file
// with extra steps, and the only thing justifying it here is the lifecycle conflict above — so it
// stays a handful of operations over `Data` and gains nothing speculatively.
//
// `Data` rather than a `Codable` generic ON PURPOSE: schema-free means the store must not know the
// shape of what it holds. Encoding is the caller's decision, which is what lets a remote-config
// payload change without touching this file — the property the ledger buys with migrations instead.

import Foundation

// MARK: - Identity

/// The name of a document, validated at construction.
///
/// A validating type rather than a `String` parameter, because the failure it prevents is a path
/// escape: a raw `"../../ledger.sqlite3"` handed to a store rooted in the caches directory would
/// resolve to a file the store has no business touching. Checking that at each call site would be
/// four checks that must not drift; making it unrepresentable is one.
public struct DocumentID: Sendable, Equatable, Hashable {
    public let rawValue: String

    /// Fails for anything that is not a plain file name: empty, a path separator, a `..` traversal,
    /// a leading dot (hidden files), or a name long enough to trip a filesystem limit. The allowed
    /// set is deliberately narrow — letters, digits, hyphen and underscore — because widening it
    /// later is cheap and a store that has already written a surprising name is not.
    public init?(_ rawValue: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
            .union(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"))
        guard !rawValue.isEmpty,
              rawValue.count <= 128,
              rawValue.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        self.rawValue = rawValue
    }

    /// For compile-time-known names only, so a constant below does not need a force-unwrap. Private,
    /// so it cannot become a way around the validation above.
    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// The cached feature-flag document — the store's one client.
    public static let flagCache = DocumentID(unchecked: "flag-cache")
}

// MARK: - Failure

/// The only error this store throws. No `CocoaError`, no `errno` — the same rule the ledger follows
/// for SQLite result codes and the engines follow for their native errors.
public enum DocumentStoreError: Error, Sendable, Equatable {
    /// The store's directory could not be created or is not usable.
    case directoryUnavailable
    /// The document could not be written. The previous contents are intact — see `write`.
    case writeFailed
    /// The document exists but could not be read.
    case readFailed
    /// The document exists but could not be removed.
    case deleteFailed
}

// MARK: - Store

/// JSON documents in a directory, one file each.
///
/// A `struct` holding a `URL`, not an actor: every operation is a single filesystem call that
/// completes before it returns, and the type owns no mutable state to serialize. That is the
/// opposite of `RunLedger`, which is an actor precisely because it owns a live `sqlite3*` handle.
/// Concurrent writers to the same document are last-writer-wins, and the atomic replace below means
/// a reader sees one version or the other, never a mixture.
public struct DocumentStore: Sendable {
    private let directory: URL

    /// - Parameter directory: where documents live. Created if absent.
    /// - Throws: `.directoryUnavailable` when it cannot be created.
    public init(directory: URL) throws(DocumentStoreError) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw .directoryUnavailable
        }
        self.directory = directory
    }

    /// Write a document, replacing any previous version.
    ///
    /// **Atomic, and that is not a detail.** `Data.write(to:options:.atomic)` writes a temporary file
    /// and renames it into place, so a crash or a kill mid-write leaves either the old document or
    /// the new one — never a half-written file. A truncated cache is worse than an absent one: an
    /// absent cache is a cold start the caller already handles, while a corrupt one is a decode
    /// failure on a path nobody tests.
    ///
    /// Overwriting in place is the operation the ledger refuses by trigger, and the reason this store
    /// exists at all (ADR-0009).
    public func write(_ document: Data, id: DocumentID) throws(DocumentStoreError) {
        do {
            try document.write(to: url(for: id), options: .atomic)
        } catch {
            throw .writeFailed
        }
    }

    /// Read a document, or `nil` when there is none.
    ///
    /// A missing document is `nil`, NOT an error. A cold cache is the ordinary first-launch state,
    /// and making the normal path throw would push every caller into a `catch` that means "fine".
    /// A document that exists and cannot be read IS an error — that distinction is the whole reason
    /// the return type is optional rather than the error set being empty.
    public func read(id: DocumentID) throws(DocumentStoreError) -> Data? {
        let location = url(for: id)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        do {
            return try Data(contentsOf: location)
        } catch {
            throw .readFailed
        }
    }

    /// Remove a document. Removing one that is not there succeeds.
    ///
    /// Idempotent on purpose: the caller's intent is "this should not be present", and a store that
    /// threw for an already-absent document would make the recovery action — delete the cache and
    /// refetch — need a guard around it.
    public func delete(id: DocumentID) throws(DocumentStoreError) {
        let location = url(for: id)
        guard FileManager.default.fileExists(atPath: location.path) else { return }
        do {
            try FileManager.default.removeItem(at: location)
        } catch {
            throw .deleteFailed
        }
    }

    /// One file per document. The `.json` suffix is for whoever opens the directory in Finder; the
    /// store never parses it, because it does not know the shape of what it holds.
    private func url(for id: DocumentID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).json")
    }
}
