# Developer guide

Start with [README](README.md#run-it) to build PicStrip and `make help` for local commands.

For command-line tooling, install uv and run `make setup`, then `make check`. The pinned Python toolkit is shared with CI. Add `bin/ios-release setup --apple` for screenshots/signing or `bin/ios-release setup --images` for marketing image composition and OCR fixtures. Xcode must already be installed; `bin/ios-release doctor --apple --xcode` checks your toolchain.

| Task | Guide |
| --- | --- |
| Understand targets, state, privacy and app flows | [App architecture](docs/development/architecture.md) |
| Change image encoding, metadata or export behavior | [Image processing](docs/development/image-processing.md) |
| Change detection rules or add a PII type | [PII detection](docs/development/pii-detection.md) |
| Edit translations and validate string catalogs | [Localization](docs/development/localization.md) and [glossary](docs/localization-glossary.md) |
| Run CI, prepare a candidate or operate a release | [CI/CD guide](docs/release-pipeline.md) |
| Review App Store copy and screenshots | [Marketing guide](docs/marketing/README.md) |
| Complete the pending 1.7.0 device acceptance | [Acceptance checklist](docs/releases/1.7.0-acceptance.md) |
| Inspect historical reviews and verification | [Release archive](docs/archive/README.md) |

The app, share extension and intents share `PicStripCore`. Keep source, tests and these guides together when changing a contract. Release tooling belongs to the pinned workflow platform; app-specific policy stays in `.github/ios-release.json`.

The OCR fixture has one source, `Tests/Fixtures/test_list.png`, copied into both test bundles by Xcode. Run `make test-fixture` only when changing that fixture. The App Store screenshot fixtures in `PicStripUITests/Fixtures/` are drawn by `scripts/make_store_fixtures.py` (see its header for the Pillow, NumPy, qrcode and ffmpeg it needs).
