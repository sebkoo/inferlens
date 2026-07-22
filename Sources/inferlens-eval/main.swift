// inferlens-eval — argument handling, a file read, a print, an exit code. Nothing else.
//
// EVERYTHING that can be wrong lives in InferlensEval, which is a library, which means the pinned
// simulator suite tests it under `bash scripts/test-clean.sh` like every other module. This file is
// the one part that suite cannot run — so it is the one part that holds no logic. That split is the
// whole reason the tool is a library plus a shim rather than an executable with the work inside it
// (ADR-0015, Decision 2).
//
// EXIT-CODE CONTRACT — the same three-way contract every gate in this repo carries
// (scripts/test-clean.sh, scripts/claims-audit.sh), because "recommended nothing" and "could not
// read the file" must never be indistinguishable:
//
//   0  a recommendation was made
//   1  the report was produced and the recommendation was REFUSED (insufficient evidence)
//   2  the input could not be read at all — no report exists
//
// Exit 1 is a working tool declining to answer, and the report on stdout says what would satisfy it.
// A caller that treats non-zero as failure gets a conservative answer; a caller that distinguishes
// them gets the truth.
//
// Build it by PRODUCT, never with a bare `swift build`: the package's other targets include
// InferlensLiteRT, whose vendored xcframework has no macOS slice, so a whole-package host build
// fails for a reason that has nothing to do with this tool.
//
//     swift build --product inferlens-eval
//     .build/debug/inferlens-eval path/to/exported-runs.ndjson

import Foundation
import InferlensEval

let arguments = CommandLine.arguments

guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: inferlens-eval <exported-runs.ndjson>\n".utf8))
    exit(2)
}

let path = arguments[1]

guard let ndjson = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write(Data("inferlens-eval: cannot read \(path)\n".utf8))
    exit(2)
}

do {
    let result = try LedgerEval.evaluate(ndjson: ndjson)
    print(result.rendered(), terminator: "")
    exit(result.verdict == .recommended ? 0 : 1)
} catch {
    // The refusal names the line and what was wrong with it. A file this build cannot fully read is
    // refused whole — never partially evaluated, because a report over "the rows that happened to
    // parse" is a statistic about an unknown subset.
    FileHandle.standardError.write(Data("inferlens-eval: refused \(path) — \(describe(error))\n".utf8))
    exit(2)
}

func describe(_ error: EvalError) -> String {
    switch error {
    case .noRows:
        "the file holds no rows"
    case .notJSONObject(let line):
        "line \(line) is not a single JSON object"
    case .missingKey(let line, let key):
        "line \(line) is missing the key '\(key)'"
    case .unknownKey(let line, let key):
        "line \(line) carries the unknown key '\(key)' — this build does not know how to read it"
    case .badValue(let line, let path):
        "line \(line) has a bad value at '\(path)'"
    case .loadTimingMismatch(let line, let isCold):
        isCold
            ? "line \(line) is cold but carries no 'load_ns'"
            : "line \(line) is warm but carries a 'load_ns'"
    }
}
