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
13. [Localization Automation](#localization-automation)
14. [Contributing: Adding a New PII Type](#contributing-adding-a-new-pii-type)
15. [Known Constraints](#known-constraints)

---

## Project Structure

```
PicStrip/
├── PicStrip.xcodeproj/
├── README.md
├── DEVELOPMENT.md              # this file
├── PRIVACY.md
├── CHANGELOG.md
├── LICENSE
├── .swiftlint.yml
├── .releaserc.json             # semantic-release config
├── .ruby-version               # Ruby version pin for rbenv
├── Gemfile                     # gem "fastlane", "~> 2.233"
├── Gemfile.lock
├── package.json                # semantic-release + plugins
├── package-lock.json
│
├── .github/workflows/
│   ├── pr.yml                  # PR checks: lint, analyze, test
│   ├── main.yml                # Release pipeline (7 jobs)
│   └── screenshots.yml         # Manual: App Store screenshot capture
│
├── fastlane/
│   ├── Fastfile                # Lane definitions
│   ├── Snapfile                # Screenshot capture config (devices + 16 locales)
│   ├── MarketingHeadlines.xcstrings  # Localized headline copy used by the marketing compositor
│   ├── accessibility_declarations.json  # App Store Accessibility Nutrition Label config
│   ├── screenshots/
│   │   ├── manifest.json       # Expected raw-capture filename inventory
│   │   ├── <locale>/           # Raw captures, one folder per locale
│   │   └── processed/          # Final marketing PNGs (Git LFS) — uploaded to App Store Connect
│   └── metadata/               # App Store metadata (title, description, keywords, release notes)
│
├── scripts/                    # Utility scripts (release notes, localization, screenshot compositor)
│   ├── process_screenshots.py  # Marketing screenshot compositor (custom frame + brand bg + headline)
│   ├── make_fixture.py         # Regenerates the OCR test fixture (PicStripUITests/test_list.png)
│   ├── requirements.txt        # Pillow, arabic-reshaper, python-bidi
│   ├── translate_xcstrings.js  # Pseudo-localizer for layout smoke testing
│   ├── audit_localization_strings.sh  # Flags string-returning literals that should be localized
│   └── write_release_notes.sh  # Generates fastlane/metadata/en-US/release_notes.txt at release time
│
├── docs/
│   ├── icons/                  # Generated app icon variants (Default, Dark, Tinted)
│   └── marketing/              # App Store marketing copy + index
│
├── PicStripCore/               # Shared pure processing/domain source files
│   ├── ImageProcessor.swift    # Stateless enum; two-pass ImageIO metadata stripping
│   ├── PIIScanner.swift        # Stateless struct; async Vision OCR + rule matching
│   ├── ImageRedactor.swift     # Stateless struct; UIGraphicsImageRenderer redaction
│   ├── DetectionModels.swift   # DetectionResult / DetectedInstance / confidence models
│   ├── DetectionRule.swift     # DetectionRule struct + DetectionRegistry enum
│   ├── PIIType.swift           # 20-case enum (Contact, Web, Identity, Financial, Developer Secrets, Unstructured)
│   └── ExportPreset.swift      # ExportPreset enum (losslessPNG, jpeg, heic, matchSource)
│
├── PicStrip/                   # Main app target (iOS 17+, Swift 5.9)
│   ├── PicStripApp.swift       # @main entry point
│   ├── ContentView.swift       # Root SwiftUI view; owns PhotosPicker + batch sheet
│   ├── ScrubberViewModel.swift # @Observable @MainActor; owns the full data-flow pipeline
│   ├── AuditReport.swift       # Codable structs: AuditReport, BatchAuditReport, RedactionReport
│   ├── ExportFormat.swift      # ExportFormat enum (user-facing)
│   ├── ExportFormat+AppEnum.swift  # AppIntents conformance — main app only
│   ├── AboutView.swift         # PII catalogue + metadata category entries
│   ├── PreSaveReviewView.swift # Final review screen; permanent-removal warning
│   ├── StripImageIntent.swift  # AppIntent for Siri / Shortcuts
│   └── PrivacyInfo.xcprivacy  # Zero-data-collection privacy manifest
│
├── PicStripShareExtension/     # Share Extension target (separate binary)
│   ├── ShareViewController.swift    # UIKit host; embeds ExtensionConfigView via UIHostingController
│   └── PrivacyInfo.xcprivacy       # Independent privacy manifest
│
├── PicStripTests/              # Unit tests
│   ├── PIIScannerTests.swift
│   ├── ImageProcessorTests.swift
│   └── DetectionRegistryTests.swift
│
└── PicStripUITests/            # UI / screenshot tests
    ├── PicStripUITests.swift   # Single testAllScreenshots() method
    └── SnapshotHelper.swift    # Fastlane snapshot helpers (@MainActor)
```

**Key notes:**

- `PicStripCore/` files are compiled directly into both the main app and the share extension. This keeps one source of truth without adding a binary framework target.
- `ExportFormat+AppEnum.swift` is compiled **only in the main app target** because it imports `AppIntents`, which is not needed in extensions.
- Both targets have independent `PrivacyInfo.xcprivacy` declarations.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set in both Debug and Release build configurations of the `PicStrip` target.

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
│  CoreGraphics · UIKit · SwiftUI                     │
└─────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Stateless services (no instances) | Photo processing is a pure function of inputs; no mutable service state needed |
| Two-pass ImageIO | Single-pass re-encode still triggers iOS auto-synthesis of EXIF; two-pass defeats it |
| `VNImageRequestHandler(data:)` instead of `(cgImage:)` | Preserves EXIF orientation so bounding boxes land on the correct pixels |
| Downsampled UI previews | The app keeps full-resolution bytes for export, but decodes display/review previews to bounded images to reduce RAM |
| Off-main image processing | Metadata encode/decode and review preview generation run off the MainActor; the view model only publishes final state |
| Sequential batch processing | Prevents OOM by keeping peak memory at ~one image at a time |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | Eliminates `@MainActor` annotation noise on view-layer types |
| Static detector caches | Compiles regexes once and reuses the native `NSDataDetector` across scans |
| No Core Data / SwiftData | Metadata is ephemeral; only lifetime stats need persistence (UserDefaults) |
| App Group for Shortcuts IPC | Single boolean flag from the AppIntent to trigger batch picker |

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
    ├─ Scan (async, Task.detached):
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
    ├─ Update lifetime stats in UserDefaults
    ├─ Generate AuditReport JSON → FileManager.tmp
    └─ Dismiss sheet → home screen
```

### Batch-Photo Flow

```
User taps "Pick Multiple" (or Shortcut fires StripImageIntent)
    ↓
ContentView presents BatchConfigView (stripMetadata, redactPII, outputFormat, saveMode)
    ↓
ScrubberViewModel.processBatch(items, config)
    ├─ for each PhotosPickerItem (sequential — never concurrent):
    │     ├─ Load: PhotosPickerItem → Data
    │     ├─ Decode: UIImage(data:)
    │     ├─ Scan: PIIScanner.scanImage(data:)
    │     ├─ Optional: ImageRedactor.redact()
    │     ├─ Strip: ImageProcessor.process(image:sourceData:preset:config:)
    │     ├─ Save: PHPhotoLibrary.performChanges
    │     ├─ Append to batchReports only after Photos accepts the write
    │     ├─ Explicit nil of Data + UIImage (ARC pressure relief)
    │     └─ @MainActor progress update
    └─ Generate BatchAuditReport JSON
    ↓
BatchSummaryView shows total processed, errors, and downloadable audit JSON
```

### Data Ownership

| Data | Owner | Lifetime |
|------|-------|----------|
| `sourceUIImage: UIImage?` | ScrubberViewModel | Downsampled display preview for the single-photo session |
| `processedData: Data?` | ScrubberViewModel | Set during pre-save prep; nil'd on dismiss |
| `processedPreviewUIImage: UIImage?` | ScrubberViewModel | Downsampled decoded preview of processed bytes; avoids repeated Data decoding |
| `detectionResults: [DetectionResult]` | ScrubberViewModel | Single-photo session |
| `pendingStrippedMetadata: StrippedMetadata?` | ScrubberViewModel | Single-photo session |
| `stripConfig: StripConfig` | ScrubberViewModel | Per-session; persists across format changes |
| `outputFileFields: [MetadataField]` | ScrubberViewModel | Set after each encode pass |
| Lifetime stats | `UserDefaults.standard` | App lifetime |
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

- Root level: `PixelWidth`, `PixelHeight`, `ColorModel`, `Depth`, `Orientation`, `ProfileName`, `DPIWidth`, `DPIHeight`, `FileSize`
- TIFF dict: `Orientation`, `XResolution`, `YResolution`, `ResolutionUnit`
- EXIF dict: `ColorSpace`, `PixelXDimension`, `PixelYDimension`, `ExifVersion`, `FlashPixVersion`, `ComponentsConfiguration`

The UI marks these with a lock icon and explains they contain no personal data.

---

### PIIScanner

**File:** `PicStripCore/PIIScanner.swift`

A **stateless struct** that runs async Vision OCR followed by layered rule matching.

```swift
struct PIIScanner {
    func scanImage(data: Data) async throws -> [DetectionResult]
}
```

The method offloads all CPU work to `Task.detached(priority: .userInitiated)`. See [PII Detection Engine](#pii-detection-engine) for the full pipeline.

---

### ImageRedactor

**File:** `PicStripCore/ImageRedactor.swift`

Burns opaque black rectangles over detected PII instances using `UIGraphicsImageRenderer`.

```swift
struct ImageRedactor {
    func redact(image: UIImage, instances: [DetectedInstance]) async -> UIImage
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

---

## PII Detection Engine

### PIIScanner Pipeline

```
scanImage(data:)
    │
    ├─ [Stage 1] Validate — CGImageSourceCreateWithData + CreateImageAtIndex
    │               ensures a meaningful error before Vision receives bad data
    │
    ├─ [Stage 2] Vision OCR
    │   VNImageRequestHandler(data:)  ← raw Data, not CGImage, to preserve EXIF orientation
    │   VNRecognizeTextRequest
    │     .recognitionLevel = .accurate
    │     .usesLanguageCorrection = false  ← preserve raw credential characters
    │     .automaticallyDetectsLanguage = true
    │   → [VNRecognizedTextObservation]
    │
    │   If results.isEmpty → retry with fresh handler at .fast level
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

| Category | Type | Detection | Base score |
|----------|------|-----------|------------|
| Contact | Phone Number | `NSDataDetector` | 0.72 |
| Contact | Email Address | Regex + `NSDataDetector` | 0.93 / 0.75 |
| Web | Link / URL | `NSDataDetector` | 0.52 |
| Web | IP Address (IPv4) | Regex | 0.90 |
| Web | IP Address (IPv6) | Regex | 0.76 |
| Web | MAC Address | Regex | 0.72 |
| Identity | Address | `NSDataDetector` | 0.68 |
| Identity | Social Security Number | Regex | 0.94 |
| Identity | Date of Birth | Regex | 0.48 |
| Identity | National Insurance Number | Regex | 0.91 |
| Financial | Credit Card (compact) | Regex | 0.94 |
| Financial | Credit Card (spaced/dashed) | Regex | 0.80 |
| Financial | IBAN | Regex | 0.93 |
| Financial | Crypto Wallet (Ethereum) | Regex | 0.87 |
| Financial | Crypto Wallet (Bitcoin Bech32) | Regex | 0.88 |
| Developer Secrets | AWS Access Key | Regex | 0.98 |
| Developer Secrets | GitHub Token | Regex | 0.97 |
| Developer Secrets | Google API Key | Regex | 0.98 |
| Developer Secrets | OpenAI API Key | Regex | 0.97 |
| Developer Secrets | Slack Token | Regex | 0.97 |
| Developer Secrets | Stripe Key | Regex | 0.97 |
| Developer Secrets | Private Key (PEM) | Regex | 0.96 |
| Unstructured | Physical Credential / Password | Cross-observation heuristic | 0.68 |

**Why `usesLanguageCorrection = false`:** Vision's language correction normalises "AIzaSy..." into dictionary words. Disabled to preserve raw credential characters.

**Why `.accurate` first with `.fast` fallback:** The Neural Engine is unavailable in the simulator; the `.accurate` model returns zero observations on simulator CPU paths. A fresh `VNImageRequestHandler` is required for the retry because handlers are single-use.

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

**File:** `PicStrip/StripImageIntent.swift`

```swift
struct StripImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Photos with PicStrip"
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: "group.com.northcutt.PicStrip")?
            .set(true, forKey: "picstrip.openBatchPicker")
        return .result()
    }
}
```

When the intent fires:

1. A boolean flag is written to the shared App Group suite (`group.com.northcutt.PicStrip`).
2. The main app's `ContentView` observes `@AppStorage("picstrip.openBatchPicker", store: ...)`.
3. On `true`, `ContentView` immediately presents `BatchConfigView` instead of the home screen.

Siri phrase registered: `"Clean photos with PicStrip"`. Also appears in Shortcuts app and Spotlight.

---

## Persistence Model

| Data | Storage | Key | Scope |
|------|---------|-----|-------|
| Lifetime photos cleaned | `UserDefaults.standard` | `picstrip.lifetimePhotos` | App |
| Lifetime metadata fields stripped | `UserDefaults.standard` | `picstrip.lifetimeFields` | App |
| Batch picker flag | `UserDefaults(suiteName: "group.com.northcutt.PicStrip")` | `picstrip.openBatchPicker` | App Group |
| Audit JSON | `FileManager.default.temporaryDirectory` | `PicStrip_Audit_<UUID>.json` | Session |
| Batch audit JSON | `FileManager.default.temporaryDirectory` | `PicStrip_BatchAudit_<UUID>.json` | Session |

No photo metadata, no detection results, no user preferences beyond stats are ever persisted. This is intentional — nothing about which photos were processed or what PII was found survives a session.

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

The app defaults to `.addOnly` authorization. Users must explicitly grant read+write if they want "Replace Original."

### On-Device Processing Guarantee

```
UIImage(data:)          native iOS — no network
CGImageSourceCreateWithData  ImageIO — native iOS
VNRecognizeTextRequest  Vision — on-device model, no network
NSRegularExpression     Foundation — native iOS
UIGraphicsImageRenderer CoreGraphics — native iOS
CGImageDestinationCopyImageSource  ImageIO — native iOS
PHPhotoLibrary.performChanges       Photos — native iOS
```

Network Inspector in Xcode will show zero outbound connections from the app.

---

## CI/CD Pipeline

### Workflows at a Glance

| File | Trigger | Purpose |
|------|---------|---------|
| `pr.yml` | PR to `main` | Lint, static analysis, unit tests |
| `main.yml` | Push to `main` | Release pipeline (7 jobs) |
| `screenshots.yml` | Manual dispatch | App Store screenshot capture |

### PR Workflow (`pr.yml`)

Four jobs run on `macos-26`:

- **lint** — `bundle exec fastlane lint` (SwiftLint strict mode); runs on every PR
- **analyze** — `bundle exec fastlane analyze` (`xcodebuild analyze`); runs on every PR
- **test** — `bundle exec fastlane test` (`PicStripTests` unit tests on `iPhone 17` simulator; JUnit XML uploaded as artifact); runs on every PR
- **screenshots** — full 2-device App Store capture; runs **only when the `screenshots` label is applied** to the PR

#### PR Screenshots (`screenshots` label)

Adding the `screenshots` label to a PR triggers a full `capture_ios_screenshots` run across the same two devices used in `screenshots.yml` (iPhone 17 Pro Max, iPad Pro 13-inch M5). The App Store auto-scales the 6.9" iPhone set to 6.7"/6.5"/5.5", so the iPhone Air capture is intentionally omitted. Results are uploaded as a PR artifact (`pr-screenshots-<PR-number>`) for visual review. No upload to App Store Connect happens from PRs — that step is only performed by `screenshots.yml` when dispatched against `main`.

### Release Workflow (`main.yml`)

```
version (ubuntu-latest)
  └─ semantic-release --dry-run
     If no releasable commits → all downstream jobs are skipped

lint + analyze + test (macos-26, parallel)

build (macos-26)
  └─ bundle exec fastlane certificates
     bundle exec fastlane build
       ├─ fastlane match appstore (readonly, SSH key from secret)
       ├─ gym (Release config, App Store export method, manual signing)
       │     MARKETING_VERSION injected from semantic-release dry-run output
       │     BUILD_NUMBER = github.run_number
       └─ shasum -a 256 build/PicStrip.ipa → PicStrip.ipa.sha256
     Outputs: ipa-hashes (base64 SHA-256 for SLSA subject)
     Creates GitHub artifact attestation for build/PicStrip.ipa
     Restores DerivedData/SPM caches to reduce release build time

release (ubuntu-latest)
  └─ npx semantic-release
       ├─ Patches MARKETING_VERSION in project.pbxproj via sed
       ├─ Generates release_notes.txt (prepareCmd) → committed to main
       ├─ Creates GitHub Release + git tag
       └─ Updates CHANGELOG.md

provenance (reusable — slsa-framework/slsa-github-generator)
  └─ SLSA Level 3 provenance signed by Sigstore/Rekor
     Generator workflow referenced by release tag v2.1.0
     Attached to the GitHub Release

attach-release-assets (ubuntu-latest)
  └─ gh release upload v<version>
       PicStrip.ipa + PicStrip.ipa.sha256

verify-provenance (ubuntu-latest)
  ├─ gh attestation verify PicStrip.ipa
  │    --source-digest = github.sha
  │    --source-ref = refs/heads/main
  └─ slsa-verifier verify-artifact PicStrip.ipa
       --source-uri github.com/northcutted/picstrip
       --source-branch main
       plus exact github.sha check in the verified provenance JSON

upload-testflight (macos-26)
  └─ bundle exec fastlane upload_testflight
       Uploads the already-built and verified IPA artifact

submit (ubuntu-latest, "production" environment — requires manual approval)
  needs: [version, upload-testflight]
  ← approval gate appears only after provenance verification and TestFlight upload succeed
  └─ bundle exec fastlane submit
       ├─ upload_to_app_store (skip_binary_upload: true)
       ├─ submit_for_review: true
       ├─ automatic_release: true  (rolls out on approval)
       └─ phased_release: true     (7-day staged rollout)
```

### Fastlane Lanes

| Lane | Purpose |
|------|---------|
| `lint` | SwiftLint strict mode; fails on any warning |
| `analyze` | `xcodebuild analyze`; flags potential bugs |
| `test` | Unit tests on `iPhone 17` simulator; JUnit XML to `build/test_output/` |
| `certificates` | `fastlane match appstore` readonly sync (creates temp keychain on CI) |
| `build` | Increments build number; `gym` with App Store export; outputs `build/PicStrip.ipa` |
| `beta` | `certificates` → `build` → `upload_to_testflight` |
| `upload_testflight` | Uploads an existing IPA path (`IPA_PATH` or `build/PicStrip.ipa`) to TestFlight |
| `screenshots` | `capture_ios_screenshots` (reads `fastlane/Snapfile`); accepts `device:"..."`, `devices:"a,b"`, and `languages:"en-US,de-DE"` overrides for local runs |
| `process_screenshots` | Iterates every locale folder under `fastlane/screenshots/` and runs `scripts/process_screenshots.py` to produce the marketing PNGs in `processed/<locale>/` |
| `upload_screenshots` | Pushes the marketing PNGs in `fastlane/screenshots/processed/` to App Store Connect; validates the full required device set unless `allow_partial:true` is passed |
| `submit` | `upload_to_app_store` with `skip_binary_upload: true`; submits for App Review |
| `accessibility` | Sync App Store Accessibility Nutrition Label declarations from `fastlane/accessibility_declarations.json` |

### Screenshot Workflow (`screenshots.yml`)

Manually dispatched (not part of the release pipeline). Two modes selected by workflow inputs:

- **`generate_new=false` (default — fast upload).** Runs on `ubuntu-latest`. Checkout uses `lfs: true` to pull the marketing PNGs from `fastlane/screenshots/processed/`, then `bundle exec fastlane upload_screenshots` ships them to App Store Connect. ~2 minutes, no simulator, no macOS-runner cost. This is the right path when the on-disk PNGs already match what you want shipped.
- **`generate_new=true` (full regen).** Runs on `macos-26`. Boots both simulators, overrides status bars to `9:41` / full battery / Wi-Fi+cellular, runs the screenshot capture lane (optionally narrowed by the `languages` input), runs the Python compositor to produce the marketing PNGs, commits the result back to `main` via Git LFS with `[skip ci]`, and then uploads. Full 16-locale × 2-device matrix is ~2 hours; the `languages` input narrows the run when you only need a subset.

#### Marketing screenshot compositor

[`scripts/process_screenshots.py`](scripts/process_screenshots.py) wraps each raw capture in a custom matte-black device frame drawn in code, composites it on a brand-gradient canvas with a localized headline above, and writes the result to `fastlane/screenshots/processed/<locale>/`.

- **Single source of truth for upload**: `upload_screenshots` reads from `processed/`, never raw captures. `process_screenshots` regenerates the whole tree from raw captures present under each `<locale>/`.
- **Custom device frame** (not `frameit`): the upstream iPhone 14 Pro Max frame asset has a metallic side reflection that bleeds white edges over any non-white background, so we draw a matte-black rounded-rect frame in PIL with side/top buttons sized per device class. Faster, smaller, and works against the brand gradient.
- **Headline copy from `fastlane/MarketingHeadlines.xcstrings`** — 16 locales × 7 screens. The script falls back to an embedded English `HEADLINES` dict if the xcstrings file is missing, so the script is standalone-runnable.
- **Per-script font selection**: separate candidate lists for Latin, CJK (Hiragino Sans GB), Korean (Apple SD Gothic Neo Bold — Hiragino has no Hangul glyphs), and Arabic (Geeza Pro). A `_font_candidates_for_text()` helper picks the right list per line.
- **Arabic shaping**: PIL renders Arabic letters in input order without joining isolated forms or reversing for RTL. The script preprocesses any line that contains Arabic with `arabic_reshaper.reshape()` + `bidi.algorithm.get_display()` before drawing. A `_line_has_arabic()` guard prevents bidi from reversing pure-Latin lines that happen to share a paragraph with Arabic.
- **Multi-pass headline fit**: the layout tries the cleanest line count first (one line per `\n`-separated paragraph) and only escalates to wrap-and-shrink when no font in the candidate list fits, which avoids orphan-word lines on de-DE / pl / tr / it where translations grow.
- **Locale-driven directory discovery**: the `process_screenshots` lane discovers locale folders under `fastlane/screenshots/` rather than hardcoding the list, so adding a locale to `Snapfile` does not require a Fastfile edit.

#### Pipeline-level decisions

- **Git LFS for `processed/**/*.png`**: tracked via `.gitattributes`. Lets the marketing PNGs round-trip through Git without bloating the pack files; the upload-only workflow path checks them out without ever touching macOS.
- **Single `testAllScreenshots()` method**: all screenshots are captured in one XCTest method. Splitting across separate methods causes XCTest to terminate and relaunch the app between each method in headless CI, which fails with `Failed to terminate com.northcutt.PicStrip`.
- **Dedicated `PicStripScreenshots` scheme**: excludes unit test bundles (`PicStripTests`, etc.) so the screenshot job doesn't re-run the full test suite.
- **Accessibility identifiers, not localized strings, in `PicStripUITests.swift`**: querying by localized text fails in non-English locales (e.g. Arabic `navigationBars["Removed Data"]`). Identifiers are stable across all 16 capture locales.
- **Local device / language overrides**: `bundle exec fastlane screenshots device:"iPhone 17 Pro Max" languages:"en-US"` smoke-tests one combo before committing to the full matrix.
- **Upload guard**: `upload_screenshots` refuses incomplete local screenshot sets by default so one-device smoke captures do not wipe the App Store Connect screenshot matrix. Pass `allow_partial:true` to override.
- **`number_of_retries(0)` in Snapfile**: screenshot failures are deterministic; retrying wastes a full macOS job cycle.
- **`if: always()` on artifact uploads**: partial screenshots and logs are preserved even when capture fails.

**PR label-gated screenshots (`pr.yml` — `screenshots` job)**: Adding the `screenshots` label to a PR triggers a single-locale capture (`languages:en-US`) on iPhone 17 Pro Max + iPad Pro 13-inch (M5). Results upload as a PR artifact (`pr-screenshots-<PR-number>`, retained 14 days). The App Store Connect upload step is skipped — it only runs when `screenshots.yml` is dispatched against `main`. The PR job is intentionally pinned to en-US: the full 16-locale capture exceeds the 60-minute PR timeout.

### Semantic Release

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

| Commit prefix | Version bump |
|---------------|-------------|
| `feat:` | minor (1.0.0 → 1.1.0) |
| `fix:` / `perf:` / `revert:` | patch (1.0.0 → 1.0.1) |
| `BREAKING CHANGE:` anywhere | major (1.0.0 → 2.0.0) |

On release, semantic-release runs a `prepareCmd` that generates `fastlane/metadata/en-US/release_notes.txt` from the commit log, then commits `release_notes.txt` and the updated `project.pbxproj` (MARKETING_VERSION patch) back to `main`.

---

## SLSA Build Provenance Level 3

Every release is accompanied by SLSA Build Level 3 provenance for the GitHub-built `PicStrip.ipa`, cryptographically proving the IPA was produced by GitHub Actions.

This claim is intentionally scoped to the IPA built and attested by GitHub Actions. It does not claim that the same digest identifies the App Store-installed application, because Apple may re-sign, encrypt, thin, or otherwise transform apps during distribution.

The release pipeline creates two complementary provenance records:

- **GitHub artifact attestation**: the `build` job runs `actions/attest-build-provenance` against `build/PicStrip.ipa`, which uploads provenance to GitHub's repository Attestations API so the release shows attestation coverage in GitHub.
- **Release-attached SLSA provenance**: the `provenance` job runs the SLSA GitHub Generator reusable workflow and attaches the SLSA Level 3 provenance file to the GitHub Release.

### What SLSA Level 3 Guarantees

| Requirement | How PicStrip satisfies it |
|-------------|--------------------------|
| Source version controlled | GitHub-hosted repository |
| Hosted build platform | GitHub Actions (`macos-26` ephemeral runner) |
| Build-as-code | `main.yml` checked into the repo |
| Ephemeral environment | Fresh runner per job; no persistent state |
| Isolated build | Hosted GitHub runner; provenance verification gates distribution |
| Non-falsifiable provenance | Signed by Sigstore/Rekor (public, immutable transparency log) |
| Distribution gate | TestFlight upload waits for GitHub attestation and SLSA release provenance verification |

### GitHub Artifact Attestations

The `build` job grants only the extra permissions required for native artifact attestations:

- `id-token: write` to mint the OIDC token used for Sigstore signing
- `attestations: write` to persist the attestation in GitHub
- `artifact-metadata: write` to create the linked artifact metadata record

The attestation action is pinned by immutable commit SHA (`a2bbfa25…`, `actions/attest-build-provenance@v4.1.0`) and runs after the IPA and SHA-256 digest are created, before the workflow artifact is uploaded.

The release workflow verifies this attestation before TestFlight upload using:

```bash
gh attestation verify PicStrip.ipa \
  --repo northcutted/picstrip \
  --signer-workflow github.com/northcutted/picstrip/.github/workflows/main.yml \
  --source-ref refs/heads/main \
  --source-digest <release-workflow-source-commit>
```

Because semantic-release creates the public tag after the IPA is built, the primary source identity for the attested IPA is the workflow source commit (`github.sha`), not the release tag commit.

### SLSA Generator Ref

The `provenance` job references the SLSA reusable workflow by upstream release tag (`v2.1.0`). That tag resolves to the previously pinned generator commit (`f7dd8c54…`), but the tag form is important for compatibility with `slsa-verifier`: provenance generated from a SHA-only reusable workflow ref can surface the generator identity as an untyped commit ref, which `slsa-verifier` rejects with `unexpected ref type`.

PicStrip's app source identity remains commit-based. The release workflow verifies `refs/heads/main` plus the exact `github.sha` that built the IPA, so semantic-release's later tag creation does not become the trust anchor for the attested binary.

### Verify an IPA

**Option 1 — GitHub artifact attestation**

```bash
gh attestation verify PicStrip.ipa \
  --repo northcutted/picstrip \
  --signer-workflow github.com/northcutted/picstrip/.github/workflows/main.yml \
  --source-ref refs/heads/main \
  --source-digest <release-workflow-source-commit>
```

Expected output includes a verified SLSA provenance predicate associated with `northcutted/picstrip`.

**Option 2 — slsa-verifier**

```bash
brew install slsa-framework/slsa/slsa-verifier

slsa-verifier verify-artifact PicStrip.ipa \
  --provenance-path PicStrip.ipa.intoto.jsonl \
  --source-uri github.com/northcutted/picstrip \
  --source-branch main
```

The release workflow also checks that the verified provenance JSON contains the exact workflow source commit SHA.

Expected output:
```
Verified SLSA provenance for PicStrip.ipa
```

**Option 3 — SHA-256 checksum**

```bash
# Both files are attached to every GitHub Release
shasum -a 256 PicStrip.ipa > computed.sha256
diff computed.sha256 PicStrip.ipa.sha256
# No output = checksums match
```

**Option 4 — Rekor transparency log**

```bash
rekor-cli search \
  --artifact PicStrip.ipa \
  --pki-format=x509 \
  --public-key=/path/to/github-public-key.pem
```

Or browse: `https://search.sigstore.dev/?logIndex=<index>`

### References

- SLSA Specification: https://slsa.dev/
- SLSA GitHub Generator: https://github.com/slsa-framework/slsa-github-generator
- slsa-verifier: https://github.com/slsa-framework/slsa-verifier
- Rekor: https://transparency.sigstore.dev/

---

## Localization

PicStrip localizes user-facing app text through Apple string catalogs:

- `PicStrip/Localizable.xcstrings` — app, share extension, processing, errors, and accessibility copy
- `PicStrip/AppShortcuts.xcstrings` — App Shortcut phrases that Siri and Shortcuts expose
- `fastlane/MarketingHeadlines.xcstrings` — App Store screenshot headline copy (7 keys × 16 locales). Read by `scripts/process_screenshots.py` at compose time.

**Production translations are hand-written.** Privacy-sensitive copy (permission prompts, redaction terminology, App Shortcut phrases, marketing headlines) is too high-stakes to ship LLM output of, and per-locale tuning catches idiom drift that machine translation doesn't. New strings get committed in English first, then a human review fills in target locales for each catalog.

**Pseudo-localization is available for layout smoke testing.** `scripts/translate_xcstrings.js --languages es fr de` writes `[<lang>] <source>` strings into the missing slots so the UI can be exercised against longer strings, RTL mirroring, and accent-rich glyphs before the real translations land. These pseudo entries should be replaced with real translations before release.

```bash
# See what's missing in a catalog without writing.
scripts/translate_xcstrings.js --languages es fr --dry-run

# Pseudo-localize a single catalog for layout smoke testing.
make localization-pseudo LANGUAGES="es"

# Pseudo-localize the marketing headlines catalog specifically.
scripts/translate_xcstrings.js --files fastlane/MarketingHeadlines.xcstrings --languages de

# Validate JSON shape, hard-coded-string audit, and SwiftLint after edits.
make localization-validate

# Export .xcloc bundles for handoff to a human translator.
make localization-export
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

`VNRecognizeTextRequest.usesLanguageCorrection = true` normalises OCR output toward dictionary words. For credentials (`AIzaSyD...`, `sk-live-...`, `AKIAIOSFODNN7EXAMPLE`) this destroys the pattern structure the regex rules depend on. It must remain `false`.

### `.fast` Fallback Requires a Fresh Handler

`VNImageRequestHandler` is single-use. The `.accurate` + `.fast` retry pattern in `PIIScanner.recognizeText(in:)` correctly creates a new handler for the retry. Do not attempt to reuse the first handler — the `perform()` call will throw.

### Batch Processing Must Remain Sequential

Concurrent batch processing would require holding multiple decoded `UIImage` objects in memory simultaneously. On a device processing ten 12 MP photos, this exceeds available memory. The sequential loop with explicit `nil` assignments is not defensive programming overhead — it is the memory model.
