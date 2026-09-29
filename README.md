<div align="center">
  <img src="docs/icons/PicStrip%20Exports/PicStrip-iOS-Default-1024x1024%401x.png" width="120" alt="PicStrip app icon"/>

# PicStrip

[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-blue.svg)](https://www.apple.com/ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![CI](https://github.com/northcutted/picstrip/actions/workflows/main.yml/badge.svg)](https://github.com/northcutted/picstrip/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Your photos, your privacy. Strip metadata and redact sensitive text — 100% on your device.**

</div>

PicStrip removes EXIF location data, camera metadata, and visually redacts personally identifiable information (PII) from photos before you share them. Scanning and image processing use Apple frameworks on the device. PicStrip has no developer photo server, analytics or advertising SDK. User-selected imports, saves and shares follow the chosen service settings; optional Apple models may need a download.

---

## Screenshots

<p align="center">
  <img src="fastlane/screenshots/processed/en-US/iPhone%2018%20Pro%20Max-03_Metadata.png" width="240" alt="A loaded photo with its risks ranked"/>
  <img src="fastlane/screenshots/processed/en-US/iPhone%2018%20Pro%20Max-02_RedactionEditor.png" width="240" alt="The redaction editor"/>
  <img src="fastlane/screenshots/processed/en-US/iPhone%2018%20Pro%20Max-01_FullPreview.png" width="240" alt="Inspect the cleaned image in full"/>
</p>

---

## What PicStrip Does

| Feature | Description |
|---------|-------------|
| **Metadata Stripping** | Removes GPS, EXIF, EXIF Auxiliary, TIFF, IPTC, and Apple Maker Note metadata, with per-field control over what to keep |
| **Visual PII Detection** | On-device OCR and Vision find 31 kinds of sensitive data across 4 risk tiers (Critical, High, Medium, Low) |
| **Name Detection** | Where Apple Intelligence is on, Apple's on-device language model finds people's names — listed, off by default, never Private Cloud Compute |
| **Redaction Editor** | Solid, crosshatch, pixelate, or blur in 12 colors, with adjustable blur and pixelate strength, previewed live in the editor; move, resize, draw your own boxes; multi-select bulk edits; 50-step undo/redo |
| **Tap to Redact** | On iOS 27, tap an object and PicStrip boxes it for you (uses an Apple model that iOS downloads once, only after you agree) |
| **Take Photo** | An advisory live viewfinder; the captured image receives a full scan and review; the photo goes straight into the editor and the original never reaches your photo library |
| **Scan Document** | Scan paper into the editor; multi-page scans use batch. Captures are not automatically saved to Photos |
| **Import Anywhere** | Photos, Files, paste, drag and drop; review the supplied image and metadata |
| **Batch Processing** | Process sequentially with a shared policy; incomplete visual scans are skipped, successful copies are retained, and cancellation stops future saves |
| **Try a Sample** | Explore a fictional image without granting library access; compare the original and cleaned output |
| **Accessible Editing** | Add a centered box and adjust its position and size without drawing; changes remain undoable |
| **Save, Replace, Share** | Save a cleaned copy, replace the original, or share; PNG (privacy default), JPEG, HEIC, or the original format |
| **Audit Reports** | Export field names, counts and scan status without original values or detected text |
| **Share Extension** | Save cleaned copies from the share sheet, or prepare the first original for editing using a protected, expiring handoff |
| **Shortcuts** | "Clean Photos with PicStrip" opens the picker; "Strip Metadata from Images" removes metadata only in the background |

Available in English and 16 more localizations, including separate Spanish for Spain and Latin America.

---

## Privacy

- Scanning, redaction and metadata removal happen on your device. No account, analytics or advertising SDK is required.
- Name suggestions use Apple's on-device model and remain optional for redaction.
- Live-camera overlays are a guide; review the full scan after capture. PicStrip does not automatically save an unreviewed capture to Photos.
- A model for object selection can download from Apple after consent. Cloud imports, synced photo libraries and chosen share destinations follow their own settings.
- Protected, backup-excluded edit handoffs expire after 15 minutes and are consumed once. Export files are cleaned up on completion where possible, with an expiry sweep as a fallback.
- Automatic detection can miss details. Failed required checks remain visible and require a deliberate manual-review confirmation in the editor; unattended visual workflows reject incomplete scans.

The full statement is in [PRIVACY.md](PRIVACY.md); the privacy manifest, permissions and required-reason APIs are covered in [DEVELOPMENT.md](DEVELOPMENT.md#privacy--security).

---

## How It Works

```mermaid
graph TD
    A["SwiftUI Views\nContentView · LiveCameraView · PreSaveReviewView · BatchConfigView"] -->|observes| B["ScrubberViewModel\n@Observable @MainActor"]
    B -->|verified export| P["ExportPipeline · ScanCoverage\nImageResourceBudget · PrivateFileStore"]
    P --> C["ImageProcessor\nstateless enum"]
    B -->|calls| D["PIIScanner\nstateless struct"]
    B -->|calls| E["ImageRedactor\nstateless struct"]
    B -->|calls| G["SemanticPII · ObjectSelection\non-device models, app only"]
    C -->|ImageIO| F["Apple Frameworks\nImageIO · Vision · VisionKit · AVFoundation · CoreImage\nFoundationModels · Photos · AppIntents"]
    D -->|Vision + NSDataDetector| F
    E -->|CoreGraphics + CoreImage| F
    G -->|FoundationModels + Vision| F

    classDef views   fill:#d1f5e8,stroke:#3db87f,color:#0a2a22
    classDef vm      fill:#1f7a61,stroke:#0a2a22,color:#ffffff
    classDef service fill:#a8e6cc,stroke:#1f7a61,color:#0a2a22
    classDef system  fill:#0a2a22,stroke:#000000,color:#3db87f

    class A views
    class B vm
    class C,D,E,G service
    class F system
```

**A two-pass ImageIO pipeline.** A single re-encode still lets iOS synthesise a minimal EXIF block. PicStrip decodes and zeroes the EXIF/TIFF dictionaries, then uses `CGImageDestinationCopyImageSource` with `kCGImageDestinationMergeMetadata: false` to replace the whole metadata tree with only what you chose to keep.

**Layered detection.** One `ImageRequestHandler(data).performAll(...)` pass runs text, face, barcode and document-rectangle requests; 60 regex rules, `NSDataDetector` and a cross-line credential heuristic work over the recognised text; checksums adjust confidence; document context boosts what belongs on a card or ID. Raw `Data` — not a decoded image — goes to Vision, so boxes land correctly whatever the photo's orientation.

**Zero runtime third-party dependencies.** Every framework is Apple's. Details, data flows and the full detection catalog are in [DEVELOPMENT.md](DEVELOPMENT.md).

---

## Run It

```bash
git clone https://github.com/northcutted/picstrip.git
cd picstrip
open PicStrip.xcodeproj
```

1. Select the **PicStrip** target → **Signing & Capabilities** → set **Team** to your Apple Developer account. Repeat for **PicStripShareExtension**.
2. Pick an iPhone 17 simulator, or a device running iOS 26 or later. The camera, document scanner and tap to redact need a real device.
3. Press **Cmd + R**.

| | |
|-|-|
| **iOS** | 26.0+ (tap to redact needs iOS 27; name detection needs Apple Intelligence) |
| **Xcode** | 27.0 (26.6 is the pinned compatibility build; iOS 27-only code compiles out below Swift 6.4) |
| **Swift** | Swift 6 language mode |
| **Apple Developer Account** | Required for signing and the share extension's App Group |

---

## Developer Commands

| Command | What it does |
|---------|--------------|
| `make help` | Lists every helper command |
| `make test` | Unit tests on the iPhone 17 simulator |
| `make lint` | SwiftLint (strict) plus the string catalog audit |
| `make audit-localization` | Finds unlocalized literals and catalog gaps (every key in all 16 localizations, placeholders intact, plural forms complete) |
| `make screenshots` | App Store screenshot capture; `DEVICE=` / `DEVICES=` select a subset |

For checks, TestFlight, and App Store updates, start with [CI/CD: from a change to the App Store](docs/release-pipeline.md). The [workflow reference](docs/ci-cd/reference.md) is generated from source; `make docs` refreshes it and `make check-docs` catches drift. The pinned release platform targets SLSA Build Level 3 for the GitHub-built IPA.

Translations are LLM-generated from the English source and edited inline; the rules and per-locale terms are in [DEVELOPMENT.md](DEVELOPMENT.md#localization) and the [localization glossary](docs/localization-glossary.md).

---

## Contributing

See [DEVELOPMENT.md](DEVELOPMENT.md) for the architecture, data flows, the detection engine, and how to add a new PII type.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:` bumps the minor version, `fix:` / `perf:` / `revert:` the patch, `BREAKING CHANGE:` the major.

---

## App Store

[![Download on the App Store](https://img.shields.io/badge/Download-App%20Store-black?logo=apple&logoColor=white&style=for-the-badge)](https://apps.apple.com/app/picstrip/id6765989071)

---

## License and Support

MIT — see [LICENSE](LICENSE). Questions and bugs: open an [Issue](https://github.com/northcutted/picstrip/issues) or start a [Discussion](https://github.com/northcutted/picstrip/discussions).
