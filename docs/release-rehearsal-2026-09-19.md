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

The initial [canary 35457971924](https://github.com/northcutted/picstrip/actions/runs/35457971924) stopped at App token creation. The owner has since accepted the updated installation grant.

After all 20 Dependabot PRs were covered by merged integrations, [preparation 35463811140](https://github.com/northcutted/picstrip/actions/runs/35463811140) passed in 9m20s. It produced version 1.7.0/build 75.1 from source `89a2768d29cbf0bf38264a4e367a37d55327ba87`, using platform `a68defff01581aa5accf40ab97dceecd874f75fe`. Independent artifact, native attestation, IPA and SLSA provenance verification passed. Both iOS runtimes executed 147 tests with zero failures or skips.

[Canary 35464407964](https://github.com/northcutted/picstrip/actions/runs/35464407964) authenticated that candidate and successfully created the App token, then stopped before upload because GitHub omitted `bypass_actors` from the administration-read REST response. A separate read-only inspection of a historical Apple upload found that upload state is nested under `attributes.state.state`. The platform now handles that contract and verifies hidden bypasses against an owner-recorded baseline plus live GraphQL identities and unchanged server timestamps. Its regression tests reject drift, incomplete responses and substituted builds.

[Preparation 35466614779](https://github.com/northcutted/picstrip/actions/runs/35466614779) produced the selected version 1.7.0/build 77.1 from `c042d27c17cb359c815dc0744f312c6edc00d2df`, with producer `152fce760a7e5a9261b182ab116e2c0111c2af87`. Candidate artifact `10592175080` has SHA256 `2e2ad3b2a50dfb47d394f76d4d404ed6310fa797378176b0ae119e0c4f36778f`. Its QA, archive, native attestations and isolated SLSA provenance passed, including independent local verification.

[Canary 35467369438](https://github.com/northcutted/picstrip/actions/runs/35467369438) stopped before upload because the unchanged GitHub ruleset timestamp was returned in UTC rather than the owner's Chicago offset. The corrected verifier compares timezone-aware instants with full fractional precision. Protected configuration explicitly approves the candidate's historical producer so this tool repair reuses the same IPA. The update also handles corrected deployment callers through protected deployment tags; no release tag is moved.

[Canary 35468908809](https://github.com/northcutted/picstrip/actions/runs/35468908809) successfully authenticated that historical candidate with the updated verifier, then rejected a private-App GraphQL response. [Read-only diagnostic 35469808337](https://github.com/northcutted/picstrip/actions/runs/35469808337) confirmed unchanged ruleset IDs/timestamps and one redacted node (`[null]`, count one), with the publisher able to bypass release tags but unable to bypass main. The platform now authenticates that exact response using the owner baseline, complete count and effective permission; it does not grant administration write or bypass the gate. A replay against fresh repository settings and all negative regressions passed.

[Canary 35470588488](https://github.com/northcutted/picstrip/actions/runs/35470588488) passed exact candidate authentication and live repository-control verification. Its macOS upload job stopped before transfer because the upstream SLSA installer is Linux-only. The platform now installs checksum-pinned official macOS verifier assets, verifies their upstream provenance, and exercises actual installation in Linux/macOS platform CI. Independent verification of both macOS assets and local arm64 execution passed. IPA provenance checks remain mandatory inside upload.

[Canary 35471442447](https://github.com/northcutted/picstrip/actions/runs/35471442447) passed candidate/provenance verification, live control readback, the macOS Transporter transfer, Linux processing observation and isolated final handoff signing. Apple confirmed version 1.7.0/build 77.1 as `VALID`, with build/upload ID `043d3495-15f2-4955-9a20-5dbf97f072d1`. The signed final artifact is `10593360031`, SHA256 `27f96c2044403db85de06ec588bbbcd8db3c9a1586d9e6442c6cfbd3528f9b0b`. Independent local verification also passed every asset digest, native signature and SLSA claim. It preserves IPA SHA256 `2bcfa818a384cb129e346eab7cfb9948be0e8533db62006cd0ea64e16f57cef6`.

The publication repair creates and peels the protected Git tag explicitly, discovers drafts through authenticated release listing, and resumes the recorded release ID only when its signed handoff and existing asset digests match. Promotion reuses this canary's original signed files without another transfer or signature. Protected policy approves its exact preparation and promotion producers independently.

Publication and staging remain pending this pin's protected CI. Staging must read back the recorded Apple build. Production approval remains a separate human action.

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

The [machine-readable evidence](evidence/release-benchmark-2026-09-19.json) retains run IDs, QA artifact digests and test counts, individual step durations, and per-job queue/execution timings. Durations use GitHub's `started_at` and `completed_at` timestamps. This is a controlled source/toolchain comparison for the worker decision, not a five-release end-to-end benchmark. The successful canary took 12m17s including queues; its Linux Apple-processing step took 7m08s. This is one release observation, not five comparable end-to-end samples. Human approval remains unmeasured.

## Independent ownership

The [separate consumer fixture](https://github.com/northcutted/ios-release-consumer-fixture/actions/runs/35447354263) passed native iOS CI without PicStrip files or release credentials. It shares PicStrip's owner and therefore does not demonstrate independent ownership. A repository owned by an independent party, with authorization to create a workflow PR and run CI, is still required for that validation.
