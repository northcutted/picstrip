# Release operations

PicStrip consumes the public MIT-licensed [iOS release platform](https://github.com/northcutted/ios-release-workflows). `.github/ios-release.json` declares PicStrip's targets, toolchains, profiles, app groups, privacy/encryption policy, locales, screenshots, and App Store policy. `.github/ios-release-platform.json` records the full platform commit; every workflow and composite action uses that same commit.

The [2026-09-19 rehearsal record](release-rehearsal-2026-09-19.md) records the verified candidate, rollout status, dependency remediation, and performance samples.

## Lifecycle

**PR → checks → merge → verified candidate → Release action → TestFlight processing → staging → production approval.**

Main prepares a clean signed IPA alongside QA and packaging when release inputs change. Documentation-only pushes skip preparation. A manual Release Prep run requests a complete candidate. A candidate includes the exact source, platform identity, configuration digest, QA reports, component inventory, SBOMs, signing identities, and provenance.

The **Release** workflow takes an exact preparation or previous TestFlight run URL. It resolves the candidate ID and checksum, authenticates the source and signatures, and freezes the selected identity for the remaining jobs. It never chooses a moving “latest” candidate or rebuilds one. Plain numeric input means the run's API ID; `#86` means preparation workflow number 86.

`RELEASE_DISTRIBUTION_ENABLED` must remain false until rehearsal and control readback succeed. `TESTFLIGHT_CANARY_ENABLED=true` permits an explicit TestFlight canary without publishing. An absent variable is false.

1. Merge a PR after `CI Gate` passes. App changes run iOS 27 tests, iOS 26 compatibility tests, analysis, lint/localization and UI smoke. Tooling changes also check developer gems. Documentation-only and store-only changes skip simulator jobs; store changes still validate metadata and screenshot inventory. Unknown paths and unavailable comparison history request every check. The required gate runs for every PR and rejects unplanned skips. Labels do not restart checks. Manual PR Checks requests the full suite, including UI smoke.
2. Inspect the successful **Release Prep** run and retain its URL. Its summary identifies the signed build and its evidence. The manual equivalent is `gh workflow run main.yml --ref main`.
3. Run **Release** on main. Choose **Upload to TestFlight** and paste that preparation run URL into **Source**. Apple must report the exact uploaded build as `VALID`; the result retains a signed processed handoff. The upload adapter comes from the verified candidate configuration.
4. After device acceptance, run **Release** again. Choose **Prepare App Store submission** and use the successful TestFlight run URL as **Source**. The workflow authenticates both handoffs, reads back the processed Apple build, and skips another transfer. If TestFlight-only acceptance is unnecessary, this action also accepts a preparation run and completes upload and processing before publication.
5. Publication creates/resumes a draft, checks the actual peeled tag commit, attaches and reads back all evidence, then publishes immutably. The internal App Store deployment stages the exact processed Apple build, reviewed metadata, screenshots, accessibility declarations, and compliance fields. Using an existing immutable release tag as Source requests staging of that same published build.
6. Inspect the staged draft and approve the `production` environment. Submission verifies the build again, preserves permitted metadata edits, applies configured release policy with readback, checks readiness, and waits for Apple to confirm submission. Apple still decides review outcomes.

**Release Maintenance → App Store status** provides an immediate refresh. Scheduled observation runs every six hours once distribution is enabled and reports changes in build, review, availability, and phased-release state. It always refreshes the newest release and keeps polling older active/unknown states. Older completed snapshots retain their original observation timestamps; a manual refresh checks them again. Cached observations never authorize a release action. Agreements, account setup, business/compliance answers, and unsupported portal requirements remain owner prerequisites. PicStrip currently declares no automatic TestFlight tester groups.

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

A successful TestFlight run URL can be supplied to Release to resume the same signed processed handoff. Failed or incomplete runs, ambiguous/expired artifacts, unapproved signers, and mismatched handoffs stop resolution. Use the original run's failed-job retry for interrupted uploads; a successful Release run is required for a new promotion. Already-published releases are verified and reused, never overwritten.

For reviewed metadata changes, merge the text by PR, then run Release on main with **Update store metadata** (stage only) or **Update metadata and request review**. Source is the existing immutable release tag. Metadata commit can name an exact reviewed commit; blank freezes the main revision selected when the workflow was dispatched.

```sh
gh workflow run promote.yml --ref main \
  -f action='Update store metadata' -f source=vX.Y.Z \
  -f metadata_commit=FULL_REVIEWED_COMMIT_SHA
```

Metadata is read from that exact main-ancestor commit; file hashes and differences are recorded. Release creates a publisher-only operation tag binding the release, metadata commit, submission choice, originating run, and reviewed deployment source. Its create event starts the internal deployment worker under the existing `v*` environment restrictions. Retrying the originating Release run reuses the tag instead of starting another deployment. Retry a failed deployment in its original run. The internal `app-store-deploy.yml` manual interface remains available for advanced recovery. All Apple mutation jobs share the app's repository concurrency group; deliberately rerun any request superseded by GitHub's pending-run concurrency behavior.

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

Install `gh` with attestation support and `slsa-verifier` first. When signers differ from the verification-tool revision, explicitly set `IOS_RELEASE_TRUSTED_PRODUCER_REVISIONS` to a JSON list of the full reviewed preparation/promotion commits (including the current platform); read approvals from protected configuration, never from downloaded artifacts. Update the platform pin with `python3 scripts/update_release_platform.py FULL_REVIEWED_PLATFORM_SHA`, then review and run CI.

Production testing remains serial. The [five-by-five worker comparison](release-rehearsal-2026-09-19.md#performance-comparison) passed all tests but found two workers slower on both runtimes. Future changes still require five equivalent successful runs, no reliability regression, and at least 15% lower median test duration. Separate queue time, execution, Apple processing, and approval delay. `scripts/ci/benchmark.py` reports complete test-job durations, including setup; the rehearsal evidence separately records the test steps used for the worker comparison. Compare the same measurement when supplying its optional `--baseline-test-seconds` value.

Screenshot scenarios and branding stay in PicStrip. `Capture Screenshots` validates inputs, captures, composes and validates the complete inventory, then opens a PR. Review images before merging. App Store uploads use the verified deployment path.

## Repository-control baseline

The publisher keeps Administration: read. GitHub hides REST bypass actors from that token, so `.github/ios-release.json` records `github_controls`: the owner-verified publisher App, ruleset IDs, server timestamps and GraphQL bypass-node identities. Promotion still checks live protections and requires unchanged, complete bypass evidence. GitHub redacts the private publisher node as `[null]` to the administration-read token. This exact case additionally requires count one, no further page, one owner-recorded Integration, unchanged server-controlled IDs/time, and the live token’s effective `always` bypass. Empty, changed or conflicting responses are rejected. Current control policy is captured from protected main before archived app configuration is loaded. Ruleset changes require owner inspection and a reviewed baseline refresh using the platform's `scripts/ci/capture_controls.py`; release jobs never refresh it automatically.


## Reuse after a deployment-tool repair

The protected `trusted_producer_revisions` configuration explicitly approves the producer of an existing candidate when newer platform tools are needed. It currently retains build 77.1's producer. Bootstrap freezes this policy before loading candidate configuration; every consumed build and promotion signature must still match an approved full commit and the expected workflow. Never take producer approvals from a downloaded artifact.

For promotion from newer main tooling, publication creates a separate protected `vVERSION-deploy-FULL_COMMIT` tag after publishing the immutable evidence. Its create event starts the corrected deployment caller. The platform checks the exact commit suffix and protected-main ancestry, then authenticates the original release and processed Apple build. The original app tag, IPA and assets stay immutable. An original release-event run can reject a newer signer; use the deployment-tag run for this recovery. Manual retries select this exact deployment tag and the original release tag input. Production still requires its existing human approval.

Use **Release Maintenance → Inspect release controls** on main to inspect the publisher token’s read-only REST/GraphQL response. It uses the existing release-publishing environment, reports no credentials, and makes no repository or App Store changes.

## Replacement 1.7.0 build

The reviewed `replacement_release` configuration records the existing `v1.7.0`, build `77.1`, and its exact Apple build ID. Preparation keeps marketing version 1.7.0, requires a higher build number and creates a unique `v1.7.0-build-N.ATTEMPT` evidence tag. The old tag, binary and assets remain immutable. The signed manifest binds the replacement configuration, tag, build and source.

Staging may replace only the recorded old build while the version is `PREPARE_FOR_SUBMISSION` and no review submission is active. It reads the relationship back after mutation. A different selected build or review state stops deployment. Remove the one-time replacement configuration in a later reviewed PR when normal version advancement should resume.

Approval sequence for this remediation: review the app and companion platform PRs, merge after required checks and screenshot review, inspect the main-only signed candidate, then authorize its upload. **Upload to TestFlight** uploads to Apple; it is not a read-only rehearsal. Build 86.1 remains reusable through its preparation run URL after this tooling update. Its producer stays explicitly trusted. Keep the replacement override until the 1.7.0 transition is safely completed, then remove it in a reviewed follow-up so normal version advancement resumes. See the [acceptance record](reviews/1.7.0-implementation-status.md) for device evidence still required before submission.
