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

Build and export IPA

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload to TestFlight

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

### ios app_store_stage

```sh
[bundle exec] fastlane ios app_store_stage
```

Stage repo metadata, screenshots, and the processed TestFlight build in App Store Connect without submitting

### ios request_review

```sh
[bundle exec] fastlane ios request_review
```

Request App Review for the current App Store Connect draft. Does not upload metadata, screenshots, or choose a build unless BUILD_NUMBER is explicitly provided.

### ios preflight

```sh
[bundle exec] fastlane ios preflight
```

Alias for app_store_stage

### ios submit

```sh
[bundle exec] fastlane ios submit
```

Alias for request_review

### ios metadata_only

```sh
[bundle exec] fastlane ios metadata_only
```

Push metadata/review information only to an existing App Store version/build. Does not rebuild, upload a binary, or replace screenshots. Defaults to the current editable App Store version and its selected build. Set SUBMIT_FOR_REVIEW=true only when intentionally resubmitting.

### ios accessibility

```sh
[bundle exec] fastlane ios accessibility
```

Sync App Store Accessibility Nutrition Label declarations

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
