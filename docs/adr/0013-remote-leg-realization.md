# ADR-0013: What "real" means for the remote leg without a production server

- Status: Accepted — 2026-07-21
- Deciders: maintainer
- Relates to: [ADR-0010](0010-remote-leg-scope.md) (the stub this rung retires, and the standard it
  set for retiring it), [ADR-0009](0009-document-store-scope.md) (the decision standard — name what
  each option alone provides, record the loser as carefully as the winner),
  [ADR-0001](0001-module-boundaries.md) (module boundaries — this rung adds the ninth name),
  [ADR-0006](0006-run-ledger-storage.md) (the ledger schema this rung does not migrate),
  CLAUDE.md invariant 1 (the ratified cold/warm boundary, applied to a leg with no model),
  invariant 2 (zero `@unchecked Sendable`), invariant 3 (the chain is a value), invariant 4 (a case
  needs a producer), invariant 5 (no second dependency manager), and the ladder's rung 39.

## Context

ADR-0010 recorded a real remote endpoint as the option **not taken**, and named exactly what would
unblock it:

> What unblocks it: a server the test suite can actually stand up — a local test server in the suite
> is provable; a hardcoded third-party URL is not, and does not qualify.

That sentence is this rung's law. Nothing else about the outside world enters the decision: the
in-tree justification is the thesis's own clause — *choose next model/backend* is only a real choice
if a remote backend really exists as code — and the standard for shipping it is what the repo can
PROVE.

Five things had to be decided before any code, and one of them was decided by a fact the repo
already held rather than by preference. They are recorded in that order.

## Decision 1 — the wire contract, and it is documented HERE as the source of truth

A preprocessed tensor goes out; top-k index/confidence pairs and a model identifier come back.

```
POST <endpoint>
Content-Type: application/octet-stream
X-Inferlens-Input: 224x224x3;float32;rgb;[-1,1];little-endian

<602112 bytes: 224*224*3 float32, row-major, RGB interleaved, normalized to [-1, 1]>

200 OK
Content-Type: application/json
{
  "model": "remote-mobilenet-v2",
  "top": [ { "index": 653, "confidence": 0.81 },
           { "index": 518, "confidence": 0.07 } ]
}
```

