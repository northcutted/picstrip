# PicStrip pipeline integration

[Start here](../release-pipeline.md) · [Operations](operations.md) · [Reference](reference.md) · [Maintenance](maintenance.md)

PicStrip owns its app and release policy. Shared architecture, security, SLSA scope, supported configuration and recovery behavior live in the platform. Open the [platform guides at PicStrip's exact pin](reference.md#platform-guides).

## Ownership

| PicStrip owns | Source |
| --- | --- |
| App identity, Xcode/runtime choices, targets, QA, locales and store policy | [App configuration](../../.github/ios-release.json) |
| Reviewed platform revision | [Platform pin](../../.github/ios-release-platform.json) |
| GitHub events, manual release choices and required gate | [Caller workflows](../../.github/workflows) |
| Conservative path selection | [Classifier](../../scripts/ci/changes.py) |
| Version policy | [Version configuration](../../.github/ios-version.json) |
| Store content, UI scenarios and screenshot composition | [fastlane](../../fastlane), [UI tests](../../PicStripUITests), [compositor](../../scripts/process_screenshots.py) |
| App operating guide, example paths and generated reference | [Docs profile](../../.github/ios-release-docs.json) |

The platform owns the Python package, generator, command implementation, Python lockfile and Ruby lockfile. [bin/ios-release](../../bin/ios-release) uses the [local launcher](../../scripts/ios_release.py) and reviewed pin; Actions installs the same package through its pinned bootstrap action. Ordinary QA uses native Xcode commands. App-owned Fastlane code is limited to screenshot scenarios; privileged release jobs use platform-owned code. Screenshot composition keeps its app-owned, hash-locked Python dependencies in a separate environment.

## PR checks and performance

Policy and `CI Gate` always run. The classifier selects native QA, UI smoke and store inventory checks. Unknown paths, missing comparison history and manual runs select all checks. Native QA covers lint/localization, analysis and tests on both configured runtimes. Screenshot capture exercises app-specific behavior on every configured device, with a fresh host per device. The matrix comes from `screenshot_devices` in app configuration; both iPhone and iPad results are required. One failure does not cancel the other device, and each job retains its own screenshots and failure diagnostics.

The former separate gem-install job is covered by platform dependency CI and the actual screenshot consumer job. Compare runner queue time, setup, test execution and Apple processing separately. The [recorded five-run comparison](../archive/releases/1.7.0/release-rehearsal-2026-09-19.md#performance-comparison) found two workers slower; default test execution remains serial.

## SLSA Build L3 scope

PicStrip retains its selected defensible Build L3 target for the GitHub-produced IPA. The platform's pinned architecture guide explains the scope, trust assumptions and evidence verification. Dated PicStrip rehearsals establish only their recorded revisions; new platform behavior requires fresh consumer checks.

## Recover with newer tools

Use the [pinned platform operations guide](reference.md#platform-guides) for producer approvals, deployment tags and retained handoffs. Keep PicStrip's exact candidate/build selection and device acceptance attached to the release; a tools upgrade does not select a different binary.
