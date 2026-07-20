// The flag contract: what a flag is, who can answer for one, and where a cached answer comes from.
//
// Dependency direction (ADR-0001): InferlensFlags -> InferlensCore, and nothing else. In particular
// it does NOT import InferlensStore, even though the flag cache is a `DocumentStore` document —
// modules never depend on each other, only on Core. The cache therefore arrives through the
// `FlagCache` seam below, satisfied by whoever composes the app, which is the same shape ADR-0008
// used to get p50/p95 onto a screen that cannot compute one.

// `Data` is the one reason this file imports Foundation: the cached document is bytes, and the
// store that holds them must not know their shape (ADR-0009).

import Foundation

// MARK: - A flag

/// One feature flag: a key, and the value to use when nothing answers for it.
///
/// **The default is part of the flag, not part of the lookup.** A provider that returned `false` for
/// an unknown key would make "switched off" and "never heard of it" the same observation, and the
/// first launch of an app with an empty cache would silently disable everything. Carrying the
/// default here means a flag always has a defined value, and the only question a provider answers is
/// whether something overrides it.
public struct FeatureFlag: Sendable, Hashable {
    public let key: String
    public let defaultValue: Bool

    public init(key: String, defaultValue: Bool) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

// MARK: - Who answers

/// Anything that can resolve a flag.
///
/// Deliberately one method. A provider that also exposed "reload", "observe" or "all flags" would be
/// promising behaviour no caller needs yet, and a protocol is the most expensive place in a codebase
/// to be speculative — every future implementation pays for it.
public protocol FeatureFlagProvider: Sendable {
    /// The flag's value, or its `defaultValue` when nothing overrides it.
    func isEnabled(_ flag: FeatureFlag) -> Bool
}

// MARK: - Where a cached answer lives

/// Persistence for the flag document, as a seam rather than a dependency.
///
/// The implementation is `DocumentStore` in InferlensStore — schema-free JSON, overwritten whole,
/// which is exactly what a cache needs and exactly what the append-only ledger refuses (ADR-0009).
/// This module cannot name that type, so it names this instead and the composition connects them.
///
/// **Neither method throws, and that is a decision.** A cache is an optimisation: if reading it
/// fails the provider falls back to defaults, and if writing it fails the next launch is merely
/// cold. Propagating a storage error into flag resolution would let a disk problem change what the
/// app does, which is a much worse failure than a stale flag. Errors are the cache implementation's
/// to handle; the flag path cannot be broken by one.
public protocol FlagCache: Sendable {
    /// The last document stored, or `nil` when there is none.
    func load() -> Data?

    /// Persist a document, replacing any previous one. Failure is silent by contract — see above.
    func store(_ document: Data)
}
