// What the eval produces: the grouped numbers, the verdict, and the report a person reads.
//
// The structured result and the rendered text are the SAME data, not two computations — `rendered()`
// formats `self` and decides nothing. That is what lets the spec pin the arithmetic (by comparing
// `latency` against `LatencyRecorder` called directly) and the presentation (by comparing bytes)
// without either test standing in for the other.

import InferlensCore

// MARK: - The ratified threshold

/// The refusal threshold. **This is a biasable choice under CLAUDE.md invariant 1, applied offline:
/// maintainer-decided, ratified in the green commit's message, documented here at the code. No agent
/// may change it without an explicit recorded ratification.** ADR-0015, Decision 3.
///
/// A benchmark tool that recommends a backend from thin evidence is biased in exactly the way the
/// percentile definition and the cold/warm boundary can be biased — it produces a defensible-looking
/// number that the rows do not support — so the number that decides "enough" is ratified like they
/// are, rather than picked by whoever wrote the function.
///
/// **20, and the number is READ OFF the ratified percentile rather than chosen.** `LatencyRecorder`'s
/// choice (a) is nearest-rank in integer arithmetic, `rank = min(max((p * N + 99) / 100, 1), N)`.
/// For p = 95:
///
///     N = 10  ->  (950  + 99) / 100  =  10  == N     p95 IS the maximum sample
///     N = 15  ->  (1425 + 99) / 100  =  15  == N     p95 IS the maximum sample
///     N = 19  ->  (1805 + 99) / 100  =  19  == N     p95 IS the maximum sample
///     N = 20  ->  (1900 + 99) / 100  =  19  <  N     p95 is finally not the maximum
///
/// Below 20 rows the figure printed under the heading `p95` is the slowest run. A recommendation
/// made by comparing two backends' "p95" at N = 8 compares two worst cases and calls the result a
/// percentile. 20 is the smallest N at which that stops being true, so this threshold is a
/// consequence of a choice already ratified rather than a second, independent one — which is also
/// why it is pinned by a test at 19 and at 20 rather than only asserted here.
///
/// It applies to the WARM bucket. Cold rows are one-per-load by ratified choice (b), so gating the
/// verdict on cold evidence would refuse for a reason the verdict does not rest on: the
/// recommendation is about steady-state cost.
public let minimumWarmRowsPerBackend = 20

// MARK: - Result

public struct EvalResult: Sendable, Equatable {
    /// Rows parsed. Every one of them is in exactly one scope; none is filtered, dropped or sampled.
    public let rowCount: Int
    /// One per `(device, OS)` pair, ascending. Percentiles never cross a scope — invariant 7.
    public let scopes: [ScopeReport]

    public init(rowCount: Int, scopes: [ScopeReport]) {
        self.rowCount = rowCount
        self.scopes = scopes
    }

    /// Recommended when at least one scope could name a winner; refused otherwise.
    public var verdict: EvalVerdict {
        scopes.contains { if case .recommended = $0.verdict { true } else { false } }
            ? .recommended
            : .refused
    }
}

public enum EvalVerdict: Sendable, Equatable {
    case recommended
    case refused
}

/// One `(device, OS)` pair and every backend measured on it.
public struct ScopeReport: Sendable, Equatable {
    public let device: String
    public let osVersion: String
    /// Ascending by the stored backend token.
    public let backends: [BackendReport]

    public init(device: String, osVersion: String, backends: [BackendReport]) {
        self.device = device
        self.osVersion = osVersion
        self.backends = backends
    }

    /// `Simulator (iPhone18,1) · iOS 26.1` — the machine, spelled the way the rows spell it. Every
    /// number in the report sits under one of these, which is invariant 7 in the output.
    public var label: String { "\(device) · \(osVersion)" }

    /// Whether this scope can name a backend, and what stopped it if not.
    ///
    /// Eligibility is `warm.sampleCount >= minimumWarmRowsPerBackend`, and a winner needs TWO
    /// eligible backends — one eligible backend is not a comparison, it is a measurement. A tie at
    /// warm total p95 refuses rather than breaking the tie on a quantity nobody ratified.
    public var verdict: ScopeVerdict {
        let eligible = backends
            .filter { ($0.latency.warm?.sampleCount ?? 0) >= minimumWarmRowsPerBackend }
            .sorted { warmP95($0) < warmP95($1) }

        if eligible.count >= 2 {
            let winner = eligible[0]
            let runnerUp = eligible[1]
            guard warmP95(winner) != warmP95(runnerUp) else {
                return .refused(shortfalls: [
                    "\(winner.backend) and \(runnerUp.backend) tie at warm total p95",
                ])
            }
            return .recommended(backend: winner.backend, runnerUp: runnerUp.backend)
        }

        var shortfalls: [String] = []
        for report in backends {
            let n = report.latency.warm?.sampleCount ?? 0
            guard n < minimumWarmRowsPerBackend else { continue }
            let noun = n == 1 ? "warm row" : "warm rows"
            shortfalls.append("\(report.backend) has \(n) \(noun) (needs \(minimumWarmRowsPerBackend))")
        }
        if backends.count < 2 {
            shortfalls.append("fewer than two backends measured")
        }
        return .refused(shortfalls: shortfalls)
    }

    /// Sorting and tie-breaking key. A backend with no warm bucket cannot reach here — it is filtered
    /// out by the eligibility check, which a zero sample count fails.
    private func warmP95(_ report: BackendReport) -> Duration {
        report.latency.warm?.total.p95 ?? .zero
    }
}

public enum ScopeVerdict: Sendable, Equatable {
    case recommended(backend: String, runnerUp: String)
    /// Each element names one thing that is missing. The renderer joins them; nothing here is
    /// pre-formatted into a sentence, so a caller can act on the list rather than parse the prose.
    case refused(shortfalls: [String])
}

/// One backend within one scope: what it cost, and what people said about it.
public struct BackendReport: Sendable, Equatable {
    /// The stored token, verbatim. Never decoded — `LedgerEval`'s header records why.
    public let backend: String
    /// Produced by `InferlensBench.LatencyRecorder`, not by this module.
    public let latency: LatencySummary
    public let signal: SignalTally

    public init(backend: String, latency: LatencySummary, signal: SignalTally) {
        self.backend = backend
        self.latency = latency
        self.signal = signal
    }
}

/// The thumbs, counted under the schema's read rule: a run's verdict is the LAST element of its
/// `signals` array, earlier ones are the history of a person changing their mind.
///
/// `unjudged` is a first-class count rather than a subtraction the reader has to do, and it is never
/// folded into agreement: a run nobody judged is not a run somebody approved. Reported, never
/// weighed into the verdict — ADR-0015, Decision 6.
public struct SignalTally: Sendable, Equatable {
    public let up: Int
    public let down: Int
    public let unjudged: Int

    public init(up: Int, down: Int, unjudged: Int) {
        self.up = up
        self.down = down
        self.unjudged = unjudged
    }

    init(rows: [ExportedRow]) {
        var up = 0
        var down = 0
        var unjudged = 0
        for row in rows {
            switch row.currentVerdict {
            case "up": up += 1
            case "down": down += 1
            default: unjudged += 1
            }
        }
        self.init(up: up, down: down, unjudged: unjudged)
    }

    /// Runs somebody judged. Not `up + down + unjudged` — that is the run count.
    public var judged: Int { up + down }
}
