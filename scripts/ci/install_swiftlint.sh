#!/usr/bin/env bash
set -euo pipefail
version=0.63.2
digest=c59a405c85f95b92ced677a500804e081596a4cae4a6a485af76065557d6ed29
directory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/picstrip-swiftlint"
mkdir -p "$directory"
curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/realm/SwiftLint/releases/download/$version/portable_swiftlint.zip" -o "$directory/tool.zip"
echo "$digest  $directory/tool.zip" | shasum -a 256 -c -
unzip -oq "$directory/tool.zip" -d "$directory"
echo "$directory" >> "$GITHUB_PATH"
