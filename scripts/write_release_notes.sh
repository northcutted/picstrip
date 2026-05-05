#!/usr/bin/env bash
# write_release_notes.sh
#
# Extracts the latest release section from CHANGELOG.md (written by
# @semantic-release/changelog), strips Markdown formatting, and writes
# plain-text App Store "What's New" copy to
# fastlane/metadata/en-US/release_notes.txt.
#
# Called by the @semantic-release/exec publishCmd in .releaserc.json.
# Runs on ubuntu-latest (GNU sed/awk).
#
# App Store Connect "What's New" limits:
#   • Max 4000 bytes
#   • Plain text only (no Markdown, no HTML)

set -euo pipefail

OUT="fastlane/metadata/en-US/release_notes.txt"

mkdir -p "$(dirname "$OUT")"

# ── 1. Extract the latest release block from CHANGELOG.md ─────────────────
# CHANGELOG sections start with "## [x.y.z]". Grab everything between the
# first such heading and the next one (or EOF).
NOTES=$(awk '/^## \[/{if(p)exit; p=1; next} p' CHANGELOG.md)

if [[ -z "$NOTES" ]]; then
  echo "write_release_notes: CHANGELOG.md has no release sections yet — skipping." >&2
  exit 0
fi

# ── 2. Strip Markdown formatting ──────────────────────────────────────────
PLAIN=$(printf '%s\n' "$NOTES" \
  | sed -E 's/^### (.+)$/\1/'            \
  | sed -E 's/^\* \*\*[^*]+\*\*: /• /'  \
  | sed -E 's/^\* /• /'                  \
  | sed -E 's/ \(\[#[0-9]+\]\([^)]+\)\)//g' \
  | sed -E 's/ \(\[?[a-f0-9]{7,}\]?\([^)]*\)\)//g' \
  | sed -E 's/ \(#[0-9]+\)//g'          \
  | sed '/^[[:space:]]*$/d'              \
)

# ── 3. Enforce 4000-byte App Store limit ──────────────────────────────────
PLAIN=$(printf '%s\n' "$PLAIN" | head -c 4000)

printf '%s\n' "$PLAIN" > "$OUT"

echo "write_release_notes: wrote $OUT"
cat "$OUT"
