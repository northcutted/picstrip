# Native release cutover

PicStrip's production workflow still uses the reviewed legacy platform pin in
`.github/ios-release-platform.json`. The separate native pin in
`.github/ios-release-native-platform.json` is for a migration rehearsal. It cannot
prepare, upload, select an Apple build, submit for review or publish the app.

The platform implementation is [ios-release-workflows #46](https://github.com/northcutted/ios-release-workflows/pull/46).
Merge that change before this consumer adoption. Preserve the native commit pin;
a later platform fix requires a reviewed pin update and fresh rehearsal results.
The existing signed canary is older evidence and still imports signing assets
through Fastlane; it is not native signing-vault or Apple-delivery proof.

## Run and inspect the rehearsal

The **Native release readiness** workflow runs when its configuration changes in
a PR, and can be dispatched explicitly against a selected branch. Before a cutover,
run it on the exact proposed main commit, alongside the existing release checks.
Its reusable workflow has read-only permissions and no Apple/signing secrets.

It checks:

- All 17 configured metadata locales and 204 committed RGB PNGs, fetched through
  Git LFS. Missing captures, pointer files, damaged PNGs and invalid store fields fail.
- Conventional Commit version selection using complete repository history. The
  platform's frozen PicStrip reference also compares the entire native decision,
  including release notes, with the deployed implementation.
- SwiftLint, localization, analysis, current-Xcode tests and compatibility tests.
- English and Arabic screenshot scenarios, on a separate fresh runner for each of
  the configured iPhone and iPad devices.

`Native rehearsal gate` requires every job. Retain its run URL, exact source SHA,
platform SHA, QA evidence, screenshots, `store.json` and `version.json`. Review
rendered screenshots before treating a capture as store-ready. The rehearsal is
not a replacement for the existing required `CI Gate` until its results are proven.

## Gates before changing production

| Gate | Required evidence |
| --- | --- |
| Native QA | Green rehearsal on the exact cutover commit, plus the existing CI gate |
| Native signing | Import the existing distribution identity into an encrypted vault; reconcile the app and extension profiles without revoking unrelated assets; archive without Fastlane; independently verify the IPA and matching dSYMs |
| Release content | Authenticate the schema-3 package containing the exact IPA, store text, screenshots, review instructions, accessibility declarations and symbols; reject altered files |
| Apple delivery | Upload that package once, observe successful processing, and verify App Store build/version/IPA identity before staging |
| Store migration | Read back all configured locales, screenshot checksums/order, review details and accessibility declarations; exercise resume after an interrupted upload and screenshot replacement |
| Release evidence | Implement and prove source/runtime SBOM and isolated SLSA parity, immutable GitHub release records and durable recovery beyond 90-day Actions retention |
| Metadata-only updates | Implement an attested, source-bound content update that preserves the already verified IPA; the native `metadata` operation currently reapplies the original sealed snapshot |
| Production approval | Confirm main-only environment policies, exact-build reauthentication and the separate human approval gate for App Review/public release |

The release-evidence and metadata-only implementation gaps are not resolved by a
green rehearsal. Do not delete Fastlane, remove legacy secrets, repoint the release
workflows or mark native releases production-ready while these gates remain open.
The app-owned Python/Pillow artwork compositor is also outside this native release
migration; generated store images remain reviewed PicStrip inputs.

For the first native signing rehearsal, use a separate native configuration and
vault so existing Match profile names and production workflows remain available.
Choose `build_number_offset` from the then-current Apple build inventory: native
Actions uses `(workflow run number + offset).attempt`, rejects values behind Apple,
and bounds the components. Do not reuse the canary's old hardcoded version/build.

The default screenshot policy preserves remote assets and reuses identical bytes
uploaded by Fastlane. Deliberate replacement requires
`app_store.screenshot_policy: "replace-configured"` in the sealed native configuration.
It saves the old inventory before deleting superseded assets in the configured
locale/device classes. Re-running the same preparation reconciles by checksum;
other classes are preserved. Keep previous release content available for recovery.

## Adoption and recovery order

1. Merge the shared platform changes and this isolated rehearsal, keeping the
   production pin unchanged.
2. Close the release-evidence and metadata-update implementation gaps, then collect
   native-vault signing, Apple delivery and interrupted-operation proof for one exact
   PicStrip candidate. Record run IDs and Apple resource IDs in the release acceptance
   document; a green archive alone is insufficient.
3. Change the production callers and required checks in a dedicated cutover PR.
   Re-run both pipelines on its exact source and preserve the previous pin/configuration.
4. After successful native delivery and recovery proof, remove unused legacy adapters
   and secrets separately. Preserve historical release artifacts and provenance.

Before any Apple upload, rollback is a caller/configuration revert. After an upload,
resume or inspect the exact native receipt and Apple build first. Never pass the same
build number to a second pipeline with different IPA bytes. A public-release rollback
is an Apple release operation, not a Git revert.
