#!/usr/bin/env bash
set -euo pipefail
branch="codex/screenshots-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
git switch -c "$branch"
rsync -a --delete incoming/ fastlane/screenshots/processed/
cp build/screenshots-manifest.json fastlane/screenshots/manifest.json
git add fastlane/screenshots/processed/ fastlane/screenshots/manifest.json
if git diff --cached --quiet; then exit 0; fi
git -c user.name='picstrip-release[bot]' -c user.email='picstrip-release[bot]@users.noreply.github.com' commit -m 'chore(screenshots): refresh reviewed App Store captures'
# The installation token is transient and is never persisted in the checkout.
auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')
echo "::add-mask::$auth"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" git push origin "$branch"
cat > "$RUNNER_TEMP/screenshot-pr.md" <<'BODY'
Refresh the App Store screenshot assets from the pinned capture toolchain. All configured locale/device combinations passed the screenshot coverage and dimension checks.

Review the images before merging. This pull request does not submit an App Store release.
BODY
gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" --title 'chore(screenshots): refresh App Store captures' --body-file "$RUNNER_TEMP/screenshot-pr.md"
