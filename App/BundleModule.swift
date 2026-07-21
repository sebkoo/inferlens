// App/BundleModule.swift — the one seam between the two build contexts that compile
// InferlensApp.swift (ADR-0011).
//
// The PACKAGE build (the `Inferlens-Package` scheme the suite runs) synthesizes an internal
// `Bundle.module` accessor for the executable target's `.copy("Models")` resource bundle. The
// APP-SHELL build (App/Inferlens.xcodeproj) compiles the same source file with no synthesized
// accessor — an app target's resources live in the app bundle itself, so `.main` IS the honest
// answer: the Models folder reference ships the same un-processed bytes at the same
// `Models/` subdirectory the package's `.copy` produces, and both lookups in InferlensApp.swift
// (`url(forResource:withExtension:subdirectory:)` and the `bundleURL` fallback) resolve
// identically against either bundle. This file is compiled by the shell target ONLY — it lives
// outside Sources/ precisely so the package build never sees a second `module` declaration.

import Foundation

extension Bundle {
    static var module: Bundle { .main }
}
