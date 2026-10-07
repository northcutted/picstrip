# App Store assets

Edit the locale files in [fastlane/metadata](../../fastlane/metadata); they are the source of truth. [The review guide](MARKETING.md) explains how to check them against the release candidate.

| Asset | Source | Validation |
|---|---|---|
| Descriptions, release notes and promotional text | `fastlane/metadata/<locale>/` | `python3 scripts/validate_store_metadata.py` |
| Review instructions | `fastlane/metadata/review_information/notes.txt` | Exercise the fictional sample and described flows |
| Screenshot headlines | `fastlane/MarketingHeadlines.xcstrings` | Inspect composed iPhone/iPad screenshots |
| Screenshot captures and inventory | `.github/ios-release.json`, `PicStripUITests` | Six screens in two classes for all 17 store locales |
| Accessibility declarations | `fastlane/accessibility_declarations.json` | Evaluate the claimed tasks on the supported devices |

Capture and composition prepare reviewable assets. App Store mutation uses the verified deployment workflow and its approval gates. Release notes are curated in every locale; engineering changelogs never replace them.

## Universal creative asset (iOS/iPadOS 27)

One 16:9 picture that the App Store crops into the product page header and the search results asset. `scripts/make_creative_assets.py` draws it in code: the store street video in PicStrip's editor (blurred face, 😎, blacked-out phone number, Bleep clip) with location, device and date chips lifting off, beside line 1 of the `01_VideoEditor` and `02_Location` headlines. It writes `PicStrip-universal-<store locale>.png` for the 17 store locales plus `PicStrip-universal-textless.png` (5244 × 2950, sRGB, no alpha) to `~/Desktop/PicStrip Creative Assets/`, and header and search crops plus an all-locale montage to `previews/` for review only. The words and faces stay inside x 700–4544, y 500–2200 so both crops and the App Store's overlay at the bottom of the header leave them alone; the script fails if a translation would leave that area.

```sh
python3 -m venv build/creative-venv
build/creative-venv/bin/pip install pillow numpy "qrcode[pil]"   # Pillow with libraqm, for Arabic
build/creative-venv/bin/python scripts/make_creative_assets.py   # or --locale en-US --locale ar-SA
```

The asset is not part of the fastlane deployment. Upload it in App Store Connect → Asset Library and submit it as a standalone submission (no app version needed): each locale's image under its localization, and the textless image wherever a language-free version is wanted.

The release pipeline does not upload it yet. `scripts/upload_creative_assets.py` does, with your own App Store Connect API key (App Manager or Admin; standard library and `openssl` only, nothing stored). For each language of an app version still in Prepare for Submission it uploads that locale's image to Asset Library and places it as both the header and the search results asset; languages already placed are skipped, so it can be run again. It only shows its plan unless given `--apply`:

```sh
python3 scripts/upload_creative_assets.py --key-id <Key ID> --issuer-id <Issuer ID> --key ~/Downloads/AuthKey_<Key ID>.p8          # plan
python3 scripts/upload_creative_assets.py --key-id <Key ID> --issuer-id <Issuer ID> --key ~/Downloads/AuthKey_<Key ID>.p8 --apply  # upload
```
