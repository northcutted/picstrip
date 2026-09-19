#!/usr/bin/env bash
set -euo pipefail
archive="$RUNNER_TEMP/actionlint.tar.gz"
curl --fail --location --retry 3 https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz -o "$archive"
echo "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  $archive" | sha256sum --check
mkdir -p "$RUNNER_TEMP/actionlint"
tar -xzf "$archive" -C "$RUNNER_TEMP/actionlint" actionlint
echo "$RUNNER_TEMP/actionlint" >> "$GITHUB_PATH"
