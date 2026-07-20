#!/usr/bin/env bash
#
# scripts/test-clean.sh — build + run the simulator test suite with a FRESH, unique -derivedDataPath
# every run.
#
# Why a fresh path each time: xcodebuild will happily report a STALE result out of a reused DerivedData.
# This session was bitten by that twice — a spurious "TEST SUCCEEDED" from cached DerivedData — and once
# a suite was run against an entirely different checkout than the one being judged. A per-run
# derivedDataPath under a fresh `mktemp -d` cannot be reused: the directory did not exist before this
# process, so no prior build product or test result can be consulted, and every run compiles + tests the
# CURRENT tree from scratch. The path is printed so it is visible and inspectable.
#
# WHAT IS AND IS NOT ISOLATED (a fresh -derivedDataPath is necessary, not sufficient on its own):
#   - Isolated per run, under the fresh -derivedDataPath: the build products AND the resolved
#     SourcePackages (each run resolves and builds its dependencies, never borrows them), plus the
#     module and compilation caches.
#   - Out of play by construction: SwiftPM's shared .build/ — this target invokes xcodebuild, never
#     `swift build` / `swift test`, so the CLI's .build/ is never read or written. That is why the
#     invocation below must stay xcodebuild-only; a `swift build`/`swift test` here would reintroduce the
#     shared .build/ and the premise would leak.
#   - Shared but sound: ~/Library/Caches/org.swift.swiftpm is an INPUT, not a build product — the LiteRT
#     xcframework is a checksum-pinned binaryTarget (ADR-0002), so SPM refuses it on mismatch. A shared
#     VERIFIED input and a reused UNVERIFIED build product are different things; only the second produces
#     the spurious green this target exists to prevent.
#
# EXIT-CODE CONTRACT (the same contract scripts/claims-audit.sh carries — one contract, every target):
#   0  tests ran and PASSED
#   1  tests ran and FAILED
#   2  the harness could NOT run the tests (no simulator, or the build did not reach test execution)
# "passed" and "never ran" must never be indistinguishable, so this never drifts to a default destination
# or to macOS.
#
# WHY THE EXIT MAPPING BELOW KEYS ON THE "Executed" LINE (a correction, recorded after the contract was
# observed to break). `** TEST FAILED **` is NOT a test-failure marker. Under `xcodebuild test`, a failed
# BUILD emits it too — the action that failed is the test action, whatever stopped it. So an earlier
# revision of this script, which reached for `** TEST FAILED **` alone, returned 1 (tests ran and failed)
# for a compile error the contract assigns to 2. Observed here, verbatim, from a build-failure log:
#
#     Testing failed:
#         Overlapping accesses to 'info.machine', ...
#         Testing cancelled because the build failed.
#     ** TEST FAILED **
#     The following build commands failed:
#     ...
#
# Note what is NOT in that log: no `** BUILD FAILED **` (the test action swallows it) and, crucially, no
# `Executed N tests` line. The presence of an `Executed` line is therefore the discriminator that actually
# separates the two — "did the runner reach test execution at all" — and the SUCCEEDED/FAILED marker only
# decides 0 vs 1 once that is established. Anything else is 2.
#
# Scope: the simulator suite only. Device-only paths (Neural Engine warm-up, real latency) cannot run
# here and are the on-device bench rung, not this target.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root, regardless of caller's working directory

SCHEME="Inferlens-Package"
PIN_NAME="iPhone 17 Pro"
PIN_OS="26.1"

# A fresh, unique, EMPTY derived-data dir per run. mktemp -d creates a path that did not exist before
# this process; the emptiness guard refuses to proceed on the (impossible-by-construction) chance it is
# not pristine, so a stale artifact can never be silently reused.
DD="$(mktemp -d "${TMPDIR:-/tmp}/inferlens-derived.XXXXXX")"
if [ -n "$(ls -A "$DD" 2>/dev/null)" ]; then
  echo "test-clean: derivedDataPath is not empty, refusing (a stale artifact could be reused): $DD" >&2
  exit 2
fi
echo "test-clean: fresh -derivedDataPath = $DD"

# Resolve a CONCRETE, NAMED destination (invariant 7 — a result must carry its device + iOS version, and
# two runs must not silently test different OS versions). Pin iPhone 17 Pro / 26.1; fall back to whatever
# simulator is booted only if the pin is unavailable; PRINT which was used either way. A generic
# destination is never used — it would build without running tests.
records() {
  xcrun simctl list devices available 2>/dev/null | awk '
    /^-- iOS / { rt=$0; sub(/^-- iOS /,"",rt); sub(/ --$/,"",rt); next }
    /^-- /     { rt=""; next }
    rt != "" {
      if (match($0, /[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}/)) {
        udid=substr($0, RSTART, RLENGTH)
        name=$0; sub(/ \([0-9A-Fa-f-]{36}\).*/,"",name); sub(/^ +/,"",name)
        state=($0 ~ /\(Booted\)/) ? "Booted" : "Shutdown"
        print rt "|" name "|" udid "|" state
      }
    }'
}
RECS="$(records)"

