# Pipeline cleanup implementation

Routine release operations now use **Release** with an exact run URL and an explicit action. The workflow resolves and authenticates the artifact IDs, digests, upload adapter, and optional processed handoff. **Release Maintenance** combines status and protection diagnostics. App Store deployment remains a protected internal worker.

The app has six workflow files instead of eight. Documentation changes skip simulator jobs and automatic candidate preparation; store changes still validate metadata/screenshots, and release-input changes still receive full candidate QA. Relevant app changes trigger UI smoke automatically. Unrelated labels no longer restart PR checks. Developer gems are checked for tooling/dependency or unknown changes. The required `CI Gate` rejects failed classification and unexpected skips.

Status polling defaults to every six hours. It reports meaningful transitions, always refreshes the newest release, and keeps older active or unknown states under observation. Manual refresh includes older completed releases. Previous observations never authorize release actions.

The duplicate local version calculator and its unused npm dependencies were removed. Version policy remains in the pinned platform, including the temporary 1.7.0 replacement policy. Updating the platform pin explicitly preserves the prior producer and approves the reviewed new producer, allowing old candidates and corrected deployment tools to interoperate.

## Validation and evidence

- App workflow policy, actionlint, 13 classification/gate tests, and curated metadata validation for all 17 locales passed locally.
- Platform workflow policy/actionlint, 9 Node tests, 51 Python tests, and 39 Ruby tests passed locally. The real macOS certificate test passed with normal macOS code-signing access; sandboxed extraction had failed, and that check was not weakened or skipped.
- The new read-only resolver authenticated the existing signed 1.7.0 build 86.1, including native signatures, SLSA provenance, source identity, archive checksum, and all declared assets. Its IPA hash remained `ac900cbcfb80f13475c746629c5d5bbdfd02f54dc2c041edb7e73a80b33488fd`.
- A separate read-only check authenticated the historical build 77.1 processed handoff from run 35471442447 and recovered its original candidate identity without another upload. This verifies resume compatibility; it does not replace build 86.1 as the selected release. The result is retained in `docs/evidence/pipeline-cleanup-2026-09-28/verified-historical-resume.json`.
- The resolved identity is retained in `docs/evidence/pipeline-cleanup-2026-09-28/verified-build-86.1.json`.
- The obsolete **Encrypt release environment secrets** workflow (362088815) was disabled and read back as `disabled_manually`; its prior successful run remains intact.
- Shared changes are in [platform PR 31](https://github.com/northcutted/ios-release-workflows/pull/31), stacked on [PR 30](https://github.com/northcutted/ios-release-workflows/pull/30). Hosted Linux and macOS checks passed for platform commit `060db3e9c163ece5eb2836ac06344828b728bfe8`; app checks are recorded on its PR.

## Release boundaries

This cleanup does not upload, stage, publish, or submit an Apple build. Build 86.1 remains the selected reviewed candidate, and its producer `d59e678d4f8f997dfdcbefe065c3c4efa9758f96` remains explicitly trusted.

Keep `replacement_release` until the 1.7.0 transition is complete. Removing it now would change the pending release's version-selection behavior. Its later removal remains an explicit reviewed follow-up before normal version advancement. Keep production approval and the `v*` deployment restrictions.

The new controller uses the existing verified upload and submission implementation. Its first Apple-facing run still requires the existing release authorization and device acceptance; local tests and GitHub-only artifact verification do not claim a new App Store rehearsal.
