# PicStrip — Developer Documentation

Architecture details, data flows, service reference, CI/CD documentation, and contributing guidelines.

---

## Table of Contents

1. [Project Structure](#project-structure)
2. [Architecture Overview](#architecture-overview)
3. [Data Flow](#data-flow)
4. [Services Reference](#services-reference)
5. [Image Processing Deep Dive](#image-processing-deep-dive)
6. [PII Detection Engine](#pii-detection-engine)
7. [Share Extension](#share-extension)
8. [App Intent & Siri](#app-intent--siri)
9. [Persistence Model](#persistence-model)
10. [Privacy & Security](#privacy--security)
11. [CI/CD Pipeline](#cicd-pipeline)
12. [SLSA Build Provenance Level 3](#slsa-build-provenance-level-3)
13. [Localization](#localization)
14. [Contributing: Adding a New PII Type](#contributing-adding-a-new-pii-type)
15. [Known Constraints](#known-constraints)

---

## Project Structure

```
PicStrip/
├── PicStrip.xcodeproj/
├── README.md                   # landing page
├── DEVELOPMENT.md              # this file
├── PRIVACY.md                  # the privacy policy users see
├── CHANGELOG.md                # generated from Conventional Commits
├── Makefile                    # `make help` lists the local commands
├── PicStrip-Info.plist         # app Info.plist (usage descriptions, URL scheme)
├── .releaserc.json             # semantic-release config
├── .ruby-version               # Ruby version pin for rbenv
├── Gemfile / Gemfile.lock      # gem "fastlane", "~> 2.240"
├── package.json / package-lock.json  # semantic-release + workflow policy tests
│
├── .github/
│   ├── ios-release.json        # The release config everything reads: Xcode pins, devices, locales
│   ├── ios-release-platform.json  # Pin of the public release platform
│   └── workflows/
│       ├── pr.yml                       # PR gate: policy, lint, analysis, tests
│       ├── main.yml                     # Release candidate: QA, archive, packaging
│       ├── promote.yml                  # Manual promotion of a verified candidate
│       ├── observe.yml                  # Waits for Apple processing
│       ├── app-store-deploy.yml         # Verified App Store staging + review request
│       ├── metadata-only.yml            # Metadata changes through the same gate
│       ├── screenshots.yml              # Manual screenshot capture → reviewed PR
│       └── inspect-release-controls.yml # Audits repository controls
│
├── fastlane/
│   ├── Fastfile                # Lane definitions (release lanes are fail-closed locally)
│   ├── Snapfile                # Screenshot capture; devices + locales come from ios-release.json
│   ├── MarketingHeadlines.xcstrings  # Screenshot headline copy (5 keys)
│   ├── accessibility_declarations.json  # Verified against App Store Connect in CI
│   ├── screenshots/
│   │   ├── <locale>/           # Raw captures, one folder per locale
│   │   └── processed/          # Final marketing PNGs (Git LFS) — uploaded to App Store Connect
│   └── metadata/<locale>/      # App Store name, subtitle, keywords, description, release notes
│
├── scripts/
│   ├── process_screenshots.py  # Marketing screenshot compositor (frame + brand background + headline)
│   ├── make_fixture.py         # Regenerates the OCR test fixture (PicStripUITests/test_list.png)
│   ├── audit_localization_strings.sh  # Flags string-returning literals that should be localized
│   ├── audit_xcstrings.py      # String catalog audit: coverage, placeholders, plural forms, dead keys
│   ├── translate_xcstrings.js  # Pseudo-localizer for layout smoke testing
│   ├── semantic_dry_run.mjs    # Read-only Conventional Commit version/notes analysis
│   ├── render_app_store_metadata.sh / write_release_notes.sh  # Release-note rendering helpers
│   ├── update_release_platform.py  # Bumps the release platform pin
│   └── ci/                     # benchmark.py, configure_repository.py, toolchain.py, workflow_policy.mjs
│
├── docs/
│   ├── release-pipeline.md     # Release operations guide (setup, SLSA scope, verification)
│   ├── localization-glossary.md  # Per-locale term decisions — new strings must reuse them
│   ├── release-advisories.md, release-rehearsal-2026-09-19.md, evidence/  # Dated release records
│   ├── app_review/             # App Review correspondence (face data)
│   ├── icons/                  # Exported app icon variants
│   └── marketing/              # App Store marketing copy + index
│
├── PicStripCore/               # Compiled into BOTH the app and the share extension (not a module)
│   ├── ImageProcessor.swift    # Stateless enum; two-pass ImageIO metadata stripping
│   ├── PIIScanner.swift        # Vision + pattern scan; ScanHints, ScanOutput, liveBoxes
│   ├── ImageRedactor.swift     # Redaction rendering; RedactionStyle, RedactionColor, RedactionSpec
│   ├── DetectionModels.swift   # DetectionResult / DetectedInstance / confidence and risk models
│   ├── DetectionRule.swift     # DetectionRule + DetectionRegistry (60 regex rules)
│   ├── PIIType.swift           # 31 types, their risk tiers, and which are redacted by default
│   ├── ExportPreset.swift      # User-facing ExportFormat and the engine-side ExportPreset
│   └── PhotoLibraryWriter.swift # The only PhotoKit change block (must stay nonisolated)
│
├── PicStrip/                   # Main app target (iOS 26+); a file-system-synchronized group
│   ├── PicStripApp.swift       # @main entry point; drains the share extension's pending image
│   ├── ContentView.swift       # Home screen, photo layout, control panel, redaction editor drawer
│   ├── ScrubberViewModel.swift # @Observable @MainActor; owns the whole data-flow pipeline
│   ├── ZoomableImagePreview.swift  # Zoom/pan preview, live redaction-style preview, draw / move / resize gestures
│   ├── RedactionRegion.swift   # Editable region model (app-only colour bridging)
│   ├── PreSaveReviewView.swift # Final review: what was removed, save / replace / share / audit
│   ├── AdvancedOptionsView.swift   # Export format picker
│   ├── BatchConfigView.swift, BatchSummaryView.swift  # Batch policy sheet and its result
│   ├── MetadataSummaryView.swift, CategoryDetailPanel.swift  # Metadata badges and the per-category panel
│   ├── AboutView.swift         # PII catalogue, import methods, privacy statements
│   ├── ScannerHeroView.swift   # Decorative home-screen animation
│   ├── IncomingImage.swift     # Transferable for paste / drag-and-drop (original bytes, never re-encoded)
│   ├── PasteboardMonitor.swift # Whether the pasteboard holds an image (never reads it); shows/hides Paste
│   ├── LiveCamera.swift        # Live-preview camera: CameraSession (AVCaptureSession), throttle, overlay geometry, view
│   ├── CameraCaptureView.swift # System photo camera (fallback) + CameraHardware (is there a real camera?)
│   ├── DocumentScannerView.swift  # System document camera + DocumentScanFlow (camera-permission mapping)
│   ├── CapturedPages.swift     # In-app capture seam: lazy per-page bytes, ScannedDocument, CapturedImageEncoder
│   ├── ObjectSegmenter.swift   # Tap to redact (iOS 27 Vision segmentation) behind ObjectSelection closures
│   ├── SemanticPII.swift       # On-device language-model pass for people's names + the merge that distrusts it
│   ├── AuditReport.swift       # Codable structs: AuditReport, BatchAuditReport, RedactionReport
│   ├── StripImageIntent.swift, StripMetadataIntent.swift, IntentRouter.swift, ExportFormat+AppEnum.swift  # App Intents
│   ├── Localizable.xcstrings   # All UI strings × 17 localizations (shared with the share extension)
│   ├── AppShortcuts.xcstrings  # Siri / Spotlight phrases
│   ├── InfoPlist.xcstrings     # Localized photo-library and camera permission prompts
│   ├── PrivacyInfo.xcprivacy   # Zero-data-collection privacy manifest
│   ├── Assets.xcassets/, PicStrip.icon/, PicStrip.entitlements
│
├── PicStripShareExtension/     # Share Extension target (separate binary, ~120 MB memory ceiling)
│   ├── ShareViewController.swift    # UIKit host; embeds ExtensionConfigView via UIHostingController
│   ├── Info.plist, InfoPlist.xcstrings, PicStripShareExtension.entitlements
│   └── PrivacyInfo.xcprivacy       # Independent privacy manifest
│
├── PicStripTests/              # Unit tests (XCTest) + fixtures test_pii.png, test_list.png, test_whiteboard.jpg
│   ├── PIIScannerTests.swift, DetectionRegistryTests.swift, SemanticPIITests.swift   # detection
│   ├── ImageProcessorTests.swift, ExportAndBatchRegressionTests.swift               # stripping, export, batch, captured pages
│   ├── RedactionFeatureTests.swift, ObjectSelectionTests.swift, ScrubberViewModelPreviewTests.swift  # redaction + editor
│   ├── DocumentScannerTests.swift, LiveCameraTests.swift, PasteboardMonitorTests.swift             # inputs
│   └── AppIntentTests.swift, LocalizationTests.swift
│
└── PicStripUITests/            # UI tests, in the PicStripScreenshots scheme
    ├── PicStripUITests.swift   # Screenshot capture + home-screen, paste and editor behaviour tests
    ├── PicStripUITestsLaunchTests.swift
    └── SnapshotHelper.swift    # Fastlane snapshot helpers (vendored)
```

**Key notes:**

- `PicStripCore/` files are compiled directly into both the main app and the share extension. This keeps one source of truth without adding a binary framework target.
- `ExportFormat+AppEnum.swift` is compiled **only in the main app target** because it imports `AppIntents`, which is not needed in extensions.
- Both targets have independent `PrivacyInfo.xcprivacy` declarations.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set in both Debug and Release build configurations of the `PicStrip` target. The share extension does **not** set it, so everything in `PicStripCore/` is declared `nonisolated` explicitly and behaves the same in both targets.
- All targets build in the **Swift 6 language mode**. Work that must leave the main actor is a `@concurrent` function returning a `Sendable` value — not a `Task.detached` wrapper.
- iOS 27-only API is wrapped in `#if compiler(>=6.4)` **and** `if #available(iOS 27, *)`, so the project still compiles with the iOS 26 SDK.

---

## Architecture Overview

### Design Pattern: MVVM

```
┌─────────────────────────────────────────────────────┐
│  SwiftUI Views                                      │
│  ContentView · PreSaveReviewView · BatchConfigView  │
└───────────────────────┬─────────────────────────────┘
                        │ observes via @Observable
                        ▼
┌─────────────────────────────────────────────────────┐
│  ScrubberViewModel   @Observable @MainActor         │
│  ├─ selectedItem: PhotosPickerItem?                 │
│  ├─ inputImage: Image?                              │
│  ├─ sourceUIImage: UIImage?                         │
│  ├─ processedData: Data?                            │
│  ├─ outputFileFields: [MetadataField]               │
│  ├─ stripConfig: StripConfig                        │
│  ├─ detectionResults: [DetectionResult]             │
│  ├─ activeSheet: ActiveSheet?                       │
│  └─ processSinglePhoto() / processBatch()           │
└───────────────────────┬─────────────────────────────┘
                        │ calls (no coupling)
                        ▼
┌─────────────────────────────────────────────────────┐
│  Stateless Services                                 │
│  ├─ ImageProcessor  (enum, static methods)         │
│  ├─ PIIScanner      (struct, async)                 │
│  └─ ImageRedactor   (struct, async)                 │
└───────────────────────┬─────────────────────────────┘
                        │ uses
                        ▼
┌─────────────────────────────────────────────────────┐
│  Apple Frameworks                                   │
│  ImageIO · Vision · Photos · PhotosUI · AppIntents  │
│  VisionKit · AVFoundation · CoreGraphics · UIKit    │
│  SwiftUI                                            │
└─────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Stateless services (no instances) | Photo processing is a pure function of inputs; no mutable service state needed |
| Two-pass ImageIO | Single-pass re-encode still triggers iOS auto-synthesis of EXIF; two-pass defeats it |
| `ImageRequestHandler(data)` instead of a decoded `CGImage` | Preserves EXIF orientation so bounding boxes land on the correct pixels (covered by `testBoundingBoxesFollowEXIFOrientation`) |
| Downsampled UI previews | The app keeps full-resolution bytes for export, but decodes display/review previews to bounded images to reduce RAM |
| Off-main image processing | Metadata encode/decode, review preview generation, OCR, redaction rendering and every batch item run in `@concurrent` functions; the view model only publishes final state |
| Fail closed | Batch, the share extension and `StripMetadataIntent` never save or return an image when a requested strip or redaction step failed — an untouched original must not be presented as clean |
| Sequential batch processing | Prevents OOM by keeping peak memory at ~one image at a time |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | Eliminates `@MainActor` annotation noise on view-layer types |
| Static detector caches | Compiles regexes once and reuses the native `NSDataDetector` across scans |
| No persistence | Metadata is ephemeral; the app writes nothing to `UserDefaults`, Core Data or SwiftData |
| In-process `IntentRouter` | `StripImageIntent` runs in the foreground app process and asks the UI for the batch picker directly; the App Group is only used for the share extension's "Edit in PicStrip" file |

---

## Data Flow

### Single-Photo Flow

```
User taps PhotosPicker
    ↓
ContentView.selectedItem.didSet → ScrubberViewModel.handleItemChange()
    ↓
ScrubberViewModel.processSinglePhoto()
    ├─ Load: PhotosPickerItem → Data
    ├─ Downsample display preview via ImageIO → sourceUIImage
    ├─ Scan (async, @concurrent):
    │     PIIScanner.scanImage(data:) → [DetectionResult]
    │     └─ Vision OCR + DetectionRegistry regex + NSDataDetector
    ├─ Off-main process/catalogue:
    │     ImageProcessor.process(...) → processedData + processedPreviewUIImage
    ├─ @MainActor update:
    │     inputImage, sourceUIImage, detectionResults, stripConfig, pendingStrippedMetadata
    └─ isProcessing = false
    ↓
User views metadata panel + red PII overlays
    ↓
User adjusts stripConfig (toggle categories, fields, PII types)
    ↓
User taps "Save to Photos" or "Share"
    ├─ Await in-flight OCR scan (prevents stale empty detection racing save)
    ├─ Prepare review bytes:
    │     Optional: ImageRedactor.redact() if redaction enabled
    │     ImageProcessor.process(image:sourceData:preset:config:)
    │     → processedData, processedPreviewUIImage, outputFileFields
    ├─ presentSheet(.preSave)
    └─ PreSaveReviewView shows format picker + stripped-field summary
    ↓
User taps "Save as New" / "Replace Original" / "Share"
    ├─ PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest }
    ├─ Generate AuditReport JSON → FileManager.tmp
    └─ Dismiss sheet → home screen
```

### Batch-Photo Flow

```
User taps "Pick Multiple" (or Shortcut fires StripImageIntent)
    ↓
ContentView presents BatchConfigView (stripMetadata, redactPII, outputFormat, saveMode)
    ↓
ScrubberViewModel.processBatch(config)  →  runBatch(sources:config:save:)
    ├─ for each BatchSource (sequential — never concurrent):
    │     ├─ Load: PhotosPickerItem → Data
    │     ├─ processBatchItem(...)  ← @concurrent, off the main actor
    │     │     ├─ Scan: PIIScanner.scanImage(data:)
    │     │     ├─ Optional: ImageRedactor.redact()
    │     │     └─ Strip: ImageProcessor.process(...)
    │     │     (returns nil if any requested step fails → photo counted as failed, nothing saved)
    │     ├─ Save: PHPhotoLibrary.performChanges
    │     ├─ Append to batchReports only after Photos accepts the write
    │     └─ @MainActor progress update
    └─ Generate BatchAuditReport JSON (photoCount = saved, failedCount = not saved)
    ↓
BatchSummaryView shows saved and failed counts and the downloadable audit JSON
```

`runBatch` takes its photo sources and its saver as parameters, so unit tests drive the whole loop with in-memory data and never touch the picker or the photo library.

### Document Scan Flow

```
User taps "Scan Document"
    ↓
DocumentScanFlow.step(for: camera permission) → present / request access / explain denial
    ↓
DocumentScannerView (VNDocumentCameraViewController) → ScannedDocument, held in memory
   ("Take Photo" is the same flow with LiveCameraView → the camera's own bytes, without the document hint;
    CameraCaptureView → CapturedPages(photo:) is the fallback)
    ↓  (acted on in the cover's onDismiss — presenting a sheet mid-dismissal can drop it)
ScrubberViewModel.loadCaptured(CapturedPages)
    ├─ 1 page  → CapturedImageEncoder → loadData(_:)      (the single-photo flow above)
    └─ N pages → scannedBatchSources → BatchConfigView  (the batch flow above; no Save Mode)
```

`CapturedPages` is a count plus a `@Sendable (Int) async -> Data?` closure, so pages are encoded one at a time, tests need no camera, and a later in-app camera can feed the same path. The un-redacted capture is never written to the photo library; it is released when the batch state is cleared or the sheet is dismissed (`scannedBatchSources = []`). Captured pages have no library original, so `effectiveBatchConfig(_:)` forces `.saveAsNew`.

### Data Ownership

| Data | Owner | Lifetime |
|------|-------|----------|
| `sourceUIImage: UIImage?` | ScrubberViewModel | Downsampled display preview for the single-photo session |
| `processedData: Data?` | ScrubberViewModel | Set during pre-save prep; nil'd on dismiss |
| `processedPreviewUIImage: UIImage?` | ScrubberViewModel | Downsampled decoded preview of processed bytes; avoids repeated Data decoding |
| `detectionResults: [DetectionResult]` | ScrubberViewModel | Single-photo session |
| `pendingStrippedMetadata: StrippedMetadata?` | ScrubberViewModel | Single-photo session |
| `stripConfig: StripConfig` | ScrubberViewModel | Per-session; persists across format changes |
| `outputFileFields: [MetadataField]` | ScrubberViewModel | Set after each encode pass; after an encode it — not the config — decides what the review and audit call "removed" (`isRemoved(_:)`) |
| Audit JSON | `FileManager.default.temporaryDirectory` | Session; user can share/download; deleted after |

---

## Services Reference

### ImageProcessor

**File:** `PicStripCore/ImageProcessor.swift`

A **stateless enum** (namespace of static methods) responsible for metadata extraction, cataloguing, and two-pass privacy stripping.

#### Public API

```swift
enum ImageProcessor {
    // Strip metadata from raw Data, re-encode with preset.
    static func process(data: Data, preset: ExportPreset, config: StripConfig = .default) throws -> ProcessedImage

    // Strip metadata from an already-rendered UIImage (post-redaction path).
    static func process(image: UIImage, sourceData: Data, preset: ExportPreset, config: StripConfig = .default) throws -> ProcessedImage

    // Catalogue all fields present in data (used for the output-file diff after encoding).
    static func readAllFields(from data: Data) -> [MetadataField]

    // Catalogue fields that will be stripped given config (used for pre-save preview).
    static func catalogueStrippedMetadata(from props: [CFString: Any]?, config: StripConfig) -> StrippedMetadata
}
```

#### StripConfig

```swift
struct StripConfig {
    var categoryEnabled: [String: Bool]    // "GPS": true = strip the whole GPS dict
    var fieldOverrides: [String: Bool]     // "GPS.GPSLatitude": false = keep this field

    static let `default`  // strip all 6 categories
    static let allEnabled // semantic alias of .default for batch call sites
}
```

#### Metadata Categories

| Category | ImageIO key |
|----------|-------------|
| GPS | `kCGImagePropertyGPSDictionary` |
| EXIF | `kCGImagePropertyExifDictionary` |
| EXIF Auxiliary | `kCGImagePropertyExifAuxDictionary` |
| TIFF | `kCGImagePropertyTIFFDictionary` |
| IPTC | `kCGImagePropertyIPTCDictionary` |
| Apple Maker Note | `kCGImagePropertyMakerAppleDictionary` |

#### Structural Fields (Cannot Be Stripped)

The iOS encoder unconditionally re-synthesises these fields into any JPEG or HEIC output:

- Root level: `PixelWidth`, `PixelHeight`, `ColorModel`, `Depth`, `HasAlpha`, `Orientation`, `ProfileName`, `DPIWidth`, `DPIHeight`, `FileSize`, plus `PrimaryImage` and `Headroom` (HEIC only)
- TIFF dict: `Orientation`, `XResolution`, `YResolution`, `ResolutionUnit`, plus `TileWidth` and `TileLength` (the HEVC tile grid, HEIC only)
- EXIF dict: `ColorSpace`, `PixelXDimension`, `PixelYDimension`, `ExifVersion`, `FlashPixVersion`, `ComponentsConfiguration`

The UI marks these with a lock icon and explains they contain no personal data.

---

### PIIScanner

**File:** `PicStripCore/PIIScanner.swift`

A **stateless struct** that runs async Vision OCR followed by layered rule matching.

```swift
struct PIIScanner {
    func scanImage(data: Data, hints: ScanHints = .none) async throws -> [DetectionResult]
    /// scanImage plus the recognised lines, for the on-device name pass.
    func scan(data: Data, hints: ScanHints = .none) async throws -> ScanOutput
    /// Advisory boxes for one camera frame — viewfinder only, never stored.
    static func liveBoxes(in pixelBuffer: CVPixelBuffer,
                          orientation: CGImagePropertyOrientation = .up,
                          textLevel: RecognizeTextRequest.RecognitionLevel = .accurate) async -> [CGRect]
}
```

The method is `@concurrent`, so it always runs off the caller's actor. It throws `invalidImageData` for undecodable bytes and `textRecognitionFailed` when neither OCR model could run — "could not look" is never reported as "found nothing". See [PII Detection Engine](#pii-detection-engine) for the full pipeline.

---

### ImageRedactor

**File:** `PicStripCore/ImageRedactor.swift`

Burns styled redaction blocks over image regions: four styles (`RedactionStyle`: solid, crosshatch, pixelate, blur) in twelve colours (`RedactionColor`), described per region by a `RedactionSpec`. Solid and crosshatch are painted in one `UIGraphicsImageRenderer` pass; crosshatch is an **opaque** fill with a contrasting diagonal lattice whose spacing scales with the region and the image (a see-through fill would leave the text readable, and fixed hairlines vanish at photo resolution). Pixelate and blur run a Core Image pre-pass — blur mosaics first and then blurs the mosaic, so it cannot be sharpened back — and fall back to a solid fill if Core Image cannot run, so a region the user asked to hide is never left readable. Their `RedactionSpec.strength` (0–1 in 0.25 steps, `RedactionStrength`) sets the mosaic block size: 0 is the fixed size PicStrip used before strength existed, so no setting is weaker than that, and the default 0.5 is stronger. Regions are grouped by style and strength, one Core Image pass per group.

**The editor previews the real thing.** `ZoomableImagePreview` draws every enabled region in the style it will be saved with, before any save. Solid and crosshatch are drawn in a `Canvas` with `RedactionLattice` — the same geometry the export uses. For pixelate and blur it asks `ImageRedactor.previewLayer` for a whole-image render at the export's block size and masks it to the regions, so the effect follows a box while it is dragged; layers are cached per style and block size and re-rendered when a drag ends. The preview image is capped at 2 400 px, so pixel-sized values are computed in export pixels and divided by `ScrubberViewModel.exportScale`. `testPreviewLayerMatchesTheExportInsideTheRegion` holds the preview to the export's pixels.

```swift
struct ImageRedactor {
    func redact(image: UIImage, specs: [RedactionSpec]) async -> UIImage?          // @concurrent
    func redact(image: UIImage, instances: [DetectedInstance]) async -> UIImage?  // solid black: batch + share extension
}
```

Bounding boxes stored in `DetectedInstance.boundingBox` are normalised SwiftUI coordinates (top-left origin, 0–1 range). The renderer multiplies them by `image.size` to get pixel-space coordinates. Runs in an async context (off the main thread) to avoid UI jank on large images.

---

### DetectionRegistry

**File:** `PicStripCore/DetectionRule.swift`

```swift
enum DetectionRegistry {
    nonisolated static let allRules: [DetectionRule]  // compiled once at first access
}
```

All `NSRegularExpression` objects are constructed in the `static let` initialiser — once per app process, never per scan. A `fatalError` fires during development if any pattern is invalid.

---

## Image Processing Deep Dive

### Why Two Passes?

A single-pass `CGImageDestinationAddImage` call still triggers the iOS JPEG/HEIC encoder to auto-synthesise a minimal EXIF block containing `ColorSpace`, `PixelXDimension`, `PixelYDimension`, and version strings. Passing empty `{}` dictionaries for `kCGImagePropertyExifDictionary` and `kCGImagePropertyTIFFDictionary` suppresses most of this, but not all — the encoder treats empty dicts as "nothing to merge" and still writes its own required fields.

The two-pass strategy defeats auto-synthesis reliably:

**Pass 1 — Pixel normalisation + compression**

```swift
// Orient pixels canonically (UIImage.normalized() redraws into a fresh CGContext)
guard let uiImage = UIImage(data: data),
      let cgImage = uiImage.normalized().cgImage else { ... }

// Encode with "hail-mary" empty dicts to zero out EXIF/TIFF as aggressively as possible
let encodeProps: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: quality,
    kCGImagePropertyExifDictionary: [:] as [CFString: Any],
    kCGImagePropertyTIFFDictionary: [:] as [CFString: Any]
]
CGImageDestinationAddImage(firstDest, cgImage, encodeProps)
CGImageDestinationFinalize(firstDest)  // → firstBuffer
```

**Pass 2 — Controlled metadata replacement**

```swift
// Build only the metadata the user chose to keep (plus Orientation = 1)
let outputMetadata = CGImageMetadataCreateMutable()
// Always inject orientation = 1 (pixels are already display-oriented)
// Re-inject any category/field the user chose to preserve via fieldOverrides

// Replace the entire metadata tree — MergeMetadata: false wipes everything
// that Pass 1 auto-synthesised
let copyOptions: [CFString: Any] = [
    kCGImageDestinationMetadata: outputMetadata,
    kCGImageDestinationMergeMetadata: false,
    kCGImageDestinationLossyCompressionQuality: quality
]
CGImageDestinationCopyImageSource(finalDest, cleanSource, copyOptions, &copyError)
```

**PNG output:** The `outputMetadata` object is left empty for PNG — PNG has no native EXIF/TIFF block, so re-injecting orientation metadata is unnecessary and produces a flatter, cleaner file.

### Metadata Re-injection (User-Kept Fields)

When a user disables a metadata category (or sets a per-field "keep" override), `ImageProcessor` re-injects those fields using `CGImageMetadata` XMP paths:

| ImageIO key | XMP namespace | Prefix |
|-------------|---------------|--------|
| `kCGImagePropertyGPSDictionary` | `http://ns.adobe.com/exif/1.0/gps/` | `exifGPS` |
| `kCGImagePropertyExifDictionary` | `kCGImageMetadataNamespaceExif` | `exif` |
| `kCGImagePropertyTIFFDictionary` | `kCGImageMetadataNamespaceTIFF` | `tiff` |
| `kCGImagePropertyIPTCDictionary` | `kCGImageMetadataNamespaceIPTCCore` | `Iptc4xmpCore` |
| EXIF Auxiliary | — | not writable via XMP |
| Apple Maker Note | — | not writable via XMP |

EXIF Auxiliary and Apple Maker Note cannot be re-injected through the XMP path API. If a user "keeps" one of these categories, the app reports the fields as stripped regardless.

Kept fields are written with `CGImageMetadataSetValueMatchingImageProperty`, which lets ImageIO pick the correct XMP type per property. Three things are worth knowing before touching this code:

- **Fractional numbers must be handed over as rational strings.** ImageIO reads EXIF rationals back as `Double` but *truncates* a fractional `NSNumber` on write (f/1.8 → 1, 1/125 s → 0, 12.5 m altitude → 12). `ImageProcessor.rationalString(for:)` converts them with a continued-fraction expansion ("9/5", "1/125"). GPS latitude/longitude (and the Dest variants) are the exception: ImageIO converts those from a plain `Double` itself and a rational string corrupts them.
- **Structural keys are never re-injected.** Pixels are rotated upright during pass 1, so writing the source's `TIFF.Orientation` back would rotate the saved photo a second time.
- **Some fields cannot be written back at all** (`TIFF.DateTime`, `TIFF.Software`, `TIFF.Artist`, the structured `EXIF.Flash`). After an encode the app therefore trusts the *output file*: `ScrubberViewModel.isRemoved(_:)` reports a field as removed when it is absent from `outputFileFields`, whatever the config asked for. The same rule makes PNG exports honest — PNG carries none of this metadata.

---

## PII Detection Engine

### PIIScanner Pipeline

```
scanImage(data:)
    │
    ├─ [Stage 1] Validate — CGImageSourceCreateWithData + CreateImageAtIndex
    │               ensures a meaningful error before Vision receives bad data
    │
    ├─ [Stage 2] Vision (Swift API) — one handler, one decode
    │   ImageRequestHandler(data)  ← raw Data, not CGImage, to preserve EXIF orientation
    │   performAll([RecognizeTextRequest, DetectFaceRectanglesRequest,
    │               DetectBarcodesRequest, DetectRectanglesRequest])
    │     RecognizeTextRequest
    │       .recognitionLevel = .accurate
    │       .usesLanguageCorrection = false  ← preserve raw credential characters
    │       .automaticallyDetectsLanguage = true
    │   → each request reports its own result or `.error`; one failure never
    │     discards the others (the variadic `perform` would throw for all of them)
    │
    │   If no text → retry with a fresh handler at .fast level
    │   If neither OCR pass produced a result → throw textRecognitionFailed
    │
    └─ [Stage 3] Per-observation analysis
        for each observation:
            ├─ Coordinate flip: Vision bottom-left → SwiftUI top-left
            │     flippedY = 1 - originY - height
            │
            ├─ [Stage B] DetectionRegistry regex sweep  (runs FIRST)
            │     for each rule in allRules:
            │         regex.matches(in: text)
            │         → record(type, baseScore, ocrConfidence, instance)
            │     Tight substring box via candidate.boundingBox(for: swiftRange)
            │     Falls back to observation-level box if API returns nil
            │
            ├─ [Stage A] NSDataDetector  (runs AFTER regex)
            │     Types: .phoneNumber, .address, .link (mailto: → .email)
            │     record() will NOT downgrade a stronger score already set
            │     by the regex pass for overlapping types (e.g., email)
            │
            └─ Orphan-label heuristic
                If neither stage matched AND observation matches bare credential
                keyword ("password:", "login:", garbled OCR variants):
                    stash label → treat NEXT observation as the password value
                    record(.unstructuredCredential, baseScore: 0.65)
```

### Scoring

```
instanceScore = baseScore × ocrConfidence

baseScore:  calibrated per rule (see table below)
            reflects pattern specificity — how likely a match is to be a true positive
ocrConfidence: Vision's per-candidate float (0.0–1.0)
               reflects OCR certainty — how reliably Vision read those characters

result-level score: upgraded when a later match for the same type is stronger
                    ensures the regex pass (higher baseScores) wins over NSDataDetector
                    for overlapping types such as email
```

### PII Type Catalog

All 31 types, by risk tier. Risk is an editorial property of the type and never changes with confidence.

| Risk | Type | Detection |
|------|------|-----------|
| **Critical** | Social Security Number | Regex (`XXX-XX-XXXX`) |
| **Critical** | National Insurance Number | Regex |
| **Critical** | Government ID | Regex (CA SIN, IN PAN/Aadhaar, ES DNI/NIE, BR CPF, DE Steuer-ID, IT Codice Fiscale, FR INSEE, JP My Number, KR RRN, CN Resident ID, PL PESEL, MX CURP, US ITIN/EIN/MBI, US passport, state driver-licence formats) |
| **Critical** | Credit Card Number | Regex + Luhn check |
| **Critical** | AWS Access Key, GitHub Token, Google API Key, OpenAI API Key, Slack Token, Stripe Key | Regex (one type each) |
| **Critical** | Private Key | Regex (PEM header) |
| **Critical** | JWT Token | Regex (double `eyJ` header) |
| **Critical** | Developer Secret | Regex (Anthropic, GitLab PAT, npm, HuggingFace, DigitalOcean, Twilio, SendGrid, Discord) |
| **Critical** | Database Connection String | Regex (inline credentials in a URI) |
| **High** | Face | Vision `DetectFaceRectanglesRequest` |
| **High** | IBAN | Regex + mod-97 check |
| **High** | ABA Routing Number, SWIFT / BIC Code | Regex, keyword-anchored |
| **High** | Physical Credential / Password | Regex (label + value) and a cross-line heuristic |
| **Medium** | Email Address | Regex + `NSDataDetector` |
| **Medium** | Phone Number, Address | `NSDataDetector` |
| **Medium** | Crypto Wallet Address | Regex |
| **Medium** | Vehicle Identification Number | Regex (17 characters, no I/O/Q) + check digit |
| **Medium** | License Plate Number | Regex (structural + keyword-anchored) |
| **Medium** | MAC Address, IP Address | Regex |
| **Low** | Date of Birth | Regex, keyword-anchored (DOB / Born / Birthday) |
| **Low** | Link / URL | `NSDataDetector` |
| **Low** | QR Code / Barcode | Vision `DetectBarcodesRequest` |
| **Low** | Name | Apple's on-device language model (app only, Apple Intelligence; listed but not redacted by default) |

The full rule set is `DetectionRegistry.build()` (60 rules). Representative base scores, to show the calibration bands:

| Type | Detection | Base score |
|------|-----------|------------|
| AWS Access Key / Google API Key | Regex | 0.98 |
| GitHub, OpenAI, Slack, Stripe keys | Regex | 0.97 |
| Private Key (PEM) | Regex | 0.96 |
| Social Security Number, Credit Card (compact) | Regex | 0.94 |
| Email Address, IBAN | Regex | 0.93 |
| IP Address (IPv4) | Regex | 0.90 |
| Date of Birth (keyword-anchored) | Regex | 0.85 |
| Credit Card (spaced/dashed) | Regex | 0.80 |
| Email via `mailto:` link | `NSDataDetector` | 0.75 |
| Phone Number | `NSDataDetector` | 0.72 |
| Address | `NSDataDetector` | 0.68 |
| Physical Credential (label + value on one line) | Regex | 0.68 |
| Physical Credential (value on the next line) | Cross-line heuristic | 0.65 |
| Name | On-device language model | 0.62 |
| Link / URL | `NSDataDetector` | 0.52 |

**Why `usesLanguageCorrection = false`:** Vision's language correction normalises "AIzaSy..." into dictionary words. Disabled to preserve raw credential characters.

**Why `.accurate` first with `.fast` fallback:** The Neural Engine is unavailable in the simulator; the `.accurate` model returns zero observations on simulator CPU paths. The retry uses a fresh `ImageRequestHandler`.

**Face detector revision:** a default-initialised `DetectFaceRectanglesRequest` still resolves to revision 3 on iOS 27, so revision 4 is requested by name — on devices only (it is unimplemented in the simulator) and behind `#if compiler(>=6.4)` + `#available(iOS 27, *)`. If it errors, `scanImage` retries face detection with the default revision so a face is never silently missed.

### Duplicate Detection

`DetectedInstance` conforms to `Equatable` on `(snippet, boundingBox)`. When both the regex pass and `NSDataDetector` fire on the same text span, `record()` silently drops the duplicate and only upgrades the score if the new instance is stronger.

---

## Share Extension

### Architecture

```
ShareViewController (UIKit — UIViewController)
    │
    └─ UIHostingController<ExtensionConfigView>
           │
           └─ ExtensionConfigView (SwiftUI, private)
                  └─ observes ExtensionViewModel (@Observable)
                         phase: .configuring | .processing
```

`ExtensionViewModel` is a minimal two-phase state machine. The full processing pipeline lives in `ShareViewController.runProcessingPipeline()`.

### Processing Pipeline (Extension)

```
User taps "Process & Save to Photos"
    ↓
ShareViewController.runProcessingPipeline(stripMetadata:redactPII:)
    │
    ├─ Request PHPhotoLibrary .addOnly authorization
    │
    └─ for each NSItemProvider (sequential):
          ├─ Resolve best concrete UTI
          │     preferredTypes: [jpeg, png, heic, com.apple.heic, rawImage, public.image]
          │     Photos only registers concrete types; "public.image" abstract causes
          │     loadDataRepresentation to silently drop its callback
          │
          ├─ Load raw Data via continuation bridge
          │
          ├─ Optional: PIIScanner().scanImage(data:) → redact with ImageRedactor
          │
          ├─ Optional: ImageProcessor.process(data:preset:config:)
          │     or      ImageProcessor.process(image:sourceData:preset:config:)
          │
          └─ PHPhotoLibrary.shared().performChanges {
                 PHAssetCreationRequest.forAsset()
                     .addResource(with: .photo, data: finalData)
             }
    ↓
extensionContext?.completeRequest(returningItems: [])
```

### Shared Core Without a Framework Target

iOS extensions are separate processes. An extension binary cannot dynamically link to the `.app` binary's code, so PicStrip keeps shared processing code in `PicStripCore/` and compiles those same source files into both targets. This avoids duplicate source files while also avoiding a new binary framework build phase.

`ExportFormat+AppEnum.swift` remains app-only because it imports `AppIntents`. The extension uses the shared `ExportPreset` directly.

### 120 MB Memory Ceiling

iOS kills extension processes that exceed ~120 MB without warning. Mitigations:

- Images are processed sequentially — never concurrently.
- `UIImage` and `Data` references are released immediately after each encode.
- The extension saves directly to Photos (no in-memory accumulation of processed images).

---

## App Intent & Siri

### `StripImageIntent` — foreground, opens the picker

**File:** `PicStrip/StripImageIntent.swift`

```swift
struct StripImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Photos with PicStrip"
    static let supportedModes: IntentModes = .foreground(.immediate)   // replaces openAppWhenRun (deprecated iOS 26)

    @AppDependency private var router: IntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestBatchPicker()
        return .result()
    }
}
```

The intent runs in the foreground app process, so it talks to the UI through `IntentRouter` (`@Observable @MainActor`, registered with `AppDependencyManager` in `PicStripApp.init()`):

1. `perform()` sets `isBatchPickerRequested`.
2. `ContentView` observes it with `.onChange(..., initial: true)` — `initial` covers a cold launch, where the intent has already run before the view exists — presents the multi-photo picker and clears the request.

This replaced an App Group `UserDefaults` flag that was only read on a `scenePhase → .active` transition. Running the shortcut while PicStrip was already frontmost never produced that transition, so the flag went stale and opened the picker at some later, unrelated launch.

Siri phrase registered: `"Clean photos with PicStrip"`. Also appears in the Shortcuts app and Spotlight.

### `StripMetadataIntent` — background, files in → files out

**File:** `PicStrip/StripMetadataIntent.swift`

Takes `[IntentFile]` (`supportedContentTypes: [.image]`) plus an `ExportFormat`, strips metadata with `ImageProcessor`, and returns clean `[IntentFile]`s for the next Shortcuts step. `supportedModes = .background`; on iOS 27 it conforms to `LongRunningIntent` and runs inside `performBackgroundTask` so a large selection can outlast the normal intent time limit.

It is deliberately **metadata only** — no OCR (what previously exceeded the background memory ceiling) and no photo-library writes (a background intent cannot present the authorization prompt). It fails closed: one unreadable or undecodable file fails the whole run.

The `images` parameter declares `inputConnectionBehavior: .connectToPreviousIntentResult`. That is what makes it the action's *input*: without it Shortcuts never wires the previous action's output into the parameter and the intent runs with no images.

**Verified end to end in the iOS 27 simulator** (Shortcuts app, not just unit tests):

| Shortcut | Input | Result |
|----------|-------|--------|
| Select Photos → Strip Metadata from Images → Save to Photos | 2.8 MB HEIC with GPS, 32 EXIF keys, MakerApple | Saved HEIC holds only structural keys |
| Same | JPEGs with GPS/EXIF/IPTC | Saved JPEGs clean |
| Get Latest Photos → Strip Metadata from Images *as PNG* → Save to Photos | JPEG (Nikon, GPS, IPTC) | Saved PNG, no metadata |

Photos-backed `IntentFile`s arrived with non-empty `data` and a `fileURL` inside the Shortcuts runner's temp directory; the `fileURL` fallback in `readData(of:)` stays as a guard because earlier OS versions were seen returning empty `data`.

Known quirks, none of them in PicStrip's code:

- **iOS 27 beta runtime (24A5355p) drops the Export Format choice.** The runner logs the chosen case but App Intents resolves the enum to `nil` (`AppEnum case "to-0.0" was not found`), so the intent runs with the default, *Match Original*. Metadata is still stripped — only the conversion is skipped. The release runtime (24A434) delivers the value correctly.
- In the simulator `performBackgroundTask` logs `BGTaskScheduler is not available on this platform` and then runs the work anyway.
- Still worth one pass on a physical device before release: `LongRunningIntent` scheduling and a large (50+) selection can only be exercised there.

---

## Persistence Model

| Data | Storage | Key | Scope |
|------|---------|-----|-------|
| "Edit in PicStrip" hand-off | App Group container (`group.com.northcutt.PicStrip`) | `pending-edit.data` | Until the app next becomes active; written with complete file protection, deleted before loading |
| Audit JSON | `FileManager.default.temporaryDirectory` | `PicStrip_Audit_<UUID>.json` | Session |
| Batch audit JSON | `FileManager.default.temporaryDirectory` | `PicStrip_BatchAudit_<UUID>.json` | Session |

No photo metadata, no detection results and no user preferences are ever persisted; the app does not use `UserDefaults` at all (and its privacy manifest no longer declares it). This is intentional — nothing about which photos were processed or what PII was found survives a session.

---

## Privacy & Security

### PrivacyInfo.xcprivacy

Both the main app and share extension declare:

```xml
<key>NSPrivacyTracking</key><false/>
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyTrackingDomains</key><array/>
```

Zero data collection. No analytics, no crash reporting, no telemetry.

### Required-Reason APIs

| API category | Reason code | Why |
|-------------|-------------|-----|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | ImageIO reads file timestamps during metadata extraction — not for fingerprinting |

All other frameworks (Vision for OCR, Photos for saving, ImageIO for encoding) do not trigger required-reason APIs.

### Permissions

| Permission | Level | When |
|-----------|-------|------|
| `NSPhotoLibraryAddUsageDescription` | Add-only | Saving a new cleaned asset |
| `NSPhotoLibraryUsageDescription` | Read + write | "Replace Original" — needs read access to delete the source asset |
| `NSCameraUsageDescription` | Camera | First tap on "Take Photo" or "Scan Document" |

The app defaults to `.addOnly` authorization. Users must explicitly grant read+write if they want "Replace Original."

### On-Device Processing Guarantee

```
UIImage(data:)          native iOS — no network
CGImageSourceCreateWithData  ImageIO — native iOS
RecognizeTextRequest    Vision — on-device model, no network
PIIScanner.liveBoxes    Vision on camera frames — in memory, never stored
SystemLanguageModel     FoundationModels — on-device only; never Private Cloud Compute
NSRegularExpression     Foundation — native iOS
UIGraphicsImageRenderer CoreGraphics — native iOS
CGImageDestinationCopyImageSource  ImageIO — native iOS
PHPhotoLibrary.performChanges       Photos — native iOS
```

PicStrip has no server and makes no network request of its own. The single exception is iOS downloading Apple's object-selection model on request (`ObjectSegmenter.downloadModel()`), which only `downloadObjectModelAndContinue()` — the consent alert's Download button — can trigger. Nothing about a photo is ever transmitted.

---

## CI/CD Pipeline

The [release operations guide](docs/release-pipeline.md) describes the job graph, exact Xcode/Ruby pins, environment and repository controls, evidence format, deployment retries, screenshot PR workflow, and rollout commands.

`pr.yml` reports the always-running **CI Gate**. The release platform's reusable `ci.yml` (the `qa` job in `pr.yml` and `main.yml`) shares SwiftLint (plus the string catalog audit), analysis, and the iOS 27 / iOS 26 test jobs between PRs and releases. `main.yml` runs signed archive creation, QA, and packaging concurrently after read-only version analysis. Upload and immutable publication require complete verified evidence. `app-store-deploy.yml` stages published releases, then waits for production approval and checks the exact App Store build before submission. `metadata-only.yml` uses that same submission gate.

## SLSA Build Provenance Level 3

The pipeline targets SLSA Build L3 for the GitHub-produced IPA using the isolated upstream generator, authenticated manifests, and verification before every distribution handoff. This claim excludes Apple's re-signed, encrypted, or thinned installed binary. Native attestations complement the isolated provenance; they do not independently establish Build L3.

See the [control coverage, trust limits, and verification commands](docs/release-pipeline.md#slsa-build-l3-scope). Live repository controls and the candidate rollout must be verified before describing this target as deployed.

---

## Localization

PicStrip localizes user-facing text through Apple string catalogs (English + 16 localizations; Spanish ships as `es` for Spain and `es-419` for Latin America):

- `PicStrip/Localizable.xcstrings` — app, share extension, processing, errors, and accessibility copy
- `PicStrip/AppShortcuts.xcstrings` — App Shortcut phrases that Siri and Spotlight expose
- `PicStrip/InfoPlist.xcstrings`, `PicStripShareExtension/InfoPlist.xcstrings` — photo-library and camera permission prompts and the share-sheet action name ("Clean with PicStrip")
- `fastlane/MarketingHeadlines.xcstrings` — App Store screenshot headline copy (5 keys × 16 locales; `es-MX` falls back to `es`). Read by `scripts/process_screenshots.py` at compose time.

**Translations are LLM-generated.** English is the canonical source; catalogs and `fastlane/metadata/<locale>/` entries are filled in from there. If a translation reads off, edit it inline in the matching catalog or `.txt` file — every locale is editable directly without round-tripping through a translator.

### Rules that keep strings translatable

A missing translation is not a build error — the app silently shows English — so these are enforced by `scripts/audit_xcstrings.py` and `LocalizationTests`, not by the compiler.

| Rule | Why |
|------|-----|
| A string literal only reaches the catalog when its type is `LocalizedStringKey`, `LocalizedStringResource` or `String(localized:)`. A `String` property or parameter (`let detail: String`, `title: String`) shown through `Text(variable)` is **never extracted** and stays English everywhere. | The About screen shipped ~45 English-only strings this way. |
| Never wrap a variable in `LocalizedStringKey(variable)` to "localize" it. | It hides the literal from extraction and does a second lookup on already-localized text. |
| Never assemble a sentence from fragments (`"\(title) \(category) fields"`, `name + ", selected"`). Pass the whole sentence; use accessibility traits for state. | Word order and agreement differ per language. |
| `^[\(n) photo](inflect: true)` is for the **English source only**. Every other locale uses plural variations in the catalog (`one`/`other`, Polish `one/few/many/other`, Arabic all six). | The grammar engine ignores most languages: Polish showed "5 pole". |
| A plural string with a second argument uses an explicit substitution (`%#@instances@` + `argNum`). | Xcode cannot infer which argument drives the plural. |
| One key = one meaning. "High" as a *confidence* band and "High" as a *risk* level are different keys (`ConfidenceLevel.high` vs `High`). | They take different grammatical gender in French, Spanish, Polish, Arabic… |
| Metadata category identifiers (`"GPS"`, `"Apple Maker Note"`) are never shown directly; views call `metadataCategoryDisplayName(for:)`. | The identifier doubles as a `StripConfig` key and must not change. |

### Glossary senses translators must respect

*scan* = analyse a photo for sensitive content — except in "Scan Document", which is capturing paper with the camera and takes each locale's Apple term for document scanning; *redact* = cover part of the picture (never the editorial "edit/write" family: *rédaction*, *redactar*, 編集…); *region* = an area of the image (never a territory); *strip* = remove metadata; *field* = one metadata entry. Platform terms follow Apple's localized iOS (German "Sichern", Dutch "Bewaar", Polish "Zachowaj", Simplified Chinese "存储").

The term each locale uses for these concepts is recorded in [`docs/localization-glossary.md`](docs/localization-glossary.md). New and changed strings must reuse those terms.

### Commands

```bash
# Hard-coded-string audit + catalog audit (coverage, placeholders, plural categories, inflect misuse).
make audit-localization

# Also prove that every string in the code is in the catalog and nothing in the catalog is dead.
xcodebuild build -project PicStrip.xcodeproj -scheme PicStrip \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/loc \
  CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES
scripts/audit_xcstrings.py --stringsdata build/loc

# Validate JSON shape, both audits, and SwiftLint after edits.
make localization-validate

# Export .xcloc bundles for handoff to a human translator.
make localization-export
```

**Pseudo-localization is available for layout smoke testing.** `scripts/translate_xcstrings.js --languages es fr de` writes `[<lang>] <source>` strings into the missing slots so the UI can be exercised against longer strings, RTL mirroring, and accent-rich glyphs before the real translations land. These pseudo entries must be replaced with real translations before release (`make audit-localization` does not tell them apart from real ones).

```bash
# See what's missing in a catalog without writing.
scripts/translate_xcstrings.js --languages es fr --dry-run

# Pseudo-localize a single catalog for layout smoke testing.
make localization-pseudo LANGUAGES="es"
```

To preview a locale without changing the simulator's language:

```bash
xcrun simctl launch booted com.northcutt.PicStrip -AppleLanguages "(pl)" -AppleLocale pl_PL
```

Do not skip review for App Shortcut phrases, permission prompts, privacy explanations, or redaction/security terms. Those strings carry product trust, and literal machine translations can sound harsher or less precise than intended.

---

## Contributing: Adding a New PII Type

### Step 1 — Define the type

Add a case to `PIIType.swift`:

```swift
enum PIIType: String, Hashable, Identifiable, CaseIterable {
    // ... existing cases ...

    // MARK: - Financial
    case bankRoutingNumber  // new

    nonisolated var description: String {
        switch self {
        // ...
        case .bankRoutingNumber: return "Bank Routing Number"
        }
    }
}
```

### Step 2 — Add a detection rule

In `DetectionRule.swift` (inside the `build()` function):

```swift
// US routing numbers: exactly 9 digits, common in financial docs
rule(.bankRoutingNumber,
     #"\b\d{9}\b"#,
     0.70)
```

Choose a `baseScore` that reflects how many false positives the pattern is likely to produce:
- `≥ 0.95` — globally unique prefix (AWS key, GitHub token)
- `0.85–0.94` — strong structure (SSN, credit card, IBAN)
- `0.70–0.84` — good structure but ambiguous in some contexts
- `0.50–0.69` — heuristic / contextual; use sparingly

### Step 3 — Update AboutView (optional)

`AboutView.swift` contains a static PII catalogue displayed in the app's About screen. Add a row for the new type if it should be visible to users.

### Step 4 — Write tests

In `PicStripTests/PIIScannerTests.swift`:

```swift
func testDetectsBankRoutingNumber() async throws {
    let image = try createTestImage(withText: "Routing: 021000021")
    let results = try await PIIScanner().scanImage(data: image)
    let hit = try XCTUnwrap(results.first { $0.type == .bankRoutingNumber })
    XCTAssertGreaterThan(hit.score, 0.6)
    XCTAssertFalse(hit.instances.isEmpty)
}
```

### Step 5 — Test end-to-end

1. `bundle exec fastlane test` — verify the new test passes in the unit test suite.
2. Run the app; open a photo containing a routing number.
3. Confirm the red overlay lands on the correct region.
4. Toggle redaction; confirm the black box covers the number in the saved image.
5. Check the audit JSON — the new type should appear under `visualRedactions`.

---

## Known Constraints

### Structural Metadata Cannot Be Stripped

The iOS JPEG/HEIC encoder unconditionally re-synthesises structural rendering fields regardless of what `CGImageDestinationCopyImageSource` is asked to omit. The UI marks these with a lock icon. Do not attempt to remove the two-pass logic in hopes of stripping them — it will not work and will introduce correctness regressions.

### Two-Pass Encoding Overhead

The two-pass strategy adds ~50–100 ms to export time on current hardware. This is not optimisable without breaking the privacy guarantee. Profile with Instruments before proposing changes.

### Share Extension Memory Ceiling

iOS kills extension processes at ~120 MB without warning. The sequential processing model and explicit deallocation between images are not optional micro-optimisations — they are the budget constraint. Do not introduce concurrent image processing inside the extension.

### OCR Language Correction Must Stay Disabled

`RecognizeTextRequest.usesLanguageCorrection = true` normalises OCR output toward dictionary words. For credentials (`AIzaSyD...`, `sk-live-...`, `AKIAIOSFODNN7EXAMPLE`) this destroys the pattern structure the regex rules depend on. It must remain `false`.

### Use `performAll`, Not the Variadic `perform`

`ImageRequestHandler.perform(a, b, c)` throws if *any* request fails, discarding the results of the ones that succeeded — rectangle detection failing on the simulator would take OCR down with it. `performAll` reports each request separately. The `.fast` OCR retry and the default-revision face retry each create a fresh handler.

### PhotoKit Change Blocks Live in `PhotoLibraryWriter` Only

`PHPhotoLibrary.performChanges` runs its block on PhotoKit's own serial queue. A closure written inside a `@MainActor` type — the view model, the share extension's view controller, anything in the app target, which is `MainActor` by default — is inferred `@MainActor`, and Swift 6 asserts that at run time: the app traps the moment PhotoKit calls the block. It compiles cleanly and no unit test sees it, because only a real save reaches PhotoKit. `PicStripCore/PhotoLibraryWriter.swift` is `nonisolated`, so its block is too. A SwiftLint rule (`photo_library_change_block`) fails the build if `performChanges` appears anywhere else, and `testSaveAsNewPhotoReachesThePhotoLibrary` (UI tests) does a real save on the simulator. The same trap applies to any framework callback that is not `@Sendable` and runs off the main thread.

### Batch Processing Must Remain Sequential

Concurrent batch processing would require holding multiple decoded `UIImage` objects in memory simultaneously. On a device processing ten 12 MP photos, this exceeds available memory. The sequential loop with explicit `nil` assignments is not defensive programming overhead — it is the memory model.

### The Language Model Is On-Device Only, and Not Trusted

`SemanticPII` uses `SystemLanguageModel` and nothing else. `PrivateCloudComputeLanguageModel` exists in the iOS 27 SDK and must never be used here: it would send recognised text off the device and void every on-device claim the app makes. The model's output is treated as a hint — `SemanticPIIMerger` keeps a name only if the line index exists and the line really contains that text, and takes the box from Vision's character geometry, so a hallucination cannot put a box on the image. Names are `isRedactedByDefault == false`; batch burns only default-redacted types, and batch and the share extension do not run the model at all. The pass runs *after* the scan has been published (`startNameScan`), so neither the editor nor a save ever waits for the model; its findings are added with `appendDetections`, which leaves every existing region — and the undo history — as the user has it. It is capped at 12 s and the model is prewarmed at launch (≈2 s warm, ≈6 s cold on the simulator). `PICSTRIP_DISABLE_NAME_DETECTION=1` switches it off for UI tests and screenshots, which must be deterministic.

### The Live Viewfinder Is Advisory

`PIIScanner.liveBoxes(in:)` runs on camera frames for the viewfinder's boxes only: one frame at a time, at most every 0.35 s (`AnalysisThrottle`), paused while the thermal state is serious or critical. The captured photo is scanned again by the full pipeline, so nothing in the editor depends on what the viewfinder showed. Frames are never stored. It uses accurate OCR — the fast model garbles the digits the pattern rules need (and reads nothing on the simulator) — so tune the interval, not the level, if a device runs hot. If the capture session cannot be configured, `LiveCameraView` reports `.unavailable` and the system camera (`CameraCaptureView`) is presented instead.

### The Object-Selection Model Is Never Downloaded Unasked

Tap-to-redact uses `GenerateIterativeSegmentationRequest` (iOS 27), whose model is an asset the OS downloads from Apple on request (`assetStatus` / `downloadAssets()`); it cannot be bundled. It is the only thing in the app that can cause a network transfer, so `ScrubberViewModel.selectObject(at:)` never calls `downloadModel` itself: a `.needsDownload` status raises the consent alert, and only `downloadObjectModelAndContinue()` — the alert's "Download" button — fetches it. Keep that property when touching this code; `ObjectSelectionFlowTests` pins it. Regions are rectangles, so the mask is reduced to its bounding box (`SegmentationMask.boundingBox`), and a mask covering almost the whole image is rejected as "the background".

### Marketing Screenshots Live in Git LFS

`fastlane/screenshots/processed/**/*.png` is tracked by Git LFS (`.gitattributes`). Run `git lfs install` once per clone — without it git stores the PNGs as ordinary blobs and the attribute does nothing, which is how the repository's pack grew to a gigabyte before September 2026. Building and testing the app never needs these files, so a clone without LFS still works. The release platform's packaging job checks out with `lfs: true` and rejects LFS pointer files, so any new workflow that reads the screenshots must do the same. Commits from before the conversion still carry the PNGs as blobs; shrinking that history would mean rewriting `main`.

### Captured Pages Are Encoded Lazily

A document scan is held as a `VNDocumentCameraScan` and each page is turned into bytes only when the pipeline asks for it. Extracting every page up front would hold one decoded bitmap per page (tens of megabytes each) for the life of the batch.

### Scans Get the Document Boost From a Hint, Not a Rectangle

The document camera crops to the page edges, so `DetectRectanglesRequest` rarely finds a quad inside a scan. `ScanHints.scannedDocument` supplies the boost instead: `ScannedDocument.pages` sets it, and `scan(data:hints:)` scores the whole frame as the document — using the image's real aspect ratio — without turning it into a redaction instance. Do not "fix" a missing rectangle by injecting a full-frame one: `applyDocumentContext` would turn it into a region and black out the whole page.
