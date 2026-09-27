# App Store assets

Edit the locale files in [fastlane/metadata](../../fastlane/metadata); they are the source of truth. [The review guide](MARKETING.md) explains how to check them against the release candidate.

| Asset | Source | Validation |
|---|---|---|
| Descriptions, release notes and promotional text | `fastlane/metadata/<locale>/` | `python3 scripts/validate_store_metadata.py` |
| Review instructions | `fastlane/metadata/review_information/notes.txt` | Exercise the fictional sample and described flows |
| Screenshot headlines | `fastlane/MarketingHeadlines.xcstrings` | Inspect composed iPhone/iPad screenshots |
| Screenshot captures and inventory | `.github/ios-release.json`, `PicStripUITests` | Five screens in two classes for all 17 store locales |
| Accessibility declarations | `fastlane/accessibility_declarations.json` | Evaluate the claimed tasks on the supported devices |

Capture and composition prepare reviewable assets. App Store mutation uses the verified deployment workflow and its approval gates. Release notes are curated in every locale; engineering changelogs never replace them.
