#!/usr/bin/env bash
#
# scripts/prose-lint.sh — the writing rules in CLAUDE.md, checked instead of remembered.
#
# EXIT-CODE CONTRACT (the same one anchor-check, media-check and test-clean carry):
#   0 clean; 1 findings; 2 the check could not run (not a git work tree, or no README).
# The comment-ratio sweep (E) reports and never fails, until the source files are brought under it.
set -euo pipefail
cd "$(dirname "$0")/.."

README_MAX_LINES=150
README_MAX_BADGES=4
MAX_COMMENT_RATIO=0.30

git rev-parse --git-dir >/dev/null 2>&1 || { echo "prose-lint: not a git work tree" >&2; exit 2; }
[ -f README.md ] || { echo "prose-lint: README.md is missing" >&2; exit 2; }

fail=0
note() { echo "FAIL: $*"; fail=1; }

# Historical documents: the prompts record instructions as they were received, and ADR-0001 to
# ADR-0015 record decisions in the vocabulary of their day. Neither is rewritten to match a later
# rule, so neither is swept for vocabulary — and no length rule applies to either. A prompt is
# evidence of what was asked, so it runs as long as the instruction ran; only README has a ceiling.
is_exempt() {
  case "$1" in
    docs/prompts/*) return 0 ;;
    docs/adr/000[1-9]-*|docs/adr/001[0-5]-*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- A: README length -------------------------------------------------------------------------
lines=$(wc -l <README.md | tr -d ' ')
[ "$lines" -gt "$README_MAX_LINES" ] && \
  note "README.md is $lines lines, over the $README_MAX_LINES-line ceiling."

# --- B: badge count ---------------------------------------------------------------------------
# A badge line is a line whose whole content is an image, linked or not. Counting lines rather than
# images is deliberate: the rule is about how much of the first screen is badges.
badges=$(grep -cE '^\[?!\[[^]]*\]\(https?://[^)]*\)' README.md || true)
[ "$badges" -gt "$README_MAX_BADGES" ] && \
  note "README.md carries $badges badge lines, over the $README_MAX_BADGES-badge ceiling."

# --- C: banned words and phrases --------------------------------------------------------------
BANNED='revolutionary|seamless|blazing fast|cutting-edge|leverage|game-changing|robust|powerful|elegant|simply|effortlessly'
# Process vocabulary a reader of this repo should never have to learn.
JARGON='rung|ladder|teeth-tested|ratified|keyed claim'

# --cached --others: an untracked file is swept too, so a new doc cannot pass by not being staged.
swept=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_exempt "$f" && continue
  swept=$((swept + 1))
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    note "$f: banned word — $hit"
  done < <(grep -niE "$BANNED" "$f" | head -20 || true)
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    note "$f: process vocabulary — $hit"
  done < <(grep -niE "$JARGON" "$f" | head -20 || true)
done < <(git ls-files --cached --others --exclude-standard -- 'README.md' 'docs/*.md' 'docs/**/*.md')

# --- D: the sweep must have read something -----------------------------------------------------
if [ "$swept" -eq 0 ]; then
  echo "prose-lint: swept 0 Markdown files — the check did not run (NOT a clean result)." >&2
  exit 2
fi

# --- E: comment-to-code ratio per Swift file (reported, not fatal) -----------------------------
# Counted the blunt way: a line whose first non-space characters are // or * or /* is a comment,
# any other non-blank line is code. Doc comments count as comments, which is the intent.
over=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  read -r c k < <(awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*(\/\/|\/\*|\*)/ { c++; next }
    { k++ }
    END { print c+0, k+0 }' "$f")
  [ "$k" -eq 0 ] && continue
  if awk -v c="$c" -v k="$k" -v m="$MAX_COMMENT_RATIO" 'BEGIN { exit !(c/k > m) }'; then
    printf 'NOTE: %s comment/code ratio %.2f, over %.2f\n' "$f" "$(awk -v c="$c" -v k="$k" 'BEGIN{printf "%.4f", c/k}')" "$MAX_COMMENT_RATIO"
    over=$((over + 1))
  fi
done < <(git ls-files --cached --others --exclude-standard -- 'Sources/*.swift' 'Sources/**/*.swift')

if [ "$fail" -ne 0 ]; then
  echo "prose-lint: FINDINGS — swept $swept Markdown file(s); $over source file(s) over the comment ratio (reported only)." >&2
  exit 1
fi
echo "prose-lint: clean — README.md is $lines lines with $badges badges; $swept Markdown file(s) swept; $over source file(s) over the comment ratio (reported only)."
exit 0
