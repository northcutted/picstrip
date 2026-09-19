# Local app tooling

PicStrip's Fastfile supports local lint, analysis, tests, signing/build diagnostics, screenshot capture, and screenshot composition. Use `bundle exec fastlane lanes` or `make help` for the local commands.

Release operations run through the pinned [public iOS release platform](https://github.com/northcutted/ios-release-workflows). The former local upload, staging, submission, and metadata lanes fail closed to prevent alternate release paths.

See [release operations](../docs/release-pipeline.md) for candidate preparation, manual promotion, App Store approval, metadata changes, and retries. Screenshot scenarios and assets remain app-owned; deployment tools and locked dependencies are platform-owned.
