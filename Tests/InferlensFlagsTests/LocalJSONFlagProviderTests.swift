// The spec for flag resolution, and the proof that the flag cache has a real reader.
//
// This target depends on InferlensFlags, InferlensStore AND InferlensCore. That asymmetry is
// deliberate and is the same one the conformance suite uses: the LIBRARIES never depend on each
// other — InferlensFlags cannot import InferlensStore and does not — but a TEST target may depend on
// both, which is the only place the two can be shown to fit before the app target composes them.
// `DocumentStore` satisfying `FlagCache` is written here, once, as `CachedFlagDocument`; the shipping
// adapter lands at rung 28, beside the first real flag — the app-composition rung deliberately left
// it out, because an adapter whose `isEnabled` nothing calls is the producer-less module the ladder
// already refused twice (corrected from "the app composition rung"; the rung-25 prompt's execution
// notes record the falsification). Until then this is the evidence that the seam and the store were
// built for each other rather than merely near each other.
//
// What these tests do NOT read:
//   - they do not test `DocumentStore` itself. That is `DocumentStoreTests`, in its own module's
//     suite; here it is used as a real backing store rather than mocked, so the pairing is exercised
//     against the actual implementation.
//   - they say nothing about remote config. There is no server; "the document" is whatever bytes the
//     caller supplies, which is the shape a later remote fetch will arrive in.
//   - they do not cover flag OBSERVATION or reload. `FeatureFlagProvider` has one method on purpose;
//     resolution happens once at init, and that property is asserted rather than assumed.

import Foundation
import Synchronization
import XCTest

import InferlensStore
@testable import InferlensFlags

// MARK: - The adapter under test-only ownership

/// `DocumentStore` as a `FlagCache`. This is the composition the app target will own; writing it
/// here proves rung 19's store and rung 20's seam actually meet, without either library depending on
/// the other.
///
/// It swallows storage errors, which is the `FlagCache` contract: a cache failure must never change
/// what the app does, only whether the next launch is cold.
private struct CachedFlagDocument: FlagCache {
    /// Named `documents`, not `store`, because `FlagCache` already requires a `store(_:)` method and
    /// a property of the same name reads as a call site for it.
    let documents: DocumentStore

    func load() -> Data? {
        try? documents.read(id: .flagCache)
    }

    func store(_ document: Data) {
        try? documents.write(document, id: .flagCache)
    }
}

/// A cache that records what it was asked to do, for the tests about write-through behaviour.
///
/// A `Mutex` around the mutable state, NOT `@unchecked Sendable`. CLAUDE.md invariant 2 caps the
/// whole codebase at one `@unchecked Sendable` and reserves it for the LiteRT C-handle boundary, so
/// a test double may not spend it. A final class whose only stored property is a `let Mutex` is
/// safely `Sendable` with no escape hatch — the mutex is where the synchronisation actually is,
/// rather than a promise in an annotation.
private final class RecordingCache: FlagCache, Sendable {
    private let state: Mutex<State>

    private struct State {
        var document: Data?
        var storeCallCount = 0
    }

    init(seed: Data? = nil) {
        state = Mutex(State(document: seed))
    }

    var storeCallCount: Int {
        state.withLock { $0.storeCallCount }
    }

    func load() -> Data? {
        state.withLock { $0.document }
    }

    func store(_ document: Data) {
        state.withLock {
            $0.document = document
            $0.storeCallCount += 1
        }
    }
}

// MARK: - Fixtures

private let paywall = FeatureFlag(key: "paywall", defaultValue: false)
private let onboarding = FeatureFlag(key: "onboarding", defaultValue: true)

private func json(_ raw: String) -> Data { Data(raw.utf8) }

// MARK: - Resolution order

final class LocalJSONFlagProviderTests: XCTestCase {
    func testWithNothingAtAllEveryFlagResolvesToItsOwnDefault() {
        let provider = LocalJSONFlagProvider(document: nil, cache: nil)

        // The two defaults differ, so a provider that returned a constant would fail here. That is
        // the failure this guards: "off" and "never heard of it" must not be the same answer.
        XCTAssertFalse(provider.isEnabled(paywall))
        XCTAssertTrue(provider.isEnabled(onboarding))
        XCTAssertEqual(provider.source, .defaults)
    }

