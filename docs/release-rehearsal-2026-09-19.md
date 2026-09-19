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

Five one-worker and five two-worker runs were dispatched against the exact source above using secret-free CI. The benchmark compares the `Run test` step, reports queue time separately, and retains failures rather than selecting only successful runs. Two workers require all five candidate runs to pass and at least a 15% median test-duration improvement. Production remains at one worker until that criterion is demonstrated.

| Sample | One worker | Two workers |
| --- | --- | --- |
| 1 | [35458121764](https://github.com/northcutted/picstrip/actions/runs/35458121764) | [35458132893](https://github.com/northcutted/picstrip/actions/runs/35458132893) |
| 2 | [35458123857](https://github.com/northcutted/picstrip/actions/runs/35458123857) | [35458135005](https://github.com/northcutted/picstrip/actions/runs/35458135005) |
| 3 | [35458125858](https://github.com/northcutted/picstrip/actions/runs/35458125858) | [35458137218](https://github.com/northcutted/picstrip/actions/runs/35458137218) |
| 4 | [35458128169](https://github.com/northcutted/picstrip/actions/runs/35458128169) | [35458139292](https://github.com/northcutted/picstrip/actions/runs/35458139292) |
| 5 | [35458130477](https://github.com/northcutted/picstrip/actions/runs/35458130477) | [35458141507](https://github.com/northcutted/picstrip/actions/runs/35458141507) |

Results remain pending while GitHub assigns native iOS runners. Apple processing and human approval are outside this CI benchmark and must be measured during promotion and submission.

## Independent ownership

The [separate consumer fixture](https://github.com/northcutted/ios-release-consumer-fixture/actions/runs/35447354263) passed native iOS CI without PicStrip files or release credentials. It shares PicStrip's owner and therefore does not demonstrate independent ownership. A repository owned by an independent party, with authorization to create a workflow PR and run CI, is still required for that validation.