- **The client preprocesses.** The engine must OWN its preprocessing or there is no boundary between
  `preprocess` and `infer` to time (`InferenceEngine.classify`'s recorded constraint). Sending the
  tensor puts resize + RGB extraction + normalization inside `preprocess`, exactly where the two
  on-device engines put theirs, and leaves `infer` as the round trip ALONE — the same bracket shape
  as `TfLiteInterpreterInvoke` alone.
- **The normalization is the client's and is named on the wire.** `[-1, 1]` is the documented
  preprocessing for this float model and is what `LiteRTEngine.preprocess` already does; the header
  states it so a server cannot silently assume `[0, 1]` and return confident nonsense.
- **Indices, not labels, come back.** The index is the model's raw identity for a class; the word is
  a rendering of it (ADR-0012). The engine maps through the SAME `LabelTable` the other two legs
  use, so a fallback to remote changes the backend line and never the vocabulary.
- **The model identifier is carried and is not yet stored.** It exists so a future row can name what
  actually answered; today the composition picks the ledger's descriptor from `outcome.backend`
  (ADR-0010) and this field is read but not persisted. Named rather than implied.

**The option not taken: send image bytes, let the server preprocess.** A smaller body, and it would
have made the leg trivial. Refused because it hands a **biasable choice** — resize filter, crop,
normalization — to code this repo cannot see, review, or pin, while `preprocess` collapses to
approximately nothing and `infer` silently absorbs work the engine never measured. That is a
benchmark confound of exactly the kind BENCHMARK_METHOD.md exists to prevent, and invariant 1 puts
biasable choices under maintainer ratification at the code, which is impossible for code on another
machine.

## Decision 2 — the proof vehicle is an NWListener loopback server in the test target

Real sockets, in-process, on `127.0.0.1` with a kernel-assigned port. `Network` is a system
framework, so this adds **no dependency** — invariant 5 is untouched, and there is still exactly one
dependency manager.

**What the loser could not prove, which is why it lost.** `URLProtocol` interception is hermetic,
faster, and genuinely proves response decoding and error mapping. It cannot prove the timeout,
because it *replaces* URLSession's loading system: `timeoutIntervalForRequest` is never consulted,
so a "timeout test" under it hands back the timeout error it claims to have observed. That is a
fabricated proof of the one path this rung adds, and it is the same defect ADR-0010 refused when it
banned a canned success — a result the code did not actually produce, presented as evidence. It also
cannot exercise the connection lifecycle, which is the whole content of Decision 5's cold rule.

The loopback server serves three routes, one per path under test:

| Route | Behaviour | Proves |
|---|---|---|
| `/classify` | reads the tensor, answers the contract's JSON | the round trip, decode, label mapping, the wire contract itself |
| `/slow` | accepts the connection, never responds | a REAL timeout, against a live socket, through URLSession's own config |
| `/boom` | `500` with a body | server-error handling |

**A third-party or external server was refused without weighing**, by ADR-0010's own standard. A
hardcoded URL is not provable by the suite: it makes the test a claim about someone else's uptime.

## Decision 3 — the unconfigured state IS the old behaviour, and the stub is DELETED

`RemoteEngine(endpoint: nil)` throws `.backendUnavailable` from `loadModel()`. That is
byte-for-byte the behaviour `RemoteStubEngine` had, for the reason the stub had it: an engine that
can never infer must not let load succeed, or it lies through the contract's steady-state clause.

So the shipped app is **unchanged for users**: the chain still ends in a leg that always throws, and
the degradation story on screen and in the ledger is exactly what it was. What changed is that the
leg is now code with a proven contract behind it rather than a placeholder.

**The stub is removed rather than kept beside the engine.** Its own justification was that it was
"a chain ENTRY, not a conforming engine" (ADR-0010, Decision 1) — and that is precisely what this
rung retires: `RemoteEngine` passes the conformance suite against the loopback server. Keeping both
would leave two types meaning one leg, where one is a strict generalization of the other, and the
standing rule prefers deleting an abstraction to adding one. `ModelDescriptor.remoteStub` becomes
`.remote` with it.

**What this does NOT claim, stated on the page rather than left to inference** (README and, when it
lands, LIMITATIONS.md carry the same sentence): the remote leg is real code proven against a local
test server. **No public endpoint ships**, the app composes it unconfigured, and the repo makes no
claim about any remote service's behaviour, latency, or availability.

## Decision 4 — no new failure vocabulary; a timeout is an absence, not a degradation

Timeout, `5xx`, a transport error and a malformed body all throw the existing
`.backendUnavailable`. **No new `DegradationReason` case, no new `InferenceError` case, no schema
change.**

This was settled by a fact in the tree, not by taste. The prompt driving this rung asked for new
reasons "with no schema change (verify, don't assume)" — verified, and the premise does not hold:

> `LedgerSchema.swift` migration v1 constrains the column with
> `CHECK (kind IN ('thermallyThrottled', 'fellBack'))`. SQLite cannot `ALTER` a CHECK, so widening
> it is a v3 table rebuild — create, copy, drop, rename — against a table carrying append-only
> triggers, for a leg that answers almost never.

Having found that, the shape question is the better one, and it answers itself: **a timeout produces
no result, and degradation is something a result carries.** `InferenceOutcome.degradations` only
exists on an outcome; a leg that times out returns none, the chain's last-error rule throws, and the
UI maps it onto `failed(retryable: true)` through a producer that already exists. The degradation
that a real remote leg produces is the one the chain already derives from its walk —
`.fellBack(from: .coreML, to: .remote)`, on the run where remote actually ANSWERS — and
`InferenceStateView` already renders `.remote` as "The remote fallback". So invariant 4 is satisfied
by producers that exist, and ADR-0010's "no new `DegradationReason` case" survives this rung intact
rather than being overturned by it.

The cost, named: a timeout and a `500` are indistinguishable in the record. `InferenceError` carries
no payload, and a failed walk writes no row, so there is nowhere for the distinction to live. That
is the same last-error cost ADR-0010 already accepted, and it is accepted again here rather than
paid for with a migration.

**The timeout value is 10 seconds** (`timeoutIntervalForRequest`), documented at the code. Chosen
because the remote leg is consulted only after both on-device engines have already failed — the user
has been waiting through two failures — and a leg that hangs is worse for them than a leg that
fails, since failing is what surfaces the retry the error's `isRetryable` promises. This is a
product choice, not a biasable measurement choice: it does not touch the percentile definition, the
cold/warm boundary, or the warm-up policy, so it is documented rather than ratified.

## Decision 5 — the cold rule for a leg with no model, ratified under invariant 1

`loadModel()` validates that an endpoint is configured and returns. It makes **no** network call.

- **Rung 12's boundary is reused verbatim, not extended**: cold is the first run after a load, its
  `total` carrying the load cost. For this leg the load cost is approximately zero, which is
  honest — there is no model to read, no graph to build, no accelerator to warm.
- **Connection setup lands inside `infer`**, because that is where it happens: `infer` brackets the
  round trip alone, and on the first request that round trip includes establishing the connection.
  It is not hidden and it is not moved.
- A step-down onto this leg is still recorded as remote's COLD run through
  `InferenceOutcome.onDemandLoad`, unchanged from ADR-0010 Decision 2. The chain's bracket does not
  know or care that the load it measured was cheap.

**The option not taken: a preflight request inside `loadModel()`**, warming the connection so run 1
matches run 2. Rejected because it would invent a SECOND meaning for `load_ns` — handshake time
beside model-load time, in the same column, distinguishable only by which backend the row names —
and that is a new biasable choice, which invariant 1 forbids introducing without its own recorded
ratification. It would also make a nearly-unreachable leg emit traffic on every chain load.

The conformance suite's steady-state check applies unchanged and is not relaxed for this engine: run
1's compute may not exceed 4× run 2's. Against the loopback server it passes with the connection
setup inside run 1, which is the empirical claim this decision rests on rather than an assumption
about it.

## Decision 6 — a new module, `InferlensRemote`

The engine lands beside `InferlensCoreML` and `InferlensLiteRT`, not inside `InferlensFallback`
where the stub lived. ADR-0001's module diagram gains its ninth name (the 6 → 7 precedent at rung
12, 7 → 8 at rung 21).