    func testTheDocumentOverridesTheDefault() {
        let provider = LocalJSONFlagProvider(
            document: json(#"{"paywall": true, "onboarding": false}"#),
            cache: nil
        )

        XCTAssertTrue(provider.isEnabled(paywall))
        XCTAssertFalse(provider.isEnabled(onboarding))
        XCTAssertEqual(provider.source, .document)
    }

    func testAKeyAbsentFromTheDocumentKeepsItsDefault() {
        let provider = LocalJSONFlagProvider(document: json(#"{"paywall": true}"#), cache: nil)

        XCTAssertTrue(provider.isEnabled(paywall))
        XCTAssertTrue(provider.isEnabled(onboarding))
    }

    func testAMalformedDocumentFallsBackToTheCache() {
        let cache = RecordingCache(seed: json(#"{"paywall": true}"#))

        let provider = LocalJSONFlagProvider(document: json("this is not json {"), cache: cache)

        XCTAssertTrue(provider.isEnabled(paywall))
        XCTAssertEqual(provider.source, .cache)
    }

    func testAMalformedDocumentWithNoCacheFallsBackToDefaults() {
        let provider = LocalJSONFlagProvider(document: json("<html>nope</html>"), cache: nil)

        XCTAssertFalse(provider.isEnabled(paywall))
        XCTAssertEqual(provider.source, .defaults)
    }

    /// A JSON array parses as JSON but is not a flag document.
    func testAJsonDocumentThatIsNotAnObjectIsRejected() {
        let provider = LocalJSONFlagProvider(document: json("[1, 2, 3]"), cache: nil)

        XCTAssertEqual(provider.source, .defaults)
    }

    // MARK: - Type strictness

    /// `1` and `"true"` are not booleans. Coercing them is how a flag ends up enabled because a
    /// value was truthy, so they are dropped and the flag keeps its default.
    func testNonBooleanValuesAreDroppedRatherThanCoerced() {
        let provider = LocalJSONFlagProvider(
            document: json(#"{"paywall": 1, "onboarding": "false"}"#),
            cache: nil
        )

        XCTAssertFalse(provider.isEnabled(paywall))
        XCTAssertTrue(provider.isEnabled(onboarding))
        // The document itself parsed — it is a valid object — so this is `.document` with no usable
        // keys, not a fallback. The distinction matters: nothing was wrong with the file.
        XCTAssertEqual(provider.source, .document)
    }

    // MARK: - Write-through

    func testAParsedDocumentIsWrittenThroughToTheCache() {
        let cache = RecordingCache()
        let document = json(#"{"paywall": true}"#)

        _ = LocalJSONFlagProvider(document: document, cache: cache)

        XCTAssertEqual(cache.storeCallCount, 1)
        XCTAssertEqual(cache.load(), document)
    }

    /// A payload already known to be bad is never cached — caching it would turn one bad fetch into
    /// a permanent failure that survives every later launch.
    func testAMalformedDocumentIsNeverCached() {
        let cache = RecordingCache(seed: json(#"{"paywall": true}"#))

        _ = LocalJSONFlagProvider(document: json("garbage"), cache: cache)

        XCTAssertEqual(cache.storeCallCount, 0)
        XCTAssertEqual(cache.load(), json(#"{"paywall": true}"#))
    }

    // MARK: - Resolution happens once

    /// Two reads in one launch must agree even if the cache changes underneath. A flag that can
    /// change value mid-session is a bug that reproduces once a week and never in a test.
    func testResolutionIsFixedAtInitNotPerLookup() {
        let cache = RecordingCache(seed: json(#"{"paywall": true}"#))
        let provider = LocalJSONFlagProvider(document: nil, cache: cache)
        XCTAssertTrue(provider.isEnabled(paywall))

        cache.store(json(#"{"paywall": false}"#))

        XCTAssertTrue(provider.isEnabled(paywall))
    }
}

// MARK: - The pairing: rung 19's store as rung 20's cache

final class FlagCacheOverDocumentStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("inferlens-flags-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// The whole reason the two rungs land together: a document written on one launch answers flags
    /// on the next, with no local file present the second time.
    func testAFlagSurvivesARelaunchThroughTheDocumentStore() throws {
        let cache = CachedFlagDocument(documents: try DocumentStore(directory: directory))

        // Launch one: a local file exists, and is written through to the store.
        let first = LocalJSONFlagProvider(document: json(#"{"paywall": true}"#), cache: cache)
        XCTAssertEqual(first.source, .document)
        XCTAssertTrue(first.isEnabled(paywall))

        // Launch two: no local file at all. Without the cache this would be `.defaults` and the
        // paywall would silently switch off.
        let second = LocalJSONFlagProvider(
            document: nil,
            cache: CachedFlagDocument(documents: try DocumentStore(directory: directory))
        )

        XCTAssertEqual(second.source, .cache)
        XCTAssertTrue(second.isEnabled(paywall))
    }

    /// Deleting the cache is the documented recovery action, and it must leave the app on defaults
    /// rather than in an error state.
    func testDeletingTheCachedDocumentReturnsTheProviderToDefaults() throws {
        let store = try DocumentStore(directory: directory)
        _ = LocalJSONFlagProvider(
            document: json(#"{"paywall": true}"#),
            cache: CachedFlagDocument(documents: store)
        )

        try store.delete(id: .flagCache)

        let provider = LocalJSONFlagProvider(document: nil, cache: CachedFlagDocument(documents: store))
        XCTAssertEqual(provider.source, .defaults)
        XCTAssertFalse(provider.isEnabled(paywall))
    }
}
