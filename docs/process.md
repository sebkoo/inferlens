# How Inferlens was built

Built with an AI coding agent working as a pair with the maintainer. The agent wrote the Swift
code, the tests, the decision records and the docs, always from a written instruction. Those
instructions are committed under `docs/prompts/` from the LiteRT engine onward, each with a note
on where it went wrong; earlier ones lived in session handoffs and were never reconstructed.

## What the maintainer decides

The maintainer decides anything that could bias a benchmark: the timing brackets, the percentile
definition, the cold and warm boundary, and the warm-up policy. As of August 2026 the maintainer
reviews every diff and makes every commit, and the agent proposes a diff and a commit message and
runs no `git commit` or `git push`. Commit messages carry no AI attribution trailers.

## The instructions, and what they got wrong

**The TensorFlow Lite engine** ([prompt](prompts/rung-15-litert-engine.md))
Build an actor over the TensorFlow Lite C API and wrap its handle in the one `@unchecked
Sendable` the codebase reserved. Probes showed an on-actor design needs zero, and an
`isolated deinit` crashed at teardown, so cleanup moved to a private class freed by ARC.

**The fallback chain** ([prompt](prompts/rung-21-fallback-chain.md))
Build the chain as a value depending on the contract alone, and disclose the load a step-down
performs as unmeasured. That load does have a home, recorded as the answering backend's cold
run. The result view already named the hop, so no view file changed.

**Cancellation** ([prompt](prompts/rung-22-cancellation.md))
Cancel the in-flight run when the input changes, and decide whether the contract should promise
`CancellationError`. It cannot, because `classify` throws a typed error, so the promise became
`InferenceError.cancelled`. One of the three checkpoint sites turned out to be imaginary.

**The signal and the export** ([prompt](prompts/rung-25-signal-and-export.md))
Add the thumbs signal, the NDJSON export, and the app composition, wiring the flag provider in
at composition time. No concrete flag existed yet, so the provider would have had no caller.
The wiring was deferred until a real flag exists, and the composition names the absence.

**Continuous integration** ([prompt](prompts/rung-31-ci.md))
Run the build and the simulator suite on a hosted runner carrying iPhone 17 Pro on iOS 26.1.
No hosted image carries both that runtime and the Swift 6.3 toolchain the package requires.
CI keeps the exact toolchain and names the simulator OS it really ran, in the job and the README.

**The app shell** ([prompt](prompts/rung-37-app-shell.md))
Commit a minimal Xcode project so the app installs and runs, then verify it on a phone. The
maintainer reduced that check to the simulator, on record. The project also needed an explicit
`PRODUCT_NAME` and a phase deleting an auto-embedded copy of the static framework.

**The label table** ([prompt](prompts/rung-38-labels.md))
Turn output indices into words, on the stated premise that the ledger and the export store
indices. They store whatever text the engine emits, which for TensorFlow Lite was `class 973`.
Only Apple's model carries a table, and the first extractor read protobuf length bytes as text.

**The remote leg** ([prompt](prompts/rung-39-remote-leg.md))
Replace the remote stub with a real `URLSession` engine and prove it with `URLProtocol`
interception. A timeout yields no result, so the new degradation cases it asked for fit nothing,
and `URLProtocol` never consults the request timeout. A loopback socket proves the timeout.

**The offline eval** ([prompt](prompts/rung-40-offline-eval.md))
Read the export, report p50 and p95 per backend, refuse to recommend below a threshold, and
refuse an unknown format version. The NDJSON carries no version field, so that check became a
required key set. Reusing `LatencyRecorder` created the first dependency between two libraries.
