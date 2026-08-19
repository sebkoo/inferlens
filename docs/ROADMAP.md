# Roadmap

What is next, roughly in the order each depends on the one before it. Findings and follow-ups
live in [Issues](https://github.com/sebkoo/inferlens/issues).

## Device benchmark

`make bench` runs both engines on a physical iPhone and emits JSON: device, iOS, thermal state,
run count, warm-up policy. Its output fills the README's Results table, and the offline eval
wants twenty warm rows per backend before it recommends anything. [#TBD](#TBD)

## Benchmark method

`docs/BENCHMARK_METHOD.md`, written with the first numbers: what the two models share, the
warm-up policy, the run counts, and the thermal state each figure was taken at. [#TBD](#TBD)

## Observability

OSSignposter spans around load, preprocess and infer, so a slow run can be read in Instruments
rather than inferred from a p95. MetricKit diagnostics behind it. [#TBD](#TBD)

## Camera mode

Classify a live frame stream instead of one picked photo, which needs a thermal-aware frame rate
and two new states with real producers: throttled, and dropped-frame. [#TBD](#TBD)

## Retry policy for the remote leg

The remote leg fails once and the chain steps down. A bounded retry with backoff belongs there,
and it changes what a `fellBack` hop means in the ledger, so it needs a decision first. [#TBD](#TBD)

## Flags wired to the chain order

`InferlensFlags` has a provider and no caller. The first real flag is the chain's leg order, read
at composition rather than compiled in. [#TBD](#TBD)

## Cross-model agreement

Top-1 agreement between the two models over a frozen image set. Disagreement is data, and
comparing positions instead of label strings needs the class index in the ledger. [#TBD](#TBD)
