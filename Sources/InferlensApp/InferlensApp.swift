// InferlensApp — thin composition placeholder. The real iOS app (the SwiftUI entry point,
// module wiring, and the one MVP screen) lands at rung 25. It depends on all modules so
// the dependency graph app -> {UI, Store, Flags, CoreML, LiteRT} -> Core is exercised and
// buildable now.
@main
enum InferlensApp {
    static func main() {}
}
