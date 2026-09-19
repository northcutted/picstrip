fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios lint

```sh
[bundle exec] fastlane ios lint
```

Run SwiftLint

### ios analyze

```sh
[bundle exec] fastlane ios analyze
```

Run xcodebuild analyze (static analysis)

### ios test

```sh
[bundle exec] fastlane ios test
```

Run unit tests on simulator

### ios certificates

```sh
[bundle exec] fastlane ios certificates
```

Sync App Store distribution certificates (readonly on CI)

### ios build

```sh
[bundle exec] fastlane ios build
```

Build and export the exact release version without changing tracked files

### ios upload_testflight

```sh
[bundle exec] fastlane ios upload_testflight
```

Upload an already-built IPA to TestFlight

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Capture App Store screenshots on simulator (reads fastlane/Snapfile)

### ios process_screenshots

```sh
[bundle exec] fastlane ios process_screenshots
```

Compose marketing screenshots from raw captures into ./fastlane/screenshots/processed/

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Upload composed marketing screenshots from ./fastlane/screenshots/processed/ to App Store Connect (binary unchanged). LOCAL DEV ONLY — requires an existing 'Prepare for Submission' draft version in App Store Connect. The release deploy workflow stages screenshots before the production approval gate, then submits the current App Store Connect draft as-is.

### ios wait_processing

```sh
[bundle exec] fastlane ios wait_processing
```

Wait on Linux for the exact uploaded build to finish processing

### ios app_store_stage

```sh
[bundle exec] fastlane ios app_store_stage
```

Stage verified metadata, screenshots, and the exact processed build

### ios request_review

```sh
[bundle exec] fastlane ios request_review
```

Submit the verified build after approval, recording permitted metadata edits

### ios metadata_only

```sh
[bundle exec] fastlane ios metadata_only
```

Update metadata for a verified release; review always uses request_review

### ios preflight

```sh
[bundle exec] fastlane ios preflight
```



### ios submit

```sh
[bundle exec] fastlane ios submit
```



### ios accessibility

```sh
[bundle exec] fastlane ios accessibility
```

Sync App Store Accessibility Nutrition Label declarations

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
