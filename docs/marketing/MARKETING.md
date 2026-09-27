# App Store copy review

The upload source is [fastlane/metadata](../../fastlane/metadata). Review the actual files in a PR; this guide does not duplicate a second copy of the description.

## The promise

PicStrip helps people find and cover private details, remove hidden metadata, and inspect a cleaned copy before sharing. Scanning, redaction and metadata removal run on the device. Automatic detection can miss details, and the user decides what to share.

## Match the exact binary

- Names require available Apple Intelligence and remain opt-in for coverage. Object selection on supported systems may require an Apple model download after consent.
- Four styles are available: solid, crosshatch, pixelate and blur. Use solid opaque coverage for secrets; blur and pixelation can leave recognizable structure.
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

Keep engineering details in the GitHub release notes. `scripts/write_release_notes.sh` validates the curated copy. The compatibility metadata packager preserves it unchanged.

## Prepare screenshots

Use the configured capture workflow and actual app UI. Lead with a cleaned result and redaction controls, then show metadata, full-image review and the fictional sample. Five screens × two device classes × 17 locales produces 170 images. Verify count, dimensions, text fit, order and source identity in the candidate manifest.

The screenshot workflow prepares assets for review; publishing a release and deploying to Apple are separate actions. Follow [release operations](../release-pipeline.md) and [the 1.7.0 acceptance record](../reviews/1.7.0-implementation-status.md).

## Submission details

Review [the reviewer instructions](../../fastlane/metadata/review_information/notes.txt), support/privacy URLs, contact fields, encryption declarations and [accessibility declarations](../../fastlane/accessibility_declarations.json). Do not copy a support claim from an earlier binary without evaluating the changed flow. See [face-data review guidance](../app_review/face_data_response.md).
