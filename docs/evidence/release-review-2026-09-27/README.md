**PicStrip release-review evidence — 27 September 2026**

This directory accompanies [the review](/Users/eddie/Development/PicStrip/docs/reviews/1.7.0-2026-09-27.md). Reviewed source: c7eabd3b4b24f35059bc0df56b9ae455b49caf4f.

**What is retained**

- Six fresh native simulator screenshots and their capture manifest.
- The timestamped read-only App Store observation for version 1.7.0/build 77.1.
- Staged and latest prepared release manifests, build-environment records, and latest hosted QA manifest.
- A compact local verification summary.
- Diagnostic test sources saved with a .swift.txt suffix so they are not compiled into either test target.
- Exact failing diagnostic assertions, using synthetic data.

No IPA, signing material, original user photo, credential, or full DerivedData directory is included. The diagnostic GPS coordinates and fictional document fixture are test data.

**Interpreting the probes**

The diagnostic assertions express expected privacy behavior and intentionally fail against the reviewed source. They do not mean that the existing 207-test suite failed.

| Probe | Result |
|---|---|
| Failed scan warning survives export preparation | Failure confirms the warning is cleared. |
| Default audit omits removed GPS values | Two failures confirm latitude and longitude are copied into the JSON. |
| Processed bytes advertise an image type | Failure confirms the Data representation advertises public.data. Receiver-specific behavior remains untested. |
| Private key redaction includes its payload | The header-recognition precondition fails, making the downstream coverage assertion inconclusive for that exact scenario. Do not count this as a fourth independently confirmed runtime defect. |

The temporary diagnostic source files were removed from their test-target folders after testing and preserved here. Production source was not edited.

**Reproduction**

Working directory: /Users/eddie/Development/PicStrip.

The local simulator was iPhone 17, iOS 27.0, identifier 473CA813-9A41-4E62-B1CA-377553FDB87E. Xcode was 27.0 beta build 27A5194q. Discover an available destination on another machine and use the pinned release Xcode for final acceptance.

Read-only source/status inspection:

```sh
git status --short
python3 scripts/audit_xcstrings.py
xcodebuild -showdestinations -project PicStrip.xcodeproj -scheme PicStrip
```

Existing unit suite (creates local test artifacts and runs the simulator):

```sh
xcodebuild test -project PicStrip.xcodeproj -scheme PicStrip \
  -destination 'platform=iOS Simulator,id=473CA813-9A41-4E62-B1CA-377553FDB87E' \
  -parallel-testing-enabled NO \
  -derivedDataPath /private/tmp/picstrip-review-repeat/DerivedData \
  -resultBundlePath /private/tmp/picstrip-review-repeat/UnitTests.xcresult \
  -only-testing:PicStripTests CODE_SIGNING_ALLOWED=NO
```

To reproduce the diagnostic probes, copy ReleaseReviewProbes.swift.txt temporarily into PicStripTests/ReleaseReviewProbes.swift and run the same command with a new result-bundle path and -only-testing:PicStripTests/ReleaseReviewProbes. Expect failures on the reviewed source. Remove only the temporary copy afterward.

For the native screenshot flow, temporarily copy ReleaseReviewScreenshots.swift.txt into PicStripUITests/ReleaseReviewScreenshots.swift and use scheme PicStripScreenshots with -only-testing:PicStripUITests/ReleaseReviewScreenshots. Its name-analysis disable flag and forced camera-button visibility are for deterministic inspection; they do not validate those hardware/model features.

The original raw logs and .xcresult bundles are in /private/tmp/picstrip-review-20260927. These temporary files are not a durable archive. The final report and this compact evidence set are the durable handoff.
