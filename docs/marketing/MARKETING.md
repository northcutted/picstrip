# App Store copy review

The upload source is [fastlane/metadata](../../fastlane/metadata). Review the actual files in a PR; this guide does not duplicate a second copy of the description.

## The promise

PicStrip helps people find and cover private details in photos and videos, remove hidden metadata, and inspect a cleaned copy before sharing. Scanning, redaction and metadata removal run on the device. Automatic detection can miss details, and the user decides what to share.

## Match the exact binary

- Names require available Apple Intelligence and remain opt-in for coverage. Object selection on supported systems may require an Apple model download after consent.
- Photo styles are solid, crosshatch, pixelate, blur and emoji (an emoji sits on a full-strength blur). Use solid opaque coverage for secrets; blur and pixelation can leave recognizable structure.
- Video covering is assistive: faces, text and drawn objects are tracked, and one can be missed for a moment. Never claim anonymity; the app tells people to watch the preview before sharing.
- Record Video records at the Camera app's quality where the device supports it (4K/HD, 24–120 fps, HDR, enhanced stabilization) — say "up to", since formats vary by device. Recordings are never saved to Photos as they are, and the microphone is used only while recording.
- Background Shortcuts remove metadata only. Visible-content review and redaction happen in PicStrip.
- The sharing preset chooses an output format and restores default removal choices. It does not promise that every sensitive detail was detected.
- Review reports contain field names, counts and status, never original metadata values or detected text.
- Direct extension editing starts with the first original image. Its protected local handoff expires after 15 minutes; cleanup runs when the app or extension next accesses storage.
- Large images may need an explicitly chosen smaller copy. Avoid promising unlimited resolution or memory use.
- Saving to Photos, using cloud file providers and sharing to chosen apps follow those services’ settings. Use the precise [privacy policy](../../PRIVACY.md); do not claim that user-directed copies never leave the device.

## Prepare the text

Edit descriptions, promotional text and release notes in all 17 configured store locales. Run:

```sh
python3 scripts/validate_store_metadata.py
python3 scripts/audit_xcstrings.py
```

The first check validates lengths, presence and release-note language boundaries. The second checks app translations, placeholders and plural coverage. Neither certifies native-language quality. Inspect representative localized screens and review terminology in [the glossary](../localization-glossary.md).

Keep engineering details in the GitHub release notes. Run `python3 scripts/validate_store_metadata.py` to validate curated copy. The verified platform packages it for release.

## Prepare screenshots

Use the configured capture workflow and actual app UI. Lead with the video editor (two faces in a street video, one blurred and one given an emoji, a bleep on the timeline), then a photo's location, the live viewfinder outlining a face, an email and a QR code, the photo editor (blur, pixelate, emoji and solid covers on faces, a phone number, a card and a code), the review with every check finished, and photos and videos in one batch. Headlines sell the benefit, not a UI label, and never mention license plates (plate detection is narrow). Six screens × two device classes × 17 locales produces 204 images. Verify count, dimensions, text fit, order and source identity in the candidate manifest.

The scenes run on fictional fixtures drawn by `scripts/make_store_fixtures.py` (people, café, badge and street video; every name, number, card and place is invented) and bundled with the UI tests; `testAllScreenshots` opens each with a `PICSTRIP_*` fixture variable.

The screenshot workflow prepares assets for review; publishing a release and deploying to Apple are separate actions. Follow [release operations](../release-pipeline.md) and [the 1.7.0 acceptance record](../releases/1.7.0-acceptance.md).

## Submission details

Review [the reviewer instructions](../../fastlane/metadata/review_information/notes.txt), support/privacy URLs, contact fields, encryption declarations and [accessibility declarations](../../fastlane/accessibility_declarations.json). Do not copy a support claim from an earlier binary without evaluating the changed flow. See [face-data review guidance](../app_review/face_data_response.md).