The stub was in the composition module because it was not an engine. A conforming engine belongs
where engines are, and the move restores a claim `InferlensFallback` makes about itself: that module
now holds the chain and nothing else, depends on `InferlensCore` alone, and names no concrete engine
anywhere — including in its tests, where the chain's remote-leg fixture becomes the in-file
failing-on-cue fake it already had.

Dependency direction is unchanged and one way: `InferlensRemote → InferlensCore` plus Foundation.
The test target adds `InferlensConformance` and `InferlensFallback`, the same asymmetry the engine
test targets already have — the suite lands in a test, never in the shipped engine.

## Concurrency — invariant 2 holds at zero

`RemoteEngine` is an actor holding a `URLSession` (a `Sendable` reference) and value configuration.
There is no C handle, no non-Sendable state crossing a boundary, and no `deinit` obligation, so
there is nothing here that could want an `@unchecked Sendable`. The count stays **zero**, and the
CI lint's ceiling of at most one is untouched.

## What this ADR does NOT decide

- **No server ships, and none is written beyond the test fixture.** The loopback server is test
  support and lives in the test target; it is not a product, not a reference implementation, and not
  deployed anywhere.
- **No authentication, no retries, no backoff, no streaming.** Each would need its own producer and
  its own rung. Streaming in particular remains refused by ADR-0010's reasoning, unchanged.
- **No ledger schema change**, and no new column for the response's model identifier — see Decision
  4 for the constraint and Decision 1 for the deferral.
- **No UI change.** The banner already names `.remote`, and no state case is added (invariant 4).
- It does not re-open the conformance suite's invariants. The new engine is run through them as one
  more engine, unchanged, and so is the chain with it in third position.

## Consequences

- The thesis's *choose next model/backend* clause becomes a real choice: swapping the chain's third
  leg for a configured endpoint is an argument at one composition line, against a contract this
  repo documents and a suite this repo runs.
- ADR-0010's "outcome not taken" is now taken, on the standard ADR-0010 itself set. That ADR is
  annotated rather than rewritten — Decision 1 stands as the record of what was true until this
  rung, which is the disposition this repo uses for every superseded claim.
- The keyed claims `always throws`, `remote leg is a stub` and `stub-only` are retired from the tree
  and swept for, since each was true before this rung and is false after it in every place it
  appeared.