# Make a parser failure LOUD and distinct from "no simulators". BWK awk can silently match nothing if
# interval quantifiers ({8},{36}) are unsupported; a blank parse while simctl shows devices is a parser
# bug, not the environment. Either way it is exit 2 (harness could not run) — never a silent default.
if [ -z "$RECS" ]; then
  if xcrun simctl list devices available 2>/dev/null | grep -qE '\([0-9A-Fa-f-]{36}\)'; then
    echo "test-clean: the simulator PARSER returned nothing though simctl lists devices — a parser bug" >&2
    echo "           (awk interval-quantifier support?), not a missing simulator. Refusing to guess." >&2
  else
    echo "test-clean: simctl reports no available simulators." >&2
  fi
  exit 2
fi

DEST=""
if echo "$RECS" | awk -F'|' -v o="$PIN_OS" -v n="$PIN_NAME" '$1==o && $2==n {found=1} END{exit(found?0:1)}'; then
  DEST="platform=iOS Simulator,name=$PIN_NAME,OS=$PIN_OS"
  echo "test-clean: destination = pinned $PIN_NAME / iOS $PIN_OS"
else
  row="$(echo "$RECS" | awk -F'|' '$4=="Booted"{print; exit}')"
  if [ -n "$row" ]; then
    b_os="${row%%|*}"; rest="${row#*|}"; b_name="${rest%%|*}"; rest="${rest#*|}"; b_udid="${rest%%|*}"
    DEST="id=$b_udid"
    echo "test-clean: destination = booted fallback $b_name / iOS $b_os (pin $PIN_NAME/$PIN_OS unavailable)"
  fi
fi
if [ -z "$DEST" ]; then
  echo "test-clean: no simulator available (pin $PIN_NAME/$PIN_OS absent and none booted) — cannot run tests." >&2
  exit 2   # harness could not run (NOT a test failure)
fi

# Run the suite. Full output tees to the run's own log inside the fresh DerivedData; the terminal gets a
# curated summary.
set +e
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$DD/tests.xcresult" \
  2>&1 | tee "$DD/xcodebuild.log" \
       | grep -E "Test Suite .*(passed|failed)|Executed [0-9]+ test|\*\* TEST (SUCCEEDED|FAILED)|(^|[^a-zA-Z])error:" || true
set -e

echo "test-clean: -derivedDataPath was = $DD"
echo "test-clean: full log = $DD/xcodebuild.log"

# Map the AUTHORITATIVE markers to the exit-code contract (not xcodebuild's bare exit code, which cannot
# tell a test failure from a build failure). A SUCCEEDED with no "Executed" line is not a pass.
if grep -q '\*\* TEST SUCCEEDED \*\*' "$DD/xcodebuild.log" && grep -qE 'Executed [0-9]+ test' "$DD/xcodebuild.log"; then
  echo "test-clean: OK — the suite ran and passed on a fresh, never-reused derivedDataPath."
  exit 0
elif grep -q '\*\* TEST FAILED \*\*' "$DD/xcodebuild.log" \
     && grep -qE 'Executed [0-9]+ test' "$DD/xcodebuild.log"; then
  # BOTH conditions, not just the marker: a failed build also prints ** TEST FAILED **. The Executed
  # line is what proves the runner actually reached test execution, so this branch is only ever a real
  # test failure.
  echo "test-clean: FAIL — tests ran and failed (see $DD/xcodebuild.log)." >&2
  exit 1   # tests ran and failed
else
  # Everything else: the suite never ran. Name WHICH kind, because "the build broke" and "the runner
  # died before executing anything" send a reader to different places, and both are exit 2.
  if grep -q 'Testing cancelled because the build failed' "$DD/xcodebuild.log" \
     || grep -q 'The following build commands failed' "$DD/xcodebuild.log"; then
    echo "test-clean: ERROR — the BUILD failed; no test ever executed (see $DD/xcodebuild.log)." >&2
  else
    echo "test-clean: ERROR — the suite did not reach test execution (see $DD/xcodebuild.log)." >&2
  fi
  exit 2   # harness could not run (NOT a test failure)
fi
