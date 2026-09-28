# Release operations

[Start here](../release-pipeline.md) · [Reference](reference.md) · [Architecture](architecture.md) · [Maintenance](maintenance.md)

Use **Release** for normal distribution. Select the `main` branch in Actions. The [generated reference](reference.md#release) lists the exact current choices and inputs. Commands below run from the PicStrip checkout with authenticated `gh`; replace capitalized placeholders before running them.

## Send a build to TestFlight

1. Open a successful **Release Prep** run and inspect its summary. Confirm the intended version, build, source commit, signed candidate, and QA evidence. If a candidate was not required, there is nothing to upload from that run.
2. Open **Release → Run workflow**, choose **Upload to TestFlight**, and paste the preparation run URL into **Source**. Leave **Metadata commit** blank for this action.
3. Wait for the run to complete successfully. Apple must report that exact build as `VALID`; the workflow retains an authenticated processed-build handoff.
4. Keep the successful Release run URL and perform device acceptance on that build. Tester groups are listed in the [reference](reference.md#platform-and-configuration); a processed build does not by itself mean every tester can access it.

CLI equivalent (uploads to Apple):

```sh
gh workflow run promote.yml --ref main \
  -f action='Upload to TestFlight' -f source=PREPARATION_RUN_URL
```

A full run URL is easiest to identify. A plain number is GitHub's **API run ID**, while `#86` means preparation workflow run number 86. The resolver rejects failed/in-progress runs, unrelated sources, ambiguous or expired artifacts, checksum mismatches, and unapproved signers. It never selects a moving “latest” build.

To request preparation manually, run `gh workflow run main.yml --ref main`. This requests a complete candidate, including the full preparation and QA path. Do not dispatch preparation just to retry an interrupted upload.

## Prepare an App Store submission

1. Finish device acceptance on the exact TestFlight build. For the current remediation, use the [1.7.0 acceptance checklist](../reviews/1.7.0-implementation-status.md#final-acceptance-checklist).
2. Run **Release** with **Prepare App Store submission** and the successful TestFlight run URL. The platform verifies both handoffs and reads back the Apple build before reusing it, without another transfer.
3. Follow the resulting **App Store Deploy (internal)** run. Publication verifies all evidence before publishing an immutable GitHub release; deployment stages that exact build, metadata, screenshots, and supported declarations.
4. Inspect staging's build identity, metadata differences, screenshot coverage, and release policy. Approve the protected **production** job only when ready to request Apple review. Apple's review and eventual availability remain separate service states.

```sh
gh workflow run promote.yml --ref main \
  -f action='Prepare App Store submission' -f source=SUCCESSFUL_TESTFLIGHT_RUN_URL
```

This action also accepts a preparation run when a separate TestFlight acceptance step is unnecessary; it then uploads and waits for processing before publication. Prefer the tested TestFlight handoff for normal app updates. An existing immutable release tag can be used to restage its verified build.

Before approval, confirm the [configured release policy](reference.md#platform-and-configuration): automatic release after approval can make the app available after Apple approves it. Agreements, account setup, business/compliance answers, and unsupported portal requirements remain owner tasks.

## Update store metadata

Merge reviewed changes under `fastlane/metadata/` first. Run **Release → Update store metadata** with the immutable release tag as **Source** and the full reviewed main-ancestor SHA as **Metadata commit**. Blank freezes the main revision selected at dispatch; it does not follow later commits.

```sh
gh workflow run promote.yml --ref main \
  -f action='Update store metadata' -f source=IMMUTABLE_RELEASE_TAG \
  -f metadata_commit=FULL_REVIEWED_COMMIT_SHA
```

This stages metadata for the existing verified binary. Choose **Update metadata and request review** to also request the protected production approval step. The local equivalent is `make metadata-only RELEASE_TAG=IMMUTABLE_RELEASE_TAG METADATA_COMMIT=FULL_REVIEWED_COMMIT_SHA`; add `SUBMIT_FOR_REVIEW=true` only when that review path is intended.

The workflow records exact metadata file hashes and differences. A protected operation tag binds the release, metadata commit, submission choice, originating run, and deployment source. Its tag event starts the internal worker under the existing `v*` environment restrictions.

## Refresh screenshots

Run **Capture Screenshots** on main. Leave `languages` blank for all configured locales or supply a comma-separated subset, such as `en-US,ar-SA`. It captures and composes images, validates the complete inventory using unchanged assets for other locales, and opens a PR.

Review the actual images before merging. This operation creates reviewed assets; it does not upload them to Apple. PR UI smoke covers en-US on iPhone and iPad, while the separate capture workflow maintains the full store inventory. Devices, scenes, and locales come from the [reference](reference.md#platform-and-configuration).

## Recover a failed run

| Symptom | Next step |
| --- | --- |
| A PR job fails | Read that job's logs/artifacts; fix the cause or retry a transient failure. The gate must still pass. |
| A run is queued | Inspect runner availability and the workflow's concurrency group. Queued is not an upload failure. |
| TestFlight transfer or processing is interrupted | Use **Re-run failed jobs** on the original Release run. Retained transfer evidence and Apple readback reconcile the attempt. |
| Publication or staging fails | Retry failed jobs in the original run. Verified published releases are reused, never overwritten. |
| Metadata deployment fails after the Release action succeeded | Follow the generated deployment tag to its internal deployment run and retry there. |
| Evidence is missing, expired, or contradictory | Stop promotion. Restore independently retained verified evidence where supported, or prepare a new candidate and repeat acceptance. Never invent an artifact ID or relax verification. |
| Controls or signer checks reject the operation | Follow [control inspection](maintenance.md#inspect-or-change-repository-controls) or [tool-repair recovery](architecture.md#recover-with-newer-tools). |

A failed or incomplete run cannot be supplied as a successful TestFlight handoff. Starting a fresh upload after an uncertain transfer can lose the evidence needed for safe resumption. All Apple mutation jobs share the app's repository concurrency group; GitHub can supersede pending requests, so explicitly rerun an operation that was superseded.

The internal workflow also exposes manual recovery inputs. Its `submit` default is **true**: inspect the [exact interface](reference.md#app-store-deploy-internal) before dispatching it on an approved immutable release/deployment tag. Ordinary releases should use **Release**.

Candidates, submission receipts, and archive diagnostics have 90-day Actions retention; copy required evidence before expiry. Other artifact lifetimes vary by job. Public Actions artifacts are not private storage.

## Observe Apple state

Use **Release Maintenance → App Store status** for a read-only refresh. Scheduled observation runs only when distribution is enabled; its schedule is in the [reference](reference.md#release-maintenance). It tracks the latest release and recent active/unknown older releases. Manual refresh includes recent completed releases too.

Prior digest-checked observations are optional cache data. They do not authorize distribution or replace fresh Apple readback at a mutation boundary.

## Replacement builds

While `replacement_release` is configured, preparation keeps the specified marketing version and requires a build newer than the recorded old one. It publishes evidence under a unique `vVERSION-build-N.ATTEMPT` tag. Existing tags, IPA files, and release assets remain immutable.

Staging may replace only that recorded Apple build while the version is `PREPARE_FOR_SUBMISSION` with no active review submission, and verifies the relationship after mutation. Any other build or state stops deployment. See the [generated override value](reference.md#platform-and-configuration) and [source configuration](../../.github/ios-release.json) for the exact identity.

Remove this one-time override in a reviewed follow-up when the transition is complete and normal version advancement should resume. An old acceptance record or a new successful build does not by itself establish that the transition is complete.
