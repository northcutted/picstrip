# Release dependency advisory review

Reviewed 2026-09-19. The initial inventories contained 18 alerts in PicStrip and 18 in the workflow platform, covering the same locked release-tool dependency graph. These packages run in CI/developer tooling and are not embedded iOS libraries. Affected locked versions were confirmed; exploitability of each advisory against a supported release path was not established. No alerts were dismissed as false positives.

The remediation updates Fastlane to 2.240.1, Excon to 1.7.1, Faraday to 2.14.4, JWT to 3.3.0, JSON to 2.21.2, YAML to 2.9.1, and compatible npm transitive dependencies. `npm audit` reports zero vulnerabilities after resolution. The platform's Linux/macOS release contract tests and PicStrip's [signed preparation](https://github.com/northcutted/picstrip/actions/runs/35457372446) passed with these locks. The updated Ruby client also authenticated a read-only App Store Connect request.

| Advisory | Package | PicStrip / platform alert | Assessment |
| --- | --- | --- | --- |
| [GHSA-2883-xcg3-v3hh](https://github.com/advisories/GHSA-2883-xcg3-v3hh) | `js-yaml` | 27 / 28 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-w9m9-85wc-3x92](https://github.com/advisories/GHSA-w9m9-85wc-3x92) | `postcss-selector-parser` | 26 / 27 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-5p4m-2wfm-xmqj](https://github.com/advisories/GHSA-5p4m-2wfm-xmqj) | `js-yaml` | 24 / 25 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-mwp4-54f8-5fhr](https://github.com/advisories/GHSA-mwp4-54f8-5fhr) | `ip-address` | 23 / 24 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-w8wr-v893-vjvp](https://github.com/advisories/GHSA-w8wr-v893-vjvp) | `tar` | 19 / 20 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-52cp-r559-cp3m](https://github.com/advisories/GHSA-52cp-r559-cp3m) | `js-yaml` | 15 / 16 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-3jxr-9vmj-r5cp](https://github.com/advisories/GHSA-3jxr-9vmj-r5cp) | `brace-expansion` | 14 / 15 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-52v5-jr5w-gjxr](https://github.com/advisories/GHSA-52v5-jr5w-gjxr) | `sigstore` | 13 / 14 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-h67p-54hq-rp68](https://github.com/advisories/GHSA-h67p-54hq-rp68) | `js-yaml` | 12 / 13 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-jfc7-64v2-mr8c](https://github.com/advisories/GHSA-jfc7-64v2-mr8c) | `@sigstore/core` | 11 / 12 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-vmf3-w455-68vh](https://github.com/advisories/GHSA-vmf3-w455-68vh) | `tar` | 10 / 11 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-v2v4-37r5-5v8g](https://github.com/advisories/GHSA-v2v4-37r5-5v8g) | `ip-address` | 9 / 10 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-3v7f-55p6-f55p](https://github.com/advisories/GHSA-3v7f-55p6-f55p) | `picomatch` | 7 / 8 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-x2f5-4prf-w687](https://github.com/advisories/GHSA-x2f5-4prf-w687) | `json` | 5 / 5 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-48rx-c7pg-q66r](https://github.com/advisories/GHSA-48rx-c7pg-q66r) | `excon` | 4 / 4 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-98m9-hrrm-r99r](https://github.com/advisories/GHSA-98m9-hrrm-r99r) | `faraday` | 3 / 3 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-c32j-vqhx-rx3x](https://github.com/advisories/GHSA-c32j-vqhx-rx3x) | `jwt` | 2 / 2 | Affected tool version updated; exploitation not demonstrated |
| [GHSA-3m6g-2423-7cp3](https://github.com/advisories/GHSA-3m6g-2423-7cp3) | `json` | 1 / 1 | Affected tool version updated; exploitation not demonstrated |

An additional npm audit finding in `yaml` (GHSA-48c2-rrv3-qjmp) was fixed by the 2.9.1 update. Platform signatures/provenance use the separately pinned GitHub/SLSA tools; npm Sigstore packages arrive through semantic-release dependencies rather than the platform verifier. Ruby HTTP/JSON/JWT dependencies also execute in Apple credential-bearing jobs, so their updates are verified with the locked release lane tests.

After [PicStrip PR 18](https://github.com/northcutted/picstrip/pull/18) and [platform PR 20](https://github.com/northcutted/ios-release-workflows/pull/20) merged, GitHub's open-alert API returned **zero open alerts in both repositories**, read back on 2026-09-19. This is a point-in-time result, not a claim that future advisories cannot appear. Dependency-update PRs remain subject to the normal required checks; enabling Dependabot does not enable automatic merges.

## Dependabot integration

The remaining version updates are integrated together with the reusable platform. Commit analyzer 13.0.1 and Conventional Commits 10.4.0 preserve breaking-change detection when updated together. Release notes generator 14.1.1 needs a scoped override to changelog writer 9.2.1 for this preset; tests assert rendered notes and commit links. Minitest 6.0.6 uses the extracted `minitest-mock` test dependency. Future release-analysis updates are grouped.

The older security PRs are covered by the current lock: `semantic-release` 25.0.9 (transitive peer only), `@sigstore/core` 3.2.1, `sigstore` 4.1.1, `tar` 7.5.22, npm 11.19.1, and `js-yaml` 4.3.2. The removed write-enabled release command is not reintroduced.

Arabic reshaper 3.0.1 was installed with verified PyPI hashes; all ten Arabic screenshots rendered successfully in an isolated output directory. Actions checkout 7.0.1 and setup-node 7.0.0 retain full commit pins.
