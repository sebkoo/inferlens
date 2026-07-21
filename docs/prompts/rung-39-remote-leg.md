# Prompt — rung 39: the remote leg becomes provable code

The instruction that drove the rung, verbatim, plus honest execution notes on where reality pushed
back — the rung-15 convention: the prompt is the plan; the commits are what happened. Two of the
notes below record the prompt asking for something the tree could not give, which is the most useful
thing a document like this can preserve.

This is also where the rung's **keyed claims** retire to. The claims audited out of the tree at this
rung — that the remote leg *is a stub that always throws*, *stub-only* — survive here as the verbatim
record of what they were, exactly as the rung-38 sweep's phrasing survives in that rung's prompt doc.
A keyed re-run will match THIS file by construction; that is intended, and note 6 below states how
the sweep is read around it.

---

## The driving prompt (as received)

> Read the on-disk record FIRST. git log --oneline -8, CLAUDE.md — invariant 3 (the chain is a VALUE,
> degradation surfaced never silent), invariant 4 (a new DegradationReason is a new producer — name it
> or don't ship it), invariant 5 (no second dependency manager — system frameworks only), invariant 2
> (zero @unchecked is the shipped state; keep it). ADR-0010 top to bottom — this rung executes the
> future that document reserved: the stub was "smallest honest scope," a real endpoint was the option
> not taken, and its recorded standard is the rung's law: what the repo can PROVE without a production
> server — a local test server in the suite is provable; a hardcoded third-party URL is not. Then
> RemoteStubEngine.swift, FallbackEngine.swift (the ratified cold-rule comment), InferenceEngine.swift
> (the contract, onDemandLoad), the conformance suite, ROADMAP's ladder + claims contract + the
> rung-37/38 append precedent, and the committed prompt docs for format. The in-tree justification is
> the thesis's own clause — "choose next model/backend" is only a real choice if a remote backend
> really exists — and nothing else; external context never enters the tree.
>
> Step 0 — ADR-0013: what "real" means without a production server. Maintainer decides via the review
> loop (AskUserQuestion), options named with what each alone provides:
>
> The wire contract: what crosses the network — preprocessed tensor vs image bytes; response shape
> (top-k index/confidence pairs + a model identifier so the ledger row can name its backend
> truthfully). Decide and DOCUMENT the contract as the API's source of truth in the ADR.
> The proof vehicle: (a) URLProtocol interception — no sockets, proves the engine's contract handling
> and error paths hermetically; (b) an NWListener loopback server in the test target — real sockets,
> still zero new dependencies; (c) any third-party or external server — refused by ADR-0010's own
> standard. Name what (a) cannot prove that (b) can (real connection lifecycle, timeout behavior
> against a live socket) and pick on that.
> The unconfigured state: no shipped public URL exists, so composition without a URL must degrade
> honestly — decide whether an unconfigured RemoteEngine preserves the stub's always-throws behavior
> (the chain's degradation story unchanged for users) and say so in README/LIMITATIONS: the leg is
> real code proven against a local server; no public endpoint ships.
> Timeouts and reasons: a decided timeout value, and the new DegradationReason cases it produces —
> each with a real producer, flowing into success(degraded:) AND the ledger's existing kind/from/to
> columns with no schema change (verify, don't assume).
> The cold rule: what loadModel() means for a network leg, and whether its first run carries a load
> cost — reuse the ratified rung-12 semantics, documented at the code, no new biasable choice without
> ratification (invariant 1 discipline).
>
> Step 1 — the engine, smallest honest scope. RemoteEngine conforming to InferenceEngine,
> URLSession-based, on-actor, zero @unchecked; the conformance suite runs over it against the chosen
> proof vehicle, and over the CHAIN with the real leg in third position. Tests: the contract
> round-trip, timeout → named reason, server-error → named reason, unconfigured → honest throw,
> all-legs-fail unchanged, and the one-line composition swap still compiles both ways. The stub stays
> or goes per ADR-0013's decision — record which and why.
>
> Step 2 — the screen and the row. No new UI state (producers exist already — success(degraded:) and
> failed(retryable:) cover the new reasons); the degradation line renders the new from→to names. If
> any fixture view changes, the rung-25 regeneration procedure applies, captions and sha together.
>
> Landing. Append rung 39 per the 37/38 precedent, technical reason in the ladder line (the chain's
> third leg becomes provable code — the thesis's backend choice becomes real). Keyed claim (≥4 chars,
> quoted, retired when its quotation enters the prompt doc): always throws|remote leg is a
> stub|stub-only. Full cadence per commit: stage → width → anchor → claims A1 → test-clean (counts
> re-measured; CLAUDE.md and ROADMAP move together) → commit → A2. make land RUNG=39 at the feat HEAD,
> trailing docs untagged, badge derived. STOP before push with the bundle, gates labeled by side; git
> push --atomic origin main rung-39; judgment run after.
>
> Standing rules: interview material never enters the tree — ADR-0013's justification is
> architectural, not situational; one commit, one concern; no AI-attribution trailers; verify before
> asserting; every gate prints which way it went; prefer deleting an abstraction over adding one.
>
> Notes for whoever runs it: Step 0's option 2 is the rung's real decision — hermetic vs live-socket
> proof is a trade the maintainer should pick consciously, and the ADR should record the loser as
> carefully as the winner. If the take-away sentence for an interviewer is ever needed, it lives
> outside the tree: this rung is the repo's own roadmap executing, on its own recorded standard.

---

## Execution notes — where reality pushed back

**1. Two of the prompt's Step 0 instructions were premised on facts the tree does not hold, and
verifying beat assuming both times.** The prompt asked for "new DegradationReason cases … with no
schema change (verify, don't assume)". Verified: `run_degradations` pins its `kind` column with
`CHECK (kind IN ('thermallyThrottled', 'fellBack'))` in migration v1, and SQLite cannot `ALTER` a
CHECK — so a new reason case is a v3 table rebuild under append-only triggers, not a free addition.
Having found the cost, the better question surfaced: a timeout produces **no result**, and a
degradation is something a result carries, so the whole premise was wrong-shaped. The decision went
to zero new cases (ADR-0013, Decision 4) — the opposite of what the instruction reached for, arrived
at by following the instruction's own "verify, don't assume".

**2. The proof vehicle the prompt listed first is the one that could not prove the headline path.**
"URLProtocol interception … proves the engine's contract handling and error paths hermetically" — all
true except the error path this rung exists to add. URLProtocol replaces URLSession's loading system,
so `timeoutIntervalForRequest` is never consulted and a timeout test under it hands back the very
error it claims to observe: a fabricated proof, the same defect ADR-0010 banned as a canned success.
The loopback server was chosen for exactly the gap the prompt told the runner to name (note that the
prompt's own option 2 hint — "timeout behavior against a live socket" — is the reason). The timeout
test now waits ~0.77 s against a 0.75 s limit, and the elapsed-time assertion is what makes the wait
part of the claim rather than incidental.

**3. The prompt named the wrong API for the wrong reason, and the right one was better on the
invariant that mattered.** It said "NWListener loopback server". The classic `NWListener`/`NWConnection`
pair is not `Sendable` under Swift 6 and would have forced an `@unchecked Sendable` in the fixture —
straight at invariant 2, which the prompt itself told the runner to keep at zero. The modern
`NetworkListener<TCP>` (iOS 26) IS `Sendable` and its `run` handler is async, so the whole fixture is
actor-clean with none. The prompt's intent (a real loopback socket, no dependency) was right; the
specific type it named would have cost the thing it was trying to protect.

**4. The stub went, and the decision was forced by the stub's own words.** ADR-0010 justified
`RemoteStubEngine` as "a chain ENTRY, not a conforming engine". That is precisely what this rung
retires — `RemoteEngine` passes the conformance suite — so keeping both would leave two types meaning
one leg where one strictly generalizes the other. Deleted, per the standing rule preferring removal
to addition. `RemoteEngine(endpoint: nil)` reproduces the old behaviour byte-for-byte, which is what
let the deletion be lossless: the shipped app is unchanged for users, and no public endpoint ships.

**5. Step 2 was empty, and that is invariant 4 working rather than a corner cut.** The prompt allowed
that no new UI state was needed; checking, even the banner needed nothing —
`InferenceStateView` already renders `.remote` as "The remote fallback" and reads `.fellBack(from:to:)`
structurally. The only degradation a real remote leg produces is the hop the chain already derives
from its walk when the leg ANSWERS (`.fellBack(coreML → remote)`), and that producer predates this
rung. So the rung added a real engine and changed no pixel — the honest amount of UI work for a leg
that is nearly unreachable in the shipped composition.

**6. This file and the keyed sweep.** The rung's keyed claims are `always throws`, `remote leg is a
stub`, and `stub-only`. The blockquote above quotes the prompt verbatim, so a keyed re-run matches
THIS document by construction, and it also matches ADR-0010's `Superseded`-marked Decision 1 heading
and the retirement note in ADR-0013 that names the three claims in backticks. All three surfaces are
historical or meta — the prompt doc is the verbatim record, the ADR-0010 heading is left standing as
the superseded record with its marker, and ADR-0013's line is the act of retiring them. None is a
bare present-tense assertion that the shipped leg is stub-only, which is what the sweep exists to
catch. The keyed audit is therefore a manual-judgment gate at this rung, read the way the cross-doc
sweep spec reads a marked historical quote: leave it, and confirm the marker is there.

**7. A finding fell out that has nothing to do with the network.** Adding `RemoteEngine.preprocess`
made the `vImageScale` + RGB + normalize path exist THREE times — LiteRT, Core ML, now remote —
identical by discipline because three engines that resized differently would be a benchmark confound.
Identical-by-discipline is what drifts, and no gate compares the three. Not extracted here: a shared
seam touches two shipped engines' invariant-1 measurement brackets, which is a rung with its own
review, not a side effect of adding a leg. Recorded in ROADMAP with the standing manual step — a
change to one engine's resize is a change to all three.
