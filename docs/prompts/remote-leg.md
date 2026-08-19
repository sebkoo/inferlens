# Prompt — the remote leg becomes provable code

The instruction that drove the work, as received. The reading list, the landing steps and the
standing rules are cut; every paragraph kept below is complete and unaltered.

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
> Notes for whoever runs it: Step 0's option 2 is the rung's real decision — hermetic vs live-socket
> proof is a trade the maintainer should pick consciously, and the ADR should record the loser as
> carefully as the winner. If the take-away sentence for an interviewer is ever needed, it lives
> outside the tree: this rung is the repo's own roadmap executing, on its own recorded standard.

## What turned out wrong

`URLProtocol` interception never consults the request timeout, so it cannot prove the one path the
prompt most wanted proven; a loopback socket that accepts and never answers can, and that is what
the suite stands up. The new degradation cases the prompt asked for fit nothing: a timeout yields no
result, so the run fails rather than degrading, and inventing a reason with no producer would have
been a state nothing emits.
