// The local JSON provider — the first thing that answers a flag, and the flag cache's first reader.
//
// It resolves in one fixed order, decided here and asserted in the spec:
//
//   1. the document it was given (a local JSON file today; a remote-config payload later)
//   2. the last document the cache holds
//   3. the flag's own `defaultValue`
//
// Step 2 is why the cache exists and why it is built alongside this: a store nothing reads is a
// module serving no clause of the thesis. Step 3 is why a flag carries its default — see
// `FeatureFlag`.
//
// Resolution happens ONCE, at init, not per lookup. `isEnabled` is then a dictionary read: no file
// I/O, no parsing, no possibility that two calls in the same launch disagree because a file changed
// between them. A flag that can change value mid-session is a bug that reproduces once a week and
// never in a test.

import Foundation

public struct LocalJSONFlagProvider: FeatureFlagProvider {
    /// The resolved overrides. Only `Bool` values survive parsing — see `parse`.
    private let overrides: [String: Bool]

    /// Which source answered. Not used to resolve anything; it exists so a caller can SAY which one
    /// it is running on, the same reason `InferenceOutcome` carries the backend that actually
    /// answered rather than the one that was asked for.
    public let source: Source

    public enum Source: Sendable, Equatable {
        /// The supplied document parsed and is in use.
        case document
        /// The supplied document was absent or unparseable; the cached one is in use.
        case cache
        /// Neither answered; every flag resolves to its own default.
        case defaults
    }

    /// - Parameters:
    ///   - document: the local JSON, e.g. the contents of a bundled `flags.json`. A JSON object of
    ///     `String: Bool`. `nil` when there is no local file.
    ///   - cache: where a good document is kept between launches. `nil` disables caching entirely,
    ///     which is what a test that wants no persistence passes.
    ///
    /// A parsed document is written THROUGH to the cache, so the next launch has it even if the
    /// local file is unreadable then. A document that fails to parse is never written: caching a
    /// payload already known to be bad would poison every later launch, turning one bad fetch into a
    /// permanent failure.
    public init(document: Data?, cache: FlagCache? = nil) {
        if let document, let parsed = Self.parse(document) {
            overrides = parsed
            source = .document
            cache?.store(document)
            return
        }
        if let cached = cache?.load(), let parsed = Self.parse(cached) {
            overrides = parsed
            source = .cache
            return
        }
        overrides = [:]
        source = .defaults
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        overrides[flag.key] ?? flag.defaultValue
    }

    /// A JSON object of `String: Bool`, or `nil` if it is not one.
    ///
    /// Non-boolean values are DROPPED rather than coerced, and dropping them means the flag falls
    /// back to its default. `"paywall": 1` and `"paywall": "true"` are not booleans, and guessing
    /// what an author meant is how a flag ends up enabled in production because a string was
    /// truthy. A whole document that is not an object fails, and the next source answers.
    private static func parse(_ document: Data) -> [String: Bool]? {
        guard let object = try? JSONSerialization.jsonObject(with: document),
              let dictionary = object as? [String: Any]
        else { return nil }

        // `as? Bool` on an NSNumber-backed value would also accept 0 and 1, so the CFBoolean check
        // is what actually distinguishes `true` from `1` after JSONSerialization has boxed both.
        return dictionary.compactMapValues { value in
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else { return nil }
            return number.boolValue
        }
    }
}
