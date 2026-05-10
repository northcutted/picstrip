#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

patterns=(
  'errorMessage = "[^"]+'
  'showErrorThenCancel\("[^"]+'
  'NSLocalizedDescriptionKey: "[^"]+'
)

status=0
for pattern in "${patterns[@]}"; do
  if rg -n "$pattern" PicStripCore PicStripShareExtension --glob '*.swift'; then
    status=1
  fi
done

return_patterns=(
  'var (title|description|label|errorDescription): String'
  'LocalizedError'
)

for pattern in "${return_patterns[@]}"; do
  files=$(rg -l "$pattern" PicStripCore PicStripShareExtension --glob '*.swift' || true)
  if [ -n "$files" ] && rg -n 'return "[^"\\][^"]+"' $files; then
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "Found string-returning user-facing literals outside localization helpers."
  echo "Use String(localized:) or LocalizedStringResource where appropriate."
  exit "$status"
fi

echo "Localization string audit passed."
