#!/usr/bin/env bash
set -euo pipefail
version=1.44.0
digest=0e91737aee2b5baf1d255b959630194a302335d848ff97bb07921eb6205b5f5a
directory="${RUNNER_TEMP:-/tmp}/picstrip-syft"
mkdir -p "$directory"
curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/anchore/syft/releases/download/v$version/syft_${version}_linux_amd64.tar.gz" -o "$directory/tool.tar.gz"
echo "$digest  $directory/tool.tar.gz" | sha256sum -c -
tar -xzf "$directory/tool.tar.gz" -C "$directory" syft
echo "$directory" >> "$GITHUB_PATH"
