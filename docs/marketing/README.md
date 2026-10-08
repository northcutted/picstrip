# App Store assets

Edit the locale files in [fastlane/metadata](../../fastlane/metadata); they are the source of truth. [The review guide](MARKETING.md) explains how to check them against the release candidate.

| Asset | Source | Validation |
|---|---|---|
| Descriptions, release notes and promotional text | `fastlane/metadata/<locale>/` | `python3 scripts/validate_store_metadata.py` |
| Review instructions | `fastlane/metadata/review_information/notes.txt` | Exercise the fictional sample and described flows |
| Screenshot headlines | `fastlane/MarketingHeadlines.xcstrings` | Inspect composed iPhone/iPad screenshots |
| Screenshot captures and inventory | `.github/ios-release.json`, `PicStripUITests` | Six screens in two classes for all 17 store locales |
| Accessibility declarations | `fastlane/accessibility_declarations.json` | Evaluate the claimed tasks on the supported devices |
| App previews | `scripts/make_app_previews.py`, `testAppPreviewFlow` in `PicStripUITests` | Watch both videos; the script checks them against Apple's specification |

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

## App previews

Two App Preview videos per language, real screen recordings of the app: `PicStrip-preview-<locale>-iphone.mp4` (886 × 1920, 6.9" iPhone) and `…-ipad.mp4` (1200 × 1600, 13" iPad). Each is 27.2 seconds of H.264 High 4.0 at 30 fps and 11 Mbit/s, tagged BT.709, with a silent stereo AAC track at 256 kbit/s and 48 kHz. `scripts/make_app_previews.py` makes them in two steps:

1. **Record.** It boots the iPhone 18 Pro Max and iPad Pro 13-inch (M5) simulators on iOS 27.0, sets the status bar to 9:41 and a full battery (a brief 9:42 at the start lines the recording up with the test's clock), builds the `PicStripScreenshots` scheme and runs the UI test `testAppPreviewFlow` while `simctl io recordVideo` records the screen. The test plays the store-screenshot fixtures in five scenes and writes a mark at each step to `/tmp/picstrip_app_preview/marks.jsonl`. It runs only when the script has written `request.json` there, so it is skipped in CI and in other UI test runs.
2. **Compose.** It cuts each scene from the recording at those marks (the `STORYBOARD` table), shortening the stretches where the screen stands still while XCTest looks for the next control. It puts the recording in the screenshots' device frame on their gradient, captions each scene with line 1 of its screenshot headline (`fastlane/MarketingHeadlines.xcstrings`; the bleep scene has no screenshot and takes its caption from `CAPTIONS` in the script), crossfades the scenes and encodes the result. Then it checks the file against Apple's specification with `ffprobe`.

| Seconds | Scene | Caption |
|---|---|---|
| 0–10.8 | The street video is scanned with its faces and the flyer's number outlined. In the editor, Face 2's clip is held and given 😎. Then the timeline is tapped at three points, and the blur, the 😎 and the black bar over the number follow along. | Blur faces in videos |
| 10.4–14.6 | A stretch of the audio lane is held and dragged across, then Bleep is chosen | Bleep what was said |
| 14.2–19.2 | Photo mode outlines a visitor's face, email and QR code, then previews them covered | See it before you shoot |
| 18.8–23.0 | The café photo's Location details, then its Camera & date details | Remove hidden location |
| 22.6–27.2 | Review & Share shows the location removed and the fields stripped; the photo is held to compare it with the original | Check, then share |

Scenes overlap by their 0.4 s crossfades.

```sh
python3 -m venv build/preview-venv
build/preview-venv/bin/pip install --require-hashes -r scripts/requirements.txt
build/preview-venv/bin/python scripts/make_app_previews.py                  # record and compose both (about 20 minutes)
build/preview-venv/bin/python scripts/make_app_previews.py --compose-only   # re-cut the last recordings after editing STORYBOARD
build/preview-venv/bin/python scripts/make_app_previews.py --device ipad --simulator ipad=<UDID>
```

It needs Xcode 27.0 (`DEVELOPER_DIR`, by default `/Applications/Xcode.app`) and `ffmpeg`/`ffprobe` with libx264 (`brew install ffmpeg`). If more than one simulator has a device's name on iOS 27.0, name it with `--simulator`. The videos go to `~/Desktop/PicStrip App Previews/`, with a poster frame (the frame at 7 s) and a contact sheet of each in `previews/`. Recordings, marks and intermediate clips stay in `build/app-previews/`. Another language needs its `CAPTIONS` entry for the bleep scene; the rest comes from the headline catalog and the app's own localization.

Upload them with the same uploader as the creative asset, adding `--previews`. For each language it uploads the videos to Asset Library (App Screenshots and Previews, with the poster frame at 7 s, or `--poster-time`, sent as an `HH:MM:SS:FF` time code at 30 fps) and places each as that language's App Preview for the 6.9" iPhone (`IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY`) or the 13" iPad (`IPAD_13_DISPLAY`). It looks up the placement group of each display class in Apple's Asset Library reference data. A language and device that already has an App Preview is left alone. A video uploaded by an earlier run that stopped before placing it is placed, not uploaded again. Nothing is deleted. As before, it shows only its plan unless given `--apply`:

```sh
python3 scripts/upload_creative_assets.py --key-id <Key ID> --issuer-id <Issuer ID> --key ~/Downloads/AuthKey_<Key ID>.p8 --previews          # plan
python3 scripts/upload_creative_assets.py --key-id <Key ID> --issuer-id <Issuer ID> --key ~/Downloads/AuthKey_<Key ID>.p8 --previews --apply  # upload
```
