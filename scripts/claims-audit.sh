#!/usr/bin/env bash
#
# scripts/claims-audit.sh — the per-rung claims audit (docs/ROADMAP.md "Harness backlog").
#
# Rung 12's real cost was not the LatencyRecorder; it was tracking ONE false claim ("the
# aggregation is hand-written") across twelve sites. Three of them a working-tree `grep -r`
# can NEVER catch, and they cost most of the passes:
#   1. a claim inside a COMMIT MESSAGE (git log, not the tree)
#   2. a DEAD-SHA reference — a short sha alive LOCALLY via a backup branch, but 404 on origin
#      once a rebase orphaned it (a plain `git cat-file -e` is a FALSE NEGATIVE here: that is
#      exactly how the dead `ffebebc` reference survived the tree sweep)
#   3. stale text a REBASE resurrected after a tree sweep had already passed
#
# So this gate sweeps the working tree, the unpushed commit messages, AND dead-sha references —
# not just `grep -r`. It prints ONE clear line per finding and exits NON-ZERO on any finding, so
# `make` stops and the script drops into CI unchanged. A gate that has never failed on purpose is
# not a gate; this one is teeth-tested (a planted claim and a planted dead sha, both caught).
# Usage: `bash scripts/claims-audit.sh ['<subject regex for this rung>']`.
#
# EXIT-CODE CONTRACT — a gate whose failure is indistinguishable from its absence is not a gate:
#   0  clean
#   1  FINDINGS: a forbidden claim and/or a dead sha (the gate fired — see the FAIL lines above)
#   2  internal error the gate could not run past (e.g. no origin/main to check reachability against)
# Exit 1 is reserved for findings ALONE; any other non-zero means "could not run", never "found
# nothing". Callers (make, CI) must distinguish the two — reading the exit code alone cannot, since a
# missing make target also exits non-zero, so a fired gate is confirmed by its FAIL lines, not by $?.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root, regardless of caller's working directory

SELF="scripts/claims-audit.sh"   # excluded from the sweeps: it holds the patterns + the ffebebc example
KEYED="${1:-}"                   # optional per-rung subject-claim, swept on top of the built-in list
fail=0

# The range under audit is origin/main..HEAD — the commits we are ABOUT to push. Past commits
# cannot be rewritten in place, so scanning all of history would fail forever on a claim that was
# true when written and later corrected; only what we are (re)introducing needs re-checking.
BASE="origin/main"
if ! git rev-parse --verify -q "$BASE" >/dev/null; then
  echo "claims-audit: '$BASE' not found — fetch origin first (Check B needs origin-reachability)." >&2
  exit 2   # internal error: the gate could not run (NOT a finding)
fi
RANGE="$BASE..HEAD"

# =============================================================================================
# Check A — forbidden claims.
#
# Each built-in pattern has ZERO legitimate occurrences in the corpus (verified at authoring:
# tree AND message history). The documented RETRACTIONS use OTHER phrasings — ADR-0005's
# falsification narrative, the verbatim rung-15 prompt, and the negation in LatencyRecorder.swift
# ("This file is NOT hand-written"), plus ROADMAP's quoted "the aggregation is hand-written" — so
# any hit here is a genuine regression and needs no per-site allowlist. A pattern that matched any
# of those would fire false positives forever; that is why the article-form is deliberately absent.
FORBIDDEN_CLAIMS='
hand[ -]?written aggregation
hand[ -]?written timing
timing is hand[ -]?written
recorder is hand[ -]?written
LatencyRecorder is hand[ -]?written
hand[ -]?authored (aggregation|timing|recorder)
'
[ -n "$KEYED" ] && FORBIDDEN_CLAIMS="$FORBIDDEN_CLAIMS
$KEYED"

sweep_claim() {
  pat="$1"
  # Surface A1: the working tree (tracked files, minus this script and binaries).
  if git grep -I -n -i -E -e "$pat" -- . \
      ":!$SELF" ':!*.png' ':!*.jpg' ':!*.tflite' ':!*.mlmodel' 2>/dev/null; then
    echo "  ^^ FAIL: forbidden claim in the TREE  ->  /$pat/i" >&2
    fail=1
  fi
  # Surface A2: commit messages over the unpushed range only (see the RANGE comment above).
  if git log --format='%B' "$RANGE" 2>/dev/null | grep -I -i -q -E -e "$pat"; then
    echo "FAIL: forbidden claim in a COMMIT MESSAGE ($RANGE)  ->  /$pat/i" >&2
    git log --format='  %h %s' "$RANGE" | grep -I -i -E -e "$pat" >&2 || true
    fail=1
  fi
}

# POSIX read loop (no subshell, so `fail` survives; bash 3.2 has no mapfile).
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  sweep_claim "$pat"
done <<EOF
$FORBIDDEN_CLAIMS
EOF

# =============================================================================================
# Check B — dead-sha references, in three stages.
#
#   1. extract 7-40-char lowercase hex tokens from tracked text files AND the unpushed messages.
#   2. keep only tokens that `git cat-file -e` resolves. This drops the noise automatically and
#      needs no allowlist: dl.google.com URL path hashes, GitHub Actions run ids, dates, and
#      64-char model checksums are not git objects, so they fall out here.
#   3. FAIL any survivor that `git merge-base --is-ancestor <sha> origin/main` reports is NOT an
#      ancestor of origin. Why origin and not local existence: a local backup branch keeps an
#      orphaned commit alive, so `cat-file -e` alone passes it (the rung-12 false negative). Only
#      reachability from origin proves a reader's commit link will not 404.
extract_shas() { perl -ne 'while (/\b([0-9a-f]{7,40})\b/g){ print "$1\n" }'; }

tree_tokens="$(
  git ls-files -z -- . ":!$SELF" ':!*.png' ':!*.jpg' ':!*.tflite' ':!*.mlmodel' \
    | while IFS= read -r -d '' f; do cat "$f"; done \
    | extract_shas
)"
msg_tokens="$(git log --format='%B' "$RANGE" 2>/dev/null | extract_shas || true)"

while IFS= read -r tok; do
  [ -z "$tok" ] && continue
  git cat-file -e "$tok" 2>/dev/null || continue      # stage 2: not a git object -> noise, drop
  if ! git merge-base --is-ancestor "$tok" "$BASE" 2>/dev/null; then
    echo "FAIL: dead-sha reference '$tok' — not reachable from $BASE (origin); a reader's commit link 404s." >&2
    echo "      (it resolves locally — a backup branch keeps it alive — which is exactly the false negative this catches.)" >&2
    fail=1
  fi
done <<EOF
$(printf '%s\n%s\n' "$tree_tokens" "$msg_tokens" | sort -u)
EOF

# =============================================================================================
if [ "$fail" -ne 0 ]; then
  echo "claims-audit: FAILED — a forbidden claim or a dead sha is present (see above)." >&2
  exit 1   # findings ONLY — reserved so a caller can tell a fired gate from an absent one
fi
echo "claims-audit: clean — tree, commit messages ($RANGE), and sha references all consistent."
