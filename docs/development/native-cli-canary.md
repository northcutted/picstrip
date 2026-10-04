# Native CLI canary

Run **Native CLI signed canary** manually from `main` to rehearse Rust archive/export against a frozen PicStrip commit. The workflow imports existing Match assets read-only, builds with the pinned native CLI, and independently verifies the IPA, app and share-extension signatures, embedded App Store profiles, entitlements and matching dSYMs on a runner without signing credentials.

The separate App Store observation job uses the native API client to read PicStrip's app, version and build status. This canary does not upload its `1.7.0 (9998.1)` archive, submit App Review, or publish the app. Its artifact is a diagnostic archive, not a release candidate. Signed artifacts and verification reports expire after 14 days; failure logs expire after three days.

The existing consumer platform pin, release preparation, release approval and production workflows remain the default. The canary's native source revision is declared explicitly in its environment and checkout steps. Update those together only after the shared-platform checks pass for the reviewed revision.

For onboarding a new app, use the shared platform's [native quickstart](https://github.com/northcutted/ios-release-workflows/blob/881bbc5d7cb6f5bf715bdf884924a0b67e8b50a8/docs/native-quickstart.md). `examples/OrbitNotes` supplies a disposable native app and extension for onboarding and screenshot rehearsals without another developer account app record.
