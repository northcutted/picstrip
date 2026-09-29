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

Retry a transient failure in the original run so its recorded identity and receipts remain available. For a metadata operation, follow the generated deployment tag to its internal worker. Check runner availability before treating a queued job as failure.

Shared retry rules, interrupted-upload recovery, producer upgrades, retention and replacement semantics live in the [pinned platform operations guide](reference.md#platform-guides). PicStrip's internal workflow exposes advanced recovery inputs; its `submit` default is **true**, so inspect the [exact interface](reference.md#app-store-deploy-internal) before using it.

## Observe Apple state

Use **Release Maintenance → App Store status** for a read-only refresh. Scheduled observation runs only when distribution is enabled; its schedule is in the [reference](reference.md#release-maintenance). It tracks the latest release and recent active/unknown older releases. Manual refresh includes recent completed releases too.

Prior digest-checked observations are optional cache data. They do not authorize distribution or replace fresh Apple readback at a mutation boundary.

## Replacement builds

PicStrip currently records a one-time replacement override in [app configuration](../../.github/ios-release.json). Confirm its exact identity in the [generated reference](reference.md#platform-and-configuration) and follow the [pinned platform replacement procedure](reference.md#platform-guides).

Remove the override in a reviewed follow-up only after the replacement transition is verified complete and normal version advancement should resume. A tools upgrade or a new successful build does not establish completion.
