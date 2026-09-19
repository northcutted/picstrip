# Release rehearsal — 2026-09-19

## Verified candidate

[Release preparation 35457372446](https://github.com/northcutted/picstrip/actions/runs/35457372446) passed in 10 minutes 6 seconds, including runner queues. This single result is not a controlled comparison with earlier releases.

| Identity | Value |
| --- | --- |
| Source | `a7c4aa915375ea3c85db7aace5c761c842ba3784` |
| Trusted platform | `492e03f1e80b46f0acdf80c8a2d4aa3a22e921cc` |
| Version / build | `1.7.0` / `73.1` |
| Candidate artifact ID | `10588489713` |
| Candidate artifact SHA256 | `a72975aef7d12891ac8e68055f5853b9a70de065408c34e309cd27caf381c48d` |
| IPA SHA256 | `711a5258851162dcc053dcf0127da9f82c119e37a83b192d2f216ee5db65bead` |

The signed archive, app/extension policy checks, inventory, SBOMs, native attestations, isolated SLSA provenance, and final evidence verification passed. The QA manifest records 147 executed tests on iOS 27 and 147 on iOS 26, with zero skipped tests and zero failures. An independent local download using the pinned platform verifier also authenticated the candidate's artifact digest, producer, source, signatures, provenance, and consumed assets. The signed screenshot inventory contains all 160 images: ten images for each of 16 locales.

The export regression tests now inject a deterministic scanner for unrelated format/metadata contracts. Production still uses the real scanner; dedicated scanner tests remain enabled. A controlled asynchronous test proves save waits for scanning to finish. Local validation passed 11 export tests on iOS 27 and five consecutive iOS 26 iterations (55 tests). The full hosted suites passed on both supported runtimes.

## TestFlight and staging

[Canary 35457971924](https://github.com/northcutted/picstrip/actions/runs/35457971924) authenticated the exact candidate, then stopped before upload because GitHub rejected the publisher installation token: `The permissions requested are not granted to this installation.` This job requests Contents: read and Administration: read. There has been no Apple upload or staging operation from this canary.

The owner must accept the updated grant for `picstrip-release-bot`, installation `132467567`. Its registration needs Contents: write, Administration: read, and Pull requests: write. [GitHub's permission-update instructions](https://docs.github.com/en/apps/using-github-apps/approving-updated-permissions-for-a-github-app) distinguish changing the registration from accepting the installation update.

A separate read-only control check using the operator's GitHub session passed: required PR/CI rules, publisher-only protected tags, immutable releases, environment ref restrictions, and production approval without administrator bypass. This verifies repository settings; it does not establish that the App installation has accepted its requested grant.

After the grant is accepted, resume the same candidate:

```sh
gh run rerun 35457971924 --repo northcutted/picstrip --failed
```

`TESTFLIGHT_CANARY_ENABLED` is true; `RELEASE_DISTRIBUTION_ENABLED` remains false. Distribution may be enabled only after the canary succeeds and repository controls pass readback. Publication must consume the canary's signed processed handoff to reuse the exact Apple build. Staging must read back that build. Production approval remains a separate human action.

## Dependency advisories

The affected release-tool dependencies were upgraded and the changes merged in both repositories. GitHub reports zero open advisories in both repositories; see the [advisory review](release-advisories.md) for package scope and validation.

## Performance comparison

All ten secret-free CI runs passed on the exact source and platform revisions above: five with one XCTest worker and five with two. Every run executed 147 tests on each runtime, with no failures or skips: **2,940 test executions** in total. No samples were rerun or discarded. Worker inputs were checked in the job logs; all iOS 27 samples used the same `xcode-27-arm64` runner image, version `20260912.0186.1`.

**Keep one worker.** Two workers did not meet the required 15% median improvement and were slower on both runtimes in this sample.

| Measurement | One worker median | Two workers median | Change |
| --- | --- | --- | --- |
| iOS 27 test step | 6m06s | 9m55s | 62.6% slower |
| iOS 26 test step | 5m13s | 8m54s | 70.6% slower |

The measured test steps include the clean Xcode build and test execution, excluding prior Ruby/toolchain setup and runner queue time. Individual results:

| Sample | One worker: iOS 27 / iOS 26 | Two workers: iOS 27 / iOS 26 |
| --- | --- | --- |
| 1 | [5m46s / 5m13s](https://github.com/northcutted/picstrip/actions/runs/35458121764) | [14m53s / 7m18s](https://github.com/northcutted/picstrip/actions/runs/35458132893) |
| 2 | [5m32s / 4m27s](https://github.com/northcutted/picstrip/actions/runs/35458123857) | [8m03s / 8m20s](https://github.com/northcutted/picstrip/actions/runs/35458135005) |
| 3 | [6m06s / 6m16s](https://github.com/northcutted/picstrip/actions/runs/35458125858) | [8m20s / 8m54s](https://github.com/northcutted/picstrip/actions/runs/35458137218) |
| 4 | [6m17s / 8m51s](https://github.com/northcutted/picstrip/actions/runs/35458128169) | [14m33s / 15m03s](https://github.com/northcutted/picstrip/actions/runs/35458139292) |
| 5 | [7m57s / 4m44s](https://github.com/northcutted/picstrip/actions/runs/35458130477) | [9m55s / 11m16s](https://github.com/northcutted/picstrip/actions/runs/35458141507) |

Queue time is separate: median iOS 27 runner waits were 21m19s for the one-worker cohort and 40m49s for the two-worker cohort. The cohorts entered the same account's queue in that order while other CI was running. These waits reflect scheduling and are not attributed to the worker setting.

The [machine-readable evidence](evidence/release-benchmark-2026-09-19.json) retains run IDs, QA artifact digests and test counts, individual step durations, and per-job queue/execution timings. Durations use GitHub's `started_at` and `completed_at` timestamps. This is a controlled source/toolchain comparison for the worker decision, not a five-release end-to-end benchmark. Apple processing and human approval remain unmeasured because the canary is blocked before upload.

## Independent ownership

The [separate consumer fixture](https://github.com/northcutted/ios-release-consumer-fixture/actions/runs/35447354263) passed native iOS CI without PicStrip files or release credentials. It shares PicStrip's owner and therefore does not demonstrate independent ownership. A repository owned by an independent party, with authorization to create a workflow PR and run CI, is still required for that validation.
