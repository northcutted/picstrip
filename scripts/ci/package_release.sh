#!/usr/bin/env bash
set -euo pipefail
export ZSTD_CLEVEL=6
mkdir -p build/package
python3 - <<'PY'
import json, os, pathlib, re
version = os.environ['VERSION']
assert re.fullmatch(r'\d+\.\d+\.\d+', version)
data = json.loads(pathlib.Path('build/version/semantic-release.json').read_text())
assert data['source_sha'] == os.environ['SOURCE_SHA'] and data['version'] == version
pathlib.Path('build/package/release-notes.md').write_text(data['notes'] + '\n')
PY
bash scripts/render_app_store_metadata.sh build/package/release-notes.md build/app-store-metadata build/package/app-store-metadata.tar.zst
python3 scripts/ci/evidence.py metadata build/app-store-metadata/fastlane/metadata
python3 scripts/ci/evidence.py screenshots fastlane/screenshots/processed --output build/package/screenshots-manifest.json
tar --zstd -cf build/package/app-store-screenshots.tar.zst fastlane/screenshots/processed
git archive --format=tar --prefix="picstrip-$VERSION/" "$SOURCE_SHA" | zstd -6 -T2 -o build/package/release-source.tar.zst
python3 scripts/ci/evidence.py checksums build/package --output build/package/package-checksums.json
