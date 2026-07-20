// InferlensFlags — FeatureFlagProvider plus a local JSON provider, and the EntitlementProvider seam
// behind the flag system. The place a remote-config system drops into later. Depends only on
// InferlensCore.
//
// What is here:
//   FeatureFlag.swift           — a flag (key + its own default), the provider protocol, and the
//                                 `FlagCache` seam
//   LocalJSONFlagProvider.swift — resolves document -> cache -> default, once, at init
//
// The cache is a `DocumentStore` document in InferlensStore, and this module does NOT import that
// module: modules depend on Core alone. The cache arrives through the `FlagCache` seam and the app
// target connects the two — the same shape ADR-0008 used to get p50/p95 onto a screen that cannot
// compute one. ADR-0009 is why the cache is a document store rather than a ledger table.
//
// Still to come: the EntitlementProvider seam, its own ladder rung — cited by name rather than by
// number, since a rung number hand-typed outside docs/ROADMAP.md rots silently the moment the
// ladder moves, which is what this file's two previous lines had already done.
