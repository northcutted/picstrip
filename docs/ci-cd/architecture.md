# Pipeline architecture and trust

[Start here](../release-pipeline.md) · [Operations](operations.md) · [Reference](reference.md) · [Maintenance](maintenance.md)

PicStrip owns application code and release policy. The public MIT-licensed iOS release platform owns the privileged build, evidence, verification, and Apple operations. Every consumer workflow/action uses the same reviewed full platform commit. Follow the [generated platform link](reference.md#platform-and-configuration) to inspect that exact implementation.

## Ownership

| Concern | Source of truth | Change here when… |
| --- | --- | --- |
| App identity, toolchains, QA, locales, signing profiles, store policy | [ios-release.json](../../.github/ios-release.json) | Changing what this app builds, tests, or ships |
| Trusted platform commit | [ios-release-platform.json](../../.github/ios-release-platform.json) | Adopting reviewed platform changes; use the update helper |
| Events, manual inputs, consumer jobs | [Workflow YAML](../../.github/workflows) | Changing how maintainers enter the pipeline |
| Check selection and required gate | [changes.mjs](../../scripts/ci/changes.mjs) | Changing which paths justify skipping work |
| Version and release-note policy | [.releaserc.json](../../.releaserc.json) | Changing Conventional Commit version rules; implementation lives in the platform |
| Store content and screenshot scenarios | [fastlane](../../fastlane) and [UI tests](../../PicStripUITests) | Editing what users see; review images and text |
| Signing, attestations, promotion, deployment/recovery | Pinned platform workflows and tools | Changing privileged behavior; validate in that repository before repinning PicStrip |
| Actual rules, environment approvals, variables, Apple state | Live GitHub / App Store Connect | Inspecting or operating the service; generated docs cannot establish this state |

Privileged platform jobs do not execute PicStrip's Fastfile, Gemfile, or arbitrary release hooks. Those remain developer/screenshot tools. Approved app build phases necessarily execute during compilation.

## Build once, carry the identity forward

After version selection, **Release Prep** runs archive/signing, QA, and store packaging in parallel. Evidence assembly waits for the required results and authenticates the candidate before it becomes usable.

The handoff binds consumer source, platform revision, app/team, configuration digest, candidate ID, version/build, component inventory, SBOMs, signing identities, QA reports, subject checksums, and provenance. Promotion freezes an exact candidate artifact ID and digest; a run URL is a lookup handle, not a substitute for authentication.

TestFlight processing adds an authenticated Apple-build handoff. Publication verifies the peeled tag commit and reads back assets before making the release immutable. Deployment authenticates that release again and verifies the exact processed Apple build before staging or submission. A successful artifact download or a matching filename is insufficient.

## PRs and performance

PRs receive no release secrets. The required **CI Gate** always reports and rejects failed classification, unexpected skips, cancellations, and failures. Known documentation/store changes avoid irrelevant simulator work; unknown paths or unavailable comparison history run all checks. The [generated examples](reference.md#which-checks-run) execute the real classifier.

The reusable QA workflow shares lint/localization, analysis, and primary/compatibility tests between PRs and release preparation. Production tests remain serial. The [recorded five-run comparison](../release-rehearsal-2026-09-19.md#performance-comparison) found two workers slower on both runtimes; changes require five equivalent successful runs, no reliability regression, and at least 15% lower median test duration.

Separate queue time, execution, Apple processing, and approval delay when comparing runs. `scripts/ci/benchmark.py` measures complete test-job durations including setup; do not compare that with a baseline containing only the test step. Clean signing/evidence jobs do not restore executable build caches.

## Repository and credential controls

These are intended controls, independently checked against live GitHub before release operations. Protected main requires a PR and an up-to-date `CI Gate`; zero mandatory peer approvals allow a solo maintainer. Only the publisher App may create protected `v*` tags. Published releases and assets are immutable. Production requires human approval with administrator bypass disabled.

| Environment | Eligible ref | Purpose / credential scope |
| --- | --- | --- |
| signing | main | Match password and read-only certificate-repository SSH key |
| testflight | main | Apple upload/processing key |
| release-publishing | main | Publisher App credentials |
| screenshot-publishing | main | App credentials for screenshot PRs |
| app-store-staging | v* tags | Apple metadata/staging key |
| production | v* tags | Apple submission key plus required approval |
| app-store-observe | main | Apple read access |

The publisher App needs Contents: write, Administration: read, and Pull requests: write for screenshot PRs; each job narrows its token permissions. Callers bind only named secrets explicitly, even when protected environments supply their values. Repository-wide copies are unnecessary, and `secrets: inherit` is forbidden. Compilation has no Apple API key or provenance-signing privilege; evidence signing is separate.

`RELEASE_DISTRIBUTION_ENABLED` gates distribution. During initial setup/control changes, keep it false until rehearsal and control readback pass. `TESTFLIGHT_CANARY_ENABLED=true` permits a deliberate TestFlight upload without release publication. Absent variables are false. Neither variable's live value can be inferred from this checkout.

One repository owns each Apple app. Repository concurrency does not serialize Apple mutations from other repositories.

## SLSA Build L3 scope

The target is defensible **SLSA Build L3 for the GitHub-produced IPA**. It is not certification or a digest claim about Apple's re-signed, encrypted, or thinned binary. Native GitHub attestations complement isolated provenance; they do not independently establish Build L3.

| Control | Implementation |
| --- | --- |
| Build isolation | Ephemeral runners and a clean signed archive |
| Provenance isolation | Upstream isolated SLSA generator; compilation cannot sign provenance |
| Independent identities | Manifest schema v3 separates consumer, platform, configuration, candidate, and Apple operation identities |
| Authentication | Approved producer workflow/revision, exact source/run, subject digests, native signatures, isolated provenance |
| Distribution | Verified candidate, signed processed build, immutable publication, exact-build submission |
| Authorization | Protected PR/check rules, publisher-only tags, ref-restricted environments, production approval |

The generator's `@v2.1.0` reference is the documented version-tag exception needed by its verifier. Trust includes GitHub hosting, approved source, platform/dependencies, maintainers, signing keys, and Apple. Authentic provenance does not establish benign source code. Transporter recovery still needs retained verified transfer evidence unless Apple's upload checksum independently binds the bytes.

The platform's Linux/macOS tests and separate consumer fixtures complement a real signed consumer rehearsal. Supported repository plans must provide native attestations and the required approval controls. Historical rehearsal results are evidence for their recorded revisions only.

## Recover with newer tools

`trusted_producer_revisions` explicitly approves existing producers when newer tools must process an older candidate. Protected-main policy is frozen before candidate configuration is loaded. Every consumed signature must still match an approved full commit and expected workflow; downloaded artifacts cannot add their own producer approvals.

When promotion uses newer tooling, publication can create a separate protected `vVERSION-deploy-FULL_COMMIT` tag. Its event starts the corrected deployment caller after checking the suffix, main ancestry, original release, and processed Apple build. Original app tags and assets remain immutable. Use the deployment-tag run when the original release-event caller cannot authenticate a newer signer. Production retains its approval requirement.

Metadata-only operations similarly use protected operation tags binding the release, exact metadata source, submission choice, and originating run. Retry in the original operation/deployment run so it reuses that identity. See [operations](operations.md#recover-a-failed-run).

## Verify a downloaded release

Use an independently trusted platform checkout at the reviewed pin, with `gh` attestation support and `slsa-verifier` installed. Read approved producer revisions from protected configuration, never from downloaded assets.

```sh
export IOS_RELEASE_CONFIG="$PWD/.github/ios-release.json"
export IOS_RELEASE_REVISION=FULL_PINNED_PLATFORM_SHA
# When producer and verifier revisions differ, set this to the reviewed JSON list:
export IOS_RELEASE_TRUSTED_PRODUCER_REVISIONS='["FULL_APPROVED_PRODUCER_SHA","FULL_PINNED_PLATFORM_SHA"]'
gh release download IMMUTABLE_RELEASE_TAG --repo northcutted/picstrip --dir release-assets
python3 /path/to/trusted-platform/scripts/ci/verify_release.py release-assets \
  --source FULL_APP_SOURCE_SHA --tag IMMUTABLE_RELEASE_TAG --final
```

Replace every placeholder with independently reviewed values. The tool must authenticate signers and all required assets before any Apple mutation; a documentation example does not grant release authorization.
