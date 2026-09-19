#!/usr/bin/env bash
set -euo pipefail
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release tag' >&2; exit 1; }
gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" > release-info.json
jq -e --arg tag "$RELEASE_TAG" '.tag_name == $tag and .draft == false and .prerelease == false and .immutable == true' release-info.json >/dev/null
mkdir -p release-assets
gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --dir release-assets
source_sha=$(git rev-parse HEAD)
python3 scripts/ci/verify_release.py release-assets --source "$source_sha" --tag "$RELEASE_TAG" --final
python3 scripts/ci/evidence.py verify release-assets --source "$source_sha" --tag "$RELEASE_TAG" --final
