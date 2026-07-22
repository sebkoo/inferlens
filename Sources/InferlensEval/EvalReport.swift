// The report a person reads. It formats `EvalResult` and decides nothing — every fact in it was
// settled before this file ran, which is why the byte-exact golden tests are a presentation spec and
// not a second copy of the arithmetic spec.
//
// NO FOUNDATION, and no `String(format:)` anywhere. Durations become milliseconds by integer
// arithmetic, the same reason `LatencyRecorder`'s ratified choice (a) is written in integers: a
// formatter is a locale away from printing `151,58 ms`, and a report whose bytes depend on the
// machine's region cannot be pinned by a golden. Column widths are computed from the content, so the
// layout is a function of the data and nothing else.

import InferlensCore

extension EvalResult {

    /// The whole report, newline-terminated.
    public func rendered() -> String {
        var lines: [String] = [
            "inferlens-eval — offline eval over the ledger export",
            "rows: \(rowCount)",
            "",
            "LATENCY",
            "p50/p95 by nearest-rank over the rows' own columns, computed by InferlensBench.LatencyRecorder.",
            "Cold totals include model load; warm totals do not.",
        ]

        for scope in scopes {
            lines.append("")
            lines.append("  \(scope.label)")
            lines.append(contentsOf: latencyTable(scope).map { "    \($0)" })
        }

        lines.append("")
        lines.append("SIGNAL")
        lines.append("Reported, not weighed. The last signal on a run is its verdict; earlier ones are history.")

        for scope in scopes {
            lines.append("")
            lines.append("  \(scope.label)")
            lines.append(contentsOf: signalTable(scope).map { "    \($0)" })
        }

        lines.append("")
        lines.append("VERDICT")
        lines.append(
            verdict == .recommended
                ? "Recommended by warm total p95, within each device and OS."
                : "No recommendation."
        )
        lines.append("")
        for scope in scopes {
            lines.append("  \(scope.label): \(sentence(for: scope))")
        }

        // The threshold appears in the OUTPUT, interpolated from the ratified constant rather than
        // typed as prose: a reader is told the rule that produced the verdict they are looking at,
        // and a change to the constant changes the report the goldens pin.
        let n = minimumWarmRowsPerBackend
        lines.append("")
        lines.append("The threshold is \(n) warm rows per backend within one device and OS. Below \(n), the")
        lines.append("nearest-rank p95 is the slowest run rather than a percentile, so a comparison would compare")
        lines.append("two worst cases. The verdict weighs latency only; the signal table above is reported and not")
        lines.append("weighed — weighing it would need a second ratified threshold.")

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The verdict, per scope

    private func sentence(for scope: ScopeReport) -> String {
        switch scope.verdict {
        case .recommended(let backend, let runnerUp):
            "\(backend), ahead of \(runnerUp)."
        case .refused(let shortfalls):
            shortfalls.isEmpty
                ? "no recommendation."
                : "no recommendation — \(shortfalls.joined(separator: "; "))."
        }
    }

    // MARK: - Tables

    private func latencyTable(_ scope: ScopeReport) -> [String] {
        var rows: [[Cell]] = [[
            Cell("backend", .left), Cell("load", .left), Cell("n", .right),
            Cell("total p50", .right), Cell("total p95", .right),
            Cell("preprocess p50", .right), Cell("preprocess p95", .right),
            Cell("infer p50", .right), Cell("infer p95", .right),
        ]]

        for report in scope.backends {
            // Cold before warm, and a bucket with no rows produces no line at all — an absent bucket
            // is absent, never a row of zeros or dashes that a reader could mistake for a measurement.
            for (name, bucket) in [("cold", report.latency.cold), ("warm", report.latency.warm)] {
                guard let bucket else { continue }
                rows.append([
                    Cell(report.backend, .left),
                    Cell(name, .left),
                    Cell("\(bucket.sampleCount)", .right),
                    Cell(milliseconds(bucket.total.p50), .right),
                    Cell(milliseconds(bucket.total.p95), .right),
                    Cell(milliseconds(bucket.preprocess.p50), .right),
                    Cell(milliseconds(bucket.preprocess.p95), .right),
                    Cell(milliseconds(bucket.infer.p50), .right),
                    Cell(milliseconds(bucket.infer.p95), .right),
                ])
            }
        }
        return render(rows)
    }

    private func signalTable(_ scope: ScopeReport) -> [String] {
        var rows: [[Cell]] = [[
            Cell("backend", .left), Cell("up", .right), Cell("down", .right), Cell("unjudged", .right),
        ]]
        for report in scope.backends {
            rows.append([
                Cell(report.backend, .left),
                Cell("\(report.signal.up)", .right),
                Cell("\(report.signal.down)", .right),
                Cell("\(report.signal.unjudged)", .right),
            ])
        }
        return render(rows)
    }
}

// MARK: - Formatting

/// Whole nanoseconds out of a `Duration`, the same decomposition `LedgerCodec` uses to put them in.
/// Arithmetic, not a policy: no rounding decision, no unit choice, nothing a benchmark could be
/// skewed by.
func nanoseconds(_ duration: Duration) -> Int64 {
    let (seconds, attoseconds) = duration.components
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
}

/// `151582667` -> `"151.58 ms"`. Rounds half-up in integer arithmetic and never touches a formatter,
/// so the bytes are the same in every locale.
func milliseconds(_ duration: Duration) -> String {
    let hundredths = (nanoseconds(duration) + 5_000) / 10_000
    let whole = hundredths / 100
    let fraction = hundredths % 100
    return "\(whole).\(fraction < 10 ? "0" : "")\(fraction) ms"
}

// MARK: - A table, aligned by content

private enum Alignment { case left, right }

private struct Cell {
    let text: String
    let alignment: Alignment

    init(_ text: String, _ alignment: Alignment) {
        self.text = text
        self.alignment = alignment
    }
}

/// Two-space separated columns, each as wide as its widest cell. Text left, numbers right. No
/// trailing whitespace on any line — a golden test compares bytes, and an invisible trailing space is
/// the kind of difference that turns a real regression into an argument about the diff.
private func render(_ rows: [[Cell]]) -> [String] {
    guard let columnCount = rows.first?.count else { return [] }
    let widths = (0 ..< columnCount).map { column in
        rows.map { $0[column].text.count }.max() ?? 0
    }
    return rows.map { row in
        row.enumerated()
            .map { index, cell in
                let padding = String(repeating: " ", count: widths[index] - cell.text.count)
                return cell.alignment == .left ? cell.text + padding : padding + cell.text
            }
            .joined(separator: "  ")
            // Only the last column can produce trailing padding, and only when it is left-aligned.
            .trimmingTrailingSpaces()
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var trimmed = self
        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
        return trimmed
    }
}
