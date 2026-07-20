// InferlensApp — thin composition placeholder. The real iOS app (the SwiftUI entry point,
// module wiring, and the one MVP screen) lands with the app-composition rung. It depends on all
// modules so the dependency graph app -> {UI, Store, Flags, CoreML, LiteRT} -> Core is exercised
// and buildable now.
@main
enum InferlensApp {
    static func main() {}
}
