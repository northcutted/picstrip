# Release operations

PicStrip consumes the public MIT-licensed [iOS release platform](https://github.com/northcutted/ios-release-workflows). `.github/ios-release.json` declares PicStrip's targets, toolchains, profiles, app groups, privacy/encryption policy, locales, screenshots, and App Store policy. `.github/ios-release-platform.json` records the full platform commit; every workflow and composite action uses that same commit.

## Lifecycle

**Main → verified candidate → manual promotion → TestFlight processing → immutable release → staging → production approval → submission.**

Main prepares a clean signed IPA alongside QA and packaging. It does not distribute automatically. A candidate includes the exact source, platform identity, configuration digest, QA reports, component inventory, SBOMs, signing identities, and provenance. Promotion requires an explicit artifact ID and SHA256. It never selects the latest candidate or rebuilds one.

`RELEASE_DISTRIBUTION_ENABLED` must remain false until rehearsal and control readback succeed. `TESTFLIGHT_CANARY_ENABLED=true` permits an explicit TestFlight canary without publishing. An absent variable is false.

1. Merge a PR only after `CI Gate` passes. The gate includes iOS 27 tests, iOS 26 compatibility tests, static analysis, lint, localization validation, workflow policy, locked gems, and screenshot composition smoke tests.
2. Main runs `Release Prep`; the manual equivalent is `gh workflow run main.yml --ref main`. Inspect the candidate artifact ID/digest in the run summary, its signing/inventory evidence, and retained archive/dSYMs.
3. Dispatch `Promote Candidate` on main with those exact `artifact_id` and `sha256`, the candidate's configured upload adapter, and `publish=false`. PicStrip initially uses Transporter. Switching to Build Uploads requires a reviewed configuration change and a Linux canary; there is no automatic adapter fallback.
4. Apple must report the recorded build as `VALID`. A successful canary emits a signed processed-handoff artifact with its own ID/digest. To publish later, supply the original candidate ID/digest plus `processed_artifact_id` and `processed_sha256`, and set `publish=true`. This reads back the existing build and skips transfer.
5. Publication creates/resumes a draft, checks the actual peeled tag commit, attaches and reads back all evidence, then publishes immutably. `release.published` triggers staging of the exact processed Apple build, reviewed metadata, screenshots, accessibility declarations, and configured compliance fields.
6. Inspect the staged draft and approve the `production` environment. Submission verifies the build again, preserves permitted metadata edits, explicitly applies automatic/phased release with readback, checks readiness, and waits for Apple to confirm submission. Apple still decides review outcomes.

Hourly observation reports build, review, availability, and phased-release state once distribution is enabled. Agreements, account setup, business/compliance answers, and unsupported portal requirements remain owner prerequisites. Configured TestFlight groups are assigned with readback; external groups also require Apple's beta review and previously supplied beta-review information. PicStrip currently declares no automatic tester groups.

## Repository and credential controls

Main requires PRs and an up-to-date `CI Gate`, with zero mandatory peer approvals so the owner can merge alone. Only the publisher App may create protected `v*` tags. Published releases/assets are immutable. Production keeps human approval and disables administrator bypass.

| Environment | Eligible ref | Credentials |
| --- | --- | --- |
| signing | main | Match password and read-only certificate-repository SSH key |
| testflight | main | App Store upload key |
| release-publishing | main | Publisher App ID/private key |
| screenshot-publishing | main | App credentials for screenshot PRs |
| app-store-staging | v* tags | App Store metadata key |
| production | v* tags | App Store submission key and required approval |
| app-store-observe | main | App Store read access |

The publisher App requires Contents: write, Administration: read, and Pull requests: write for screenshot PRs. Each job requests only its needed token permissions. Callers explicitly bind only each interface's named secrets (`NAME: ${{ secrets.NAME }}`). GitHub needs those bindings even when the protected environment supplies the actual value; repository-wide copies are unnecessary. CI receives none, and `secrets: inherit` is forbidden. Compilation has no App Store API key or attestation permission; evidence signing runs separately. Privileged platform jobs never execute PicStrip's Fastfile, Gemfile, or arbitrary hooks. Consumer build phases necessarily run inside the approved app's compilation job.

Preview/apply controls only after CI passes for the currently checked-in revision:

```sh
python3 scripts/ci/configure_repository.py --ci-run CI_RUN_ID --release-app-id 3718913
python3 scripts/ci/configure_repository.py --ci-run CI_RUN_ID --release-app-id 3718913 --apply
```

The helper preserves production reviewers, disables distribution, and reads the resulting controls back. Promotion independently checks live controls for drift. One repository owns each Apple app in v1; GitHub concurrency cannot serialize two independent repositories.

## Retry and metadata operations

Use **Re-run failed jobs** on the original promotion/deployment run. Operation artifacts are selected only from that run and validated by digest; prior successful job attempts remain usable. Upload/file IDs and checksums, review submission/item IDs, and Apple state are reconciled before resuming. A conflicting build, unrelated review item, missing evidence, or ambiguous legacy upload stops the operation.

A successful signed canary handoff can also be supplied explicitly to a later promotion. Already-published releases are verified and reused, never overwritten. Preparation is separate from deployment, so retrying metadata or review cannot rebuild the IPA.

For a staging retry, dispatch `app-store-deploy.yml` with the workflow ref and `release_tag` both set to the same immutable tag. For reviewed metadata changes, merge the text by PR, then run:

```sh
gh workflow run metadata-only.yml --ref vX.Y.Z \
  -f release_tag=vX.Y.Z -f metadata_commit=FULL_REVIEWED_COMMIT_SHA \
  -f submit_for_review=true
```

Metadata is read from that exact main-ancestor commit; file hashes and differences are recorded. Review uses the same production gate. All Apple mutation jobs share the app's repository concurrency group. A newer queued request can supersede an older pending request under GitHub's concurrency semantics; rerun a superseded request deliberately.

Submission receipts contain public metadata/build snapshots and differences, exclude review credentials/contact details, and are signed separately from immutable release assets. Receipts, candidates, and archive diagnostics have 90-day Actions retention. Download them for longer retention; public Actions artifacts are not private storage.

## SLSA Build L3 scope

The target is defensible **SLSA Build L3 for the GitHub-produced IPA**, not certification or a digest claim about Apple's redistributed binary. Native attestations alone do not establish that posture.

| Control | Implementation |
| --- | --- |
| Build isolation | Ephemeral hosted runners; clean signed archive; no restored executable build cache in signing/evidence jobs |
| Provenance isolation | Upstream isolated SLSA generator; no compilation OIDC/attestation signing privileges |
| Independent identities | Manifest schema v3 separates consumer source, trusted platform revision, app/team, configuration, candidate, and Apple operation IDs |
| Authentication | Pinned producer workflow/revision, exact consumer source/run, subject digests, native signatures and isolated SLSA provenance |
| Handoff | Complete verified evidence before upload; signed processed build; verified immutable publication; exact build at submission |
| Authorization | PR/check rules, publisher-only tags, environment ref restrictions, human production approval |

The generator's `@v2.1.0` version-tag reference is the documented verifier compatibility exception to full commit pins. Trust includes GitHub hosting, approved consumer source, pinned platform/dependencies, maintainers, signing keys, and Apple's service. An authentic provenance statement does not prove source code benign. Transporter recovery requires retained verified transfer evidence unless Apple's upload checksum independently binds the bytes.

See [SLSA requirements](https://slsa.dev/spec/v1.2/build-requirements) and [generator reference requirements](https://github.com/slsa-framework/slsa-github-generator#referencing-slsa-builders-and-generators).

## Local verification and benchmarks

```sh
npm ci --ignore-scripts
npm run check:workflows
npm run test:ci
actionlint
ruby -c fastlane/Fastfile
```

The platform repository owns release/evidence/recovery tests, including the locked Fastlane lane contracts and independent consumer fixtures. Its Linux/macOS tests do not substitute for a signed consumer rehearsal or a real third-party app run. The separate [native consumer fixture](https://github.com/northcutted/ios-release-consumer-fixture) passed both iOS test targets and the evidence gate without PicStrip files or release credentials. This is a separate-repository rehearsal, not yet an independently owned customer run. Public repositories and Enterprise Cloud private repositories are supported; required native attestations and approval features must be available.

To verify a downloaded release, use an independently trusted checkout at the pinned platform commit:

```sh
export IOS_RELEASE_CONFIG="$PWD/.github/ios-release.json"
export IOS_RELEASE_REVISION=FULL_PINNED_PLATFORM_SHA
gh release download vX.Y.Z --repo northcutted/picstrip --dir release-assets
python3 /path/to/trusted-platform/scripts/ci/verify_release.py release-assets \
  --source FULL_SOURCE_SHA --tag vX.Y.Z --final
```

Install `gh` with attestation support and `slsa-verifier` first. Update the platform pin with `python3 scripts/update_release_platform.py FULL_REVIEWED_PLATFORM_SHA`, then review and run CI.

Production testing remains serial. Compare five equivalent successful runs and account for flakes before enabling two workers; require at least 15% lower median test duration. Separate queue time, execution, Apple processing, and approval delay. `scripts/ci/benchmark.py` accepts five run IDs and an optional `--baseline-test-seconds` value. No runtime saving is claimed without those measurements.

Screenshot scenarios and branding stay in PicStrip. `Capture Screenshots` validates inputs, captures, composes and validates the complete inventory, then opens a PR. Review images before merging. App Store uploads use the verified deployment path.
