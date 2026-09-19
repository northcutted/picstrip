#!/usr/bin/env bash
set -euo pipefail
python3 scripts/ci/signing_profiles.py record
directory="$RUNNER_TEMP/picstrip-signing"
git clone --quiet --no-checkout git@github.com:northcutted/picstrip-certs.git "$directory"
commit=$(git -C "$directory" rev-parse HEAD)
git -C "$directory" checkout --quiet -b ci-snapshot "$commit"
password=$(openssl rand -hex 32)
echo "::add-mask::$password"
{
  echo "MATCH_COMMIT=$commit"
  echo "MATCH_GIT_URL=file://$directory"
  echo "MATCH_GIT_BRANCH=ci-snapshot"
  echo "SIGNING_KEYCHAIN=$RUNNER_TEMP/picstrip-signing.keychain-db"
  echo "SIGNING_KEYCHAIN_PASSWORD=$password"
} >> "$GITHUB_ENV"
