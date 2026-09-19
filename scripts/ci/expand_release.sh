#!/usr/bin/env bash
set -euo pipefail
directory="${1:?release directory required}"
mkdir -p build/verified-archives
zstd -d "$directory/app-store-metadata.tar.zst" -o build/verified-archives/metadata.tar -f
zstd -d "$directory/app-store-screenshots.tar.zst" -o build/verified-archives/screenshots.tar -f
python3 scripts/ci/evidence.py extract build/verified-archives/metadata.tar --output . --prefix fastlane/metadata
python3 scripts/ci/evidence.py extract build/verified-archives/screenshots.tar --output . --prefix fastlane/screenshots/processed
python3 scripts/ci/evidence.py screenshots fastlane/screenshots/processed --output build/verified-screenshots.json
cmp build/verified-screenshots.json "$directory/screenshots-manifest.json"
