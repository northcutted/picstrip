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

Upload composed marketing screenshots from ./fastlane/screenshots/processed/ to App Store Connect (binary unchanged)

### ios submit

```sh
[bundle exec] fastlane ios submit
```

Upload metadata + submit the processed TestFlight build for App Review

### ios accessibility

```sh
[bundle exec] fastlane ios accessibility
```

Sync App Store Accessibility Nutrition Label declarations

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
