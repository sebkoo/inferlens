// The spec for the document store.
//
// The load-bearing test here is `testWritingTwiceOverwritesInPlace`. Overwriting is the operation
// the ledger refuses by trigger, and it is the entire justification ADR-0009 gives for this store
// existing beside the SQL one — so it is asserted rather than assumed. If that test were ever
// deleted, the ADR's argument would have no evidence behind it.
//
// What these tests do NOT read:
//   - they never assert atomicity under a crash. `.atomic` is a rename, and forcing a kill
//     mid-write is not something a unit test can do honestly. What IS asserted is the observable
//     consequence a rename gives you: a long document replaced by a short one leaves no trailing
//     bytes of the old one, which is what a non-atomic truncate-then-write would produce.
//   - they say nothing about the flag SCHEMA. The store holds `Data` and does not know the shape;
//     what keys a flag document carries is the flag-provider rung's subject (ADR-0009).
//   - they do not touch the ledger. The two stores share a module and nothing else, and a test that
//     opened both would imply a coupling the ADR spent its length denying.

import Foundation
import XCTest

@testable import InferlensStore

final class DocumentStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A fresh directory per test, in the system temp area — the same instinct as test-clean's
        // fresh derivedDataPath: a store that passed because of a file an earlier test left behind
        // is the reused-DerivedData defect in miniature.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("inferlens-docstore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() throws -> DocumentStore {
        try DocumentStore(directory: directory)
    }

    // MARK: - Identity

    func testAPlainNameIsAValidDocumentID() {
        XCTAssertEqual(DocumentID("flag-cache")?.rawValue, "flag-cache")
        XCTAssertEqual(DocumentID("model_meta2")?.rawValue, "model_meta2")
    }

    /// The failure the type exists to prevent: a name that escapes the store's directory. These are
    /// refused at construction, so an invalid id cannot reach the filesystem at all.
    func testPathEscapesAndOddNamesAreRefused() {
        XCTAssertNil(DocumentID("../../ledger.sqlite3"))
        XCTAssertNil(DocumentID("sub/dir"))
        XCTAssertNil(DocumentID(".."))
        XCTAssertNil(DocumentID(".hidden"))
        XCTAssertNil(DocumentID(""))
        XCTAssertNil(DocumentID("has space"))
        XCTAssertNil(DocumentID(String(repeating: "a", count: 129)))
    }

    func testTheFlagCacheIdIsAValidName() {
        // The one constant the store ships. It uses a private unchecked initializer, so this asserts
        // it would also survive the public validation — otherwise the constant could drift into
        // something `DocumentID("flag-cache")` would reject.
        XCTAssertEqual(DocumentID.flagCache.rawValue, "flag-cache")
        XCTAssertEqual(DocumentID(DocumentID.flagCache.rawValue), DocumentID.flagCache)
    }

    // MARK: - Round trip

    func testADocumentRoundTrips() throws {
        let store = try makeStore()
        let payload = Data(#"{"paywall":false}"#.utf8)

        try store.write(payload, id: .flagCache)

        XCTAssertEqual(try store.read(id: .flagCache), payload)
    }

    func testTheStoreCreatesItsDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        _ = try makeStore()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// A cold cache is the ordinary first-launch state, so it is `nil` and not a thrown error.
    func testAMissingDocumentReadsAsNilRatherThanThrowing() throws {
        let store = try makeStore()
        XCTAssertNil(try store.read(id: .flagCache))
    }

    // MARK: - Overwrite (the reason this store is not a ledger table)

    /// ADR-0009's central claim, asserted. The ledger refuses UPDATE by trigger; this store must
    /// accept it, or the flag cache has nowhere to live.
    func testWritingTwiceOverwritesInPlace() throws {
        let store = try makeStore()

        try store.write(Data(#"{"paywall":false}"#.utf8), id: .flagCache)
        try store.write(Data(#"{"paywall":true}"#.utf8), id: .flagCache)

        XCTAssertEqual(try store.read(id: .flagCache), Data(#"{"paywall":true}"#.utf8))
    }

    /// The observable consequence of an atomic replace: no remnant of the longer previous document.
    /// A truncate-then-write that failed halfway would leave the tail of the old value behind, and
    /// the result would still decode as *something* — the worst kind of corruption.
    func testAShorterDocumentLeavesNoTrailingBytesOfTheLongerOne() throws {
        let store = try makeStore()
        let long = Data(String(repeating: "x", count: 4096).utf8)
        let short = Data("y".utf8)

        try store.write(long, id: .flagCache)
        try store.write(short, id: .flagCache)

        let read = try store.read(id: .flagCache)
        XCTAssertEqual(read, short)
        XCTAssertEqual(read?.count, 1)
    }

    func testAnEmptyDocumentIsStoredAndReadBackAsEmptyNotMissing() throws {
        let store = try makeStore()
        try store.write(Data(), id: .flagCache)

        // Distinct from the missing case above: this must be an empty `Data`, not `nil`, or "the
        // cache is empty" and "there is no cache" become the same observation.
        XCTAssertEqual(try store.read(id: .flagCache), Data())
    }

    // MARK: - Delete

    func testDeleteRemovesTheDocument() throws {
        let store = try makeStore()
        try store.write(Data("{}".utf8), id: .flagCache)

        try store.delete(id: .flagCache)

        XCTAssertNil(try store.read(id: .flagCache))
    }

    /// Deleting the cache and refetching is the recovery action, so it must not need a guard around
    /// it — removing something already absent succeeds.
    func testDeletingAnAbsentDocumentSucceeds() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.delete(id: .flagCache))
    }

    // MARK: - Separation

    /// Two documents do not interfere. Thin, but it is what makes the id meaningful rather than
    /// decorative — a store that ignored the id would pass every other test in this file.
    func testDocumentsAreKeyedIndependently() throws {
        let store = try makeStore()
        let other = try XCTUnwrap(DocumentID("other"))

        try store.write(Data("first".utf8), id: .flagCache)
        try store.write(Data("second".utf8), id: other)

        XCTAssertEqual(try store.read(id: .flagCache), Data("first".utf8))
        XCTAssertEqual(try store.read(id: other), Data("second".utf8))
    }

    /// A second store over the same directory sees what the first wrote — the property that makes
    /// this a cache across launches rather than a memo for one process.
    func testAnotherStoreOverTheSameDirectorySeesTheDocument() throws {
        try makeStore().write(Data("persisted".utf8), id: .flagCache)

        let reopened = try DocumentStore(directory: directory)

        XCTAssertEqual(try reopened.read(id: .flagCache), Data("persisted".utf8))
    }
}
