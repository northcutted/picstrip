#!/usr/bin/env bash
# Preserve curated locale text in a metadata archive. The first argument remains
# for compatibility; engineering release notes must not overwrite store notes.
set -euo pipefail
: "${1:?usage: render_app_store_metadata.sh <engineering-notes.md> <new-output-dir> <archive-path>}"
OUTPUT_ROOT="${2:?missing new output directory}"
ARCHIVE_PATH="${3:?missing archive path}"
python3 "$(dirname "$0")/validate_store_metadata.py"
if [[ -e "$OUTPUT_ROOT" ]]; then
  echo "Output directory already exists; choose a new directory: $OUTPUT_ROOT" >&2
  exit 1
fi
mkdir -p "$OUTPUT_ROOT/fastlane" "$(dirname "$ARCHIVE_PATH")"
cp -R fastlane/metadata "$OUTPUT_ROOT/fastlane/metadata"
tar --zstd -cf "$ARCHIVE_PATH" -C "$OUTPUT_ROOT" fastlane/metadata
