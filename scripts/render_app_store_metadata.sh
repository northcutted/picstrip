#!/usr/bin/env bash

set -euo pipefail

NOTES_SOURCE="${1:?usage: render_app_store_metadata.sh <release-notes.md> <output-dir> <archive-path>}"
OUTPUT_ROOT="${2:?usage: render_app_store_metadata.sh <release-notes.md> <output-dir> <archive-path>}"
ARCHIVE_PATH="${3:?usage: render_app_store_metadata.sh <release-notes.md> <output-dir> <archive-path>}"
METADATA_ROOT="$OUTPUT_ROOT/fastlane/metadata"

rm -rf "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT/fastlane" "$(dirname "$ARCHIVE_PATH")"
cp -R fastlane/metadata "$METADATA_ROOT"
find "$METADATA_ROOT" -name ".DS_Store" -delete

PLAIN=$(sed -E 's/^### (.+)$/\1/' "$NOTES_SOURCE" \
  | sed -E 's/^\* \*\*([^*]+):\*\* /- \1: /' \
  | sed -E 's/^\* \*\*[^*]+\*\*: /- /' \
  | sed -E 's/^\* /- /' \
  | sed -E 's/ \(\[#[0-9]+\]\([^)]+\)\)//g' \
  | sed -E 's/ \(\[?[a-f0-9]{7,}\]?\([^)]*\)\)//g' \
  | sed -E 's/ \(#[0-9]+\)//g' \
  | sed '/^[[:space:]]*$/d' \
  | head -c 4000)

locale_count=0
while IFS= read -r locale_dir; do
  printf '%s\n' "$PLAIN" > "$locale_dir/release_notes.txt"
  locale_count=$((locale_count + 1))
done < <(
  find "$METADATA_ROOT" -mindepth 1 -maxdepth 1 -type d \
    ! -name "review_information" \
    | sort
)

if [[ "$locale_count" -eq 0 ]]; then
  echo "render_app_store_metadata: no metadata locale directories found under $METADATA_ROOT" >&2
  exit 1
fi

tar --zstd -cf "$ARCHIVE_PATH" -C "$OUTPUT_ROOT" fastlane/metadata
