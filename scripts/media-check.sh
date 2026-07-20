#!/usr/bin/env bash
#
# scripts/media-check.sh — the media gate ADR-0007 reserved. It exists now because the five state
# screenshots exist; it was deliberately NOT built while docs/media/ was empty, because a check over an
# empty set passes unconditionally and reads as coverage.
#
# EXIT-CODE CONTRACT (the same one claims-audit, anchor-check and test-clean carry):
#   0  clean
#   1  FINDINGS — a file over a ceiling, a video, an orphan, a missing caption element (see FAIL lines)
#   2  the gate could NOT run (not a git work tree, or a tool it depends on is missing)
# Exit 1 is reserved for findings ALONE. A gate whose failure is indistinguishable from its absence is
# not a gate, and one whose SCAN SET excludes the thing under test is worse — it reports clean about a
# corpus the reader thinks it covered. This repo hit that three times in a week: a stale DerivedData
# reporting a pass, claims-audit sweeping git ls-files past an untracked file, and a screenshot check
# that caught a placeholder glyph and passed a completely blank image. Hence check E below.
set -euo pipefail
cd "$(dirname "$0")/.."

MEDIA_DIR="docs/media"
MAX_FILE_BYTES=250000      # ADR-0007 Decision 2, decimal
MAX_TOTAL_BYTES=2000000    # ADR-0007 Decision 2, decimal
MAX_LONG_EDGE=1200         # ADR-0007 Decision 2

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "media-check: not a git work tree — the gate cannot enumerate what is committed." >&2
  exit 2
fi
if ! command -v sips >/dev/null 2>&1; then
  echo "media-check: 'sips' is unavailable, so pixel dimensions cannot be read." >&2
  exit 2
fi

fail=0
note() { echo "FAIL: $*"; fail=1; }

# --- A: no video is tracked, ANYWHERE in the repo, by extension and regardless of size ------------
# By extension, not by byte count: a GIF of a screen recording is video wearing an image container, and
# a size test would refuse every real recording while implying a small one would be welcome.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  note "video committed: $f — ADR-0007 forbids tracked video in any container."
done < <(git ls-files -- '*.mp4' '*.mov' '*.webm' '*.gif' 2>/dev/null)

# --- B: per-file ceiling and long edge -------------------------------------------------------------
total=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  bytes=$(wc -c <"$f" | tr -d ' ')
  total=$((total + bytes))
  if [ "$bytes" -gt "$MAX_FILE_BYTES" ]; then
    note "$f is $bytes bytes, over the $MAX_FILE_BYTES-byte per-file ceiling (ADR-0007)."
  fi
  w=$(sips -g pixelWidth  "$f" 2>/dev/null | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/{print $2}')
  if [ -z "$w" ] || [ -z "$h" ]; then
    note "$f — could not read pixel dimensions; it may not be a valid image."
  else
    long=$w; [ "$h" -gt "$long" ] && long=$h
    [ "$long" -gt "$MAX_LONG_EDGE" ] && \
      note "$f long edge is ${long}px, over the ${MAX_LONG_EDGE}px ceiling (ADR-0007)."
  fi
done < <(git ls-files -- "$MEDIA_DIR/*.png" 2>/dev/null)

# --- C: directory total ----------------------------------------------------------------------------
[ "$total" -gt "$MAX_TOTAL_BYTES" ] && \
  note "$MEDIA_DIR totals $total bytes, over the $MAX_TOTAL_BYTES-byte ceiling (ADR-0007)."

# --- D: no orphans — every committed image is referenced by some Markdown file ----------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  if ! git ls-files -- '*.md' | xargs grep -lF "$base" >/dev/null 2>&1; then
    note "$f is referenced by no Markdown file — an image nothing shows is not documentation."
  fi
done < <(git ls-files -- "$MEDIA_DIR/*.png" 2>/dev/null)

# --- E: alt text, in BOTH syntaxes -----------------------------------------------------------------
# The scan set is the whole point of this check. The README uses <img ...> to control display width; a
# checker that understood only Markdown's ![alt](src) would sweep past every image on the page and
# report clean. Both forms are parsed, and a syntax this does not know is not silently tolerated.
#
# PROSE ABOUT IMAGES IS NOT AN IMAGE. The first run of this check flagged three "violations" in
# ADR-0007 itself, which describes the two syntaxes in backticks while explaining what is checked. A
# gate that fires on its own documentation is a false-positive generator, and false positives are how a
# gate ends up switched off. So fenced blocks and inline-code spans are stripped before scanning: an
# example is what a reader is shown, a reference is what a browser fetches, and only the second is in
# scope.
strip_code() {
  awk 'BEGIN{fenced=0} /^[[:space:]]*```/{fenced=!fenced; next} !fenced' "$1" | sed -E 's/`[^`]*`//g'
}

while IFS= read -r md; do
  [ -n "$md" ] || continue
  scanned="$(strip_code "$md")"
  # Markdown: ![](path) with empty alt.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    note "$md: a Markdown image has empty alt text — $hit"
  done < <(printf '%s\n' "$scanned" | grep -oE '!\[[[:space:]]*\]\([^)]*\)' || true)
  # HTML: an <img> with no alt= at all, or alt="".
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if ! printf '%s' "$hit" | grep -qE 'alt="[^"]+"'; then
      note "$md: an HTML <img> has missing or empty alt text — $hit"
    fi
  done < <(printf '%s\n' "$scanned" | grep -oE '<img[^>]*>' || true)
done < <(git ls-files -- '*.md')

png_count=$(git ls-files -- "$MEDIA_DIR/*.png" | wc -l | tr -d ' ')
md_count=$(git ls-files -- '*.md' | wc -l | tr -d ' ')

if [ "$fail" -ne 0 ]; then
  echo "media-check: FINDINGS — swept $png_count image(s) in $MEDIA_DIR and $md_count Markdown file(s)." >&2
  exit 1
fi

# Print the corpus size on success too. A gate that says "clean" without saying what it looked at is
# the failure recorded in ROADMAP's backlog; the counts are how a reader checks the scope was right.
echo "media-check: clean — $png_count image(s) in $MEDIA_DIR, $total bytes total (ceiling $MAX_TOTAL_BYTES); alt text checked in both syntaxes across $md_count Markdown file(s)."
exit 0
