# PicStrip Developer Documentation

This document provides comprehensive architecture details, data flows, service descriptions, and contributing guidelines for PicStrip developers.

---

## Table of Contents

1. [Project Structure](#project-structure)
2. [Architecture Overview](#architecture-overview)
3. [Data Flow](#data-flow)
4. [Services Reference](#services-reference)
5. [Image Processing Deep Dive](#image-processing-deep-dive)
6. [PII Detection Engine](#pii-detection-engine)
7. [Batch Processing](#batch-processing)
8. [Share Extension](#share-extension)
9. [App Intent & Siri](#app-intent--siri)
10. [Persistence Model](#persistence-model)
11. [Privacy & Security](#privacy--security)
12. [CI/CD Pipeline](#cicd-pipeline)
13. [Contributing: Adding a New PII Type](#contributing-adding-a-new-pii-type)
14. [Known Constraints](#known-constraints)

---

## Project Structure

```
PicStrip/
├── PicStrip.xcodeproj/          # Xcode project (main app + share extension)
├── README.md                     # Public-facing documentation
├── DEVELOPMENT.md                # This file
├── .swiftlint.yml               # SwiftLint configuration
├── .releaserc.json              # Semantic release configuration
├── Fastfile                      # Fastlane build automation
├── Snapfile                      # Fastlane screenshot configuration
│
├── .github/workflows/
│   ├── pr.yml                    # PR checks: lint, analyze, test
│   └── main.yml                  # Main branch: build, screenshots, release, provenance
│
├── PicStrip/                    # Main app target
│   ├── PicStripApp.swift         # @main entry point
│   ├── ContentView.swift         # Root view with navigation stack & sheets
│   ├── ScrubberViewModel.swift   # Core @Observable state machine (687 lines)
│   ├── About/                    # AboutView & license screens
│   ├── Components/
│   │   ├── ScannerHeroView.swift       # Animated decorative blob gradient
│   │   ├── MetadataBadgeRow.swift      # Category pills (GPS, EXIF, TIFF, etc.)
│   │   ├── CategoryDetailPanel.swift   # Sliding panel over image with per-field toggles
│   │   └── ...
│   ├── Models/
│   │   ├── MetadataField.swift         # Single EXIF/TIFF/IPTC key-value + category
│   │   ├── StrippedMetadata.swift      # Collection of fields with grouping
│   │   ├── StripConfig.swift           # User toggles: per-category + per-field overrides
│   │   ├── PIITypes.swift              # Enum: Email, Phone, SSN, etc. (20 types)
│   │   ├── DetectionResult.swift       # Aggregated findings for one PII type
│   │   ├── AuditReport.swift           # Codable summary for JSON export
│   │   ├── ExportPreset.swift          # Format (PNG/JPEG/HEIC) + quality settings
│   │   └── ...
│   ├── Services/
│   │   ├── ImageProcessor.swift        # Static EXIF/metadata stripping (two-pass ImageIO)
│   │   ├── PIIScanner.swift            # Async OCR + regex + NSDataDetector
│   │   ├── ImageRedactor.swift         # UIGraphicsImageRenderer black-box burn
│   │   └── DetectionRegistry.swift     # Regex patterns compiled at startup
│   ├── Extensions/
│   │   ├── Image+Extensions.swift      # Image normalization, coordinate flipping
│   │   └── ...
│   └── Resources/
│       └── PrivacyInfo.xcprivacy      # Zero-data-collection privacy manifest
│
├── PicStripShareExtension/          # Share Extension target (separate from main app)
│   ├── ShareViewController.swift     # UIKit host for extension UI
│   ├── ExtensionConfigView.swift     # SwiftUI embedded via UIHostingController
│   ├── ExtensionViewModel.swift      # @Observable state machine
│   ├── ImageProcessor.swift          # ⚠️ Duplicate: shared logic, not linked
│   ├── ExportPreset.swift            # ⚠️ Duplicate: shared logic, not linked
│   └── Resources/
│       └── PrivacyInfo.xcprivacy     # Zero-data-collection privacy manifest
│
└── PicStripTests/                   # Unit tests
    ├── ImageProcessorTests.swift     # Metadata stripping verification
    ├── PIIScannerTests.swift         # OCR + detection accuracy
    └── ...
```

**Key Notes:**
- `ImageProcessor.swift` and `ExportPreset.swift` are **duplicated** in both targets; they are not shared frameworks because the Share Extension cannot link to the main app's binary.
- `ExportFormat+AppEnum.swift` is compiled **only in the main app target** (it imports `AppIntents`).
- `PrivacyInfo.xcprivacy` is duplicated in both targets for independent privacy declarations.

---

## Architecture Overview

### Design Pattern: MVVM

PicStrip uses **Model–View–ViewModel (MVVM)** with modern Swift concurrency patterns.

```
┌─────────────────────────────────────────┐
│          SwiftUI Views Layer            │
│  (ContentView, PreSaveReviewView, etc.) │
└──────────────────┬──────────────────────┘
                   │ @State, @Binding
                   │ observes changes
                   ↓
┌──────────────────────────────────────────┐
│   ScrubberViewModel (@Observable)        │
│  ├─ isProcessing: Bool                   │
│  ├─ errorMessage: String?                │
│  ├─ activeSheet: ActiveSheet?            │
│  ├─ loadedImage: UIImage?                │
│  ├─ detectionResult: DetectionResult?    │
│  ├─ strippedMetadata: StrippedMetadata?  │
│  ├─ stripConfig: StripConfig             │
│  └─ processSinglePhoto()                 │
│     processBatch()                       │
│     processForExport()                   │
└──────────────────┬──────────────────────┘
                   │ calls (no coupling)
                   ↓
┌──────────────────────────────────────────┐
│   Services (stateless structs/enums)     │
│  ├─ ImageProcessor.process()             │
│  ├─ PIIScanner.scanImage()               │
│  └─ ImageRedactor.redact()               │
└──────────────────┬──────────────────────┘
                   │ uses
                   ↓
┌──────────────────────────────────────────┐
│     Apple Frameworks (ImageIO, Vision,   │
│     Photos, PhotosUI, AppIntents)        │
└──────────────────────────────────────────┘
```

### Why MVVM?

1. **Testable:** Services are pure functions; ViewModels can be tested in isolation.
2. **Reusable:** Same ViewModels power both the main app and Share Extension.
3. **Lightweight:** Swift `@Observable` (iOS 17+) eliminates Combine boilerplate.
4. **No Third-Party Deps:** Zero runtime dependencies on reactive frameworks.
5. **Async-First:** Native `async/await` integration from the ground up.

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| No Core Data / SwiftData | Metadata is ephemeral; only lifetime stats need persistence (UserDefaults suffices) |
| Stateless services | Photo processing is deterministic; no mutable state needed |
| Two-pass ImageIO | Defeats auto-synthesis of minimal EXIF; ensures truly clean output |
| Sequential batch processing | Avoids OOM on device; each image is explicitly dereferenced |
| Vision + Regex + NSDataDetector | Layered detection: Vision for arbitrary text, NSDataDetector for OS-native patterns, Regex for high-confidence structure |
| App Group `group.com.northcutt.PicStrip` | Single-flag IPC from App Intent to main app (batch picker trigger) |

---

## Data Flow

### Single-Photo Flow

```
User taps PhotosPicker
    ↓
ContentView.onPhotoPickerChange()
    ↓
ScrubberViewModel.processSinglePhoto(photoData, itemProvider)
    ├─ Decode: PHAsset → UIImage(data:).normalized()
    ├─ Scan (async): PIIScanner.scanImage()
    │  └─ Task.detached { Vision OCR + Regex + NSDataDetector }
    ├─ Extract: ImageProcessor.process(.extract) → StrippedMetadata
    ├─ @MainActor update: detectionResult, strippedMetadata, stripConfig
    └─ Set isProcessing = false
    ↓
User views metadata and PII overlays
    ↓
User adjusts stripConfig (toggle categories, fields, PII redaction)
    ↓
User taps "Save to Photos" or "Share"
    ├─ presentSheet(.preSave)
    └─ PreSaveReviewView shows summary + export options
    ↓
User taps "Save as New" / "Replace Original" / "Share"
    ├─ Call ScrubberViewModel.processForExport()
    │  ├─ Optional: ImageRedactor.redact() if PII redaction enabled
    │  ├─ Call: ImageProcessor.process(.export, config, redactedImage)
    │  └─ Returns clean JPEG/PNG/HEIC bytes
    ├─ Save to Photos library via PHPhotoLibrary.shared()
    ├─ Update lifetime stats in UserDefaults
    ├─ Generate + share AuditReport JSON
    └─ Dismiss sheet → home screen
```

### Batch-Photo Flow

```
User taps "Pick Multiple"
    ↓
ContentView.batch(PhotosPicker)
    ↓
ScrubberViewModel.processBatch(assets, config)
    ├─ for each asset (sequential loop):
    │  ├─ Decode: UIImage(data:).normalized()
    │  ├─ Scan (async): PIIScanner.scanImage()
    │  ├─ Extract: ImageProcessor.process(.extract)
    │  ├─ Optional: ImageRedactor.redact()
    │  ├─ Encode: ImageProcessor.process(.export)
    │  ├─ Save to Photos
    │  ├─ Append BatchAuditReport
    │  ├─ Explicitly zero Data and UIImage references (ARC pressure relief)
    │  └─ Update UI progress
    └─ Generate batch summary JSON
    ↓
BatchSummaryView displays total processed, errors, and downloadable audit
```

### Data Ownership

| Data | Owner | Lifetime |
|------|-------|----------|
| `loadedImage: UIImage?` | ScrubberViewModel | Single-photo session or nil |
| `detectionResult: DetectionResult?` | ScrubberViewModel | Single-photo session or nil |
| `strippedMetadata: StrippedMetadata?` | ScrubberViewModel | Single-photo session or nil |
| `stripConfig: StripConfig` | ScrubberViewModel | Per-session; user edits persist across images in same session |
| `batchItems: [BatchItem]` | ScrubberViewModel | Batch session only |
| Lifetime stats | UserDefaults.standard | App lifetime |
| Audit JSON | FileManager.tmp | Session; user can download/share; deleted after session |

---

## Services Reference

### ImageProcessor

**File:** `PicStrip/Services/ImageProcessor.swift`

A **namespace** of static methods for metadata extraction and stripping.

```swift
enum ImageProcessor {
    // Mode: extract metadata, export with stripping, etc.
    enum Mode { case extract, export }
    
    static func process(
        imageData: Data,
        mode: Mode,
        config: StripConfig = .default,
        outputFormat: ExportFormat = .jpeg
    ) -> Result<Data, ImageProcessorError>
    
    static var availableCategories: [MetadataCategory]
    static var structuralFields: [String]  // Cannot be stripped
}
```

#### Two-Pass Encoding Strategy

The core privacy guarantee rests on a deliberate **two-pass re-encode**:

**Pass 1: Normalize orientation**
```swift
let uiImage = UIImage(data: imageData).normalized()
// Forces orientation=1 (canonical), discards all metadata except pixels
let cgImage = uiImage.cgImage
```

**Pass 2: Selective re-apply via CGImageDestination**
```swift
let destination = CGImageDestinationCreateWithData(...)
// Merge only the metadata the user permitted
let metadata = selectedMetadata()  // User's StripConfig applied
CGImageDestinationSetProperties(destination, [
    kCGImagePropertyExifDictionary: metadata.exif,
    kCGImagePropertyTIFFDictionary: metadata.tiff,
    // ... other categories
])
CGImageDestinationFinalize(destination)
```

**Why two passes?**
- **Single-pass re-encode** with empty metadata hints still triggers ImageIO's auto-synthesis of minimal EXIF (e.g., minimal ColorModel, PixelDimensions).
- **Two-pass** forces a fresh pixel decode, breaking the link to the original file's metadata template.
- Result: truly clean output with zero auto-synthesised fields.

#### Structural Fields (Cannot Be Stripped)

These fields are unconditionally re-injected by the iOS encoder and are marked `isStructural: true`:

- `PixelWidth`, `PixelHeight` (image dimensions)
- `Orientation` (1 = canonical)
- `ColorModel` (RGB, CMYK, etc.)
- `XResolution`, `YResolution` (DPI)
- `ResolutionUnit`

The UI displays a lock icon and explains: "Structural fields contain no personal data and cannot be removed."

#### Metadata Categories

Extracted and categorized as:

| Category | Example Fields |
|----------|---|
| **GPS** | `GPSLatitude`, `GPSLongitude`, `GPSAltitude` |
| **EXIF** | `DateTimeOriginal`, `CameraModel`, `LensMake`, `ExposureTime`, `FNumber` |
| **EXIF Auxiliary** | `LensInfo`, `InternalSerialNumber` |
| **TIFF** | `ImageDescription`, `Make`, `Model`, `Orientation` |
| **IPTC** | `Keywords`, `Copyright`, `Creator`, `CaptionAbstract` |
| **Apple Maker Note** | Private Apple camera tuning data |

---

### PIIScanner

**File:** `PicStrip/Services/PIIScanner.swift`

On-device OCR + rule-based detection for 20 PII types.

```swift
struct PIIScanner {
    static func scanImage(
        _ cgImage: CGImage
    ) async -> DetectionResult
}
```

#### Detection Pipeline

```
CGImage input
    ↓
[1] Vision VNRecognizeTextRequest (accurate, language correction disabled)
    ↓
for each VNRecognizedTextObservation:
    │
    ├─ [2a] DetectionRegistry.allRules regex sweep
    │        └─ Each regex has a baseScore (0.7–1.0 depending on pattern strength)
    │
    └─ [2b] NSDataDetector (phone, address, link, URL)
            └─ If a rule matched earlier with higher score, keep that
            └─ Otherwise, record NSDataDetector result
    ↓
[3] Bounding box coordinate flip: Vision (bottom-left origin) → SwiftUI (top-left)
    ↓
[4] Orphan-label heuristic:
    └─ If an observation matches bare "password:" with no value,
       treat the next observation as the password value
    ↓
DetectionResult { [.email: [instances...], .ssn: [instances...], ...] }
```

#### PII Types (20 total)

| Type | Pattern | Example |
|------|---------|---------|
| **Email** | RFC 5322 email regex | `user@example.com` |
| **Phone** | NSDataDetector | `(555) 123-4567` |
| **SSN** | `XXX-XX-XXXX` | `123-45-6789` |
| **Credit Card** | `XXXX-XXXX-XXXX-XXXX` | `4532 1234 5678 9010` |
| **API Key** | `api_[a-zA-Z0-9_]{20,}` | `api_sk_live_abc123...` |
| **JWT** | `eyJ...` (base64 pattern) | JWT token |
| **Private Key** | `-----BEGIN PRIVATE KEY-----` | PEM-encoded key |
| **Password** | `password[:\s=]+\S+` | `password: MyP@ssw0rd` |
| **Database Connection** | `(mysql\|postgres)://...` | Connection string |
| **AWS Key** | `AKIA[0-9A-Z]{16}` | AWS access key |
| **OAuth Token** | `oauth_.*\s*=` | OAuth credential |
| **Slack Token** | `xox[baprs]-\d+-\w+` | Slack API token |
| **GitHub Token** | `ghp_[A-Za-z0-9_]{36,255}` | GitHub PAT |
| **License Key** | Alphanumeric with hyphens, 20+ chars | Software license |
| **UUID** | `[0-9a-f]{8}-[0-9a-f]{4}...` | Unique identifier |
| **URLs** | NSDataDetector | `https://example.com/path` |
| **Addresses** | NSDataDetector | `123 Main St, City, ST 12345` |
| **Blockchain Address** | `0x[a-fA-F0-9]{40}` | Ethereum address |
| **Social Security Card** | Alternative format | SSN variants |
| **Date of Birth** | `MM/DD/YYYY` or `YYYY-MM-DD` | `01/15/1990` |

#### Scoring & Confidence

```swift
let score = baseScore × ocrConfidence
// baseScore: 0.7 (weak, e.g., bare "password:") to 1.0 (strong, e.g., "api_" prefix)
// ocrConfidence: Vision's per-character confidence (typically 0.8–0.99)
// Result: 0.56–0.99 range, user is alerted only if score > threshold (default 0.6)
```

#### Coordinate System

Vision framework returns bounding boxes in **bottom-left origin** (normalized 0–1):
```swift
// Vision box: (x: 0.5, y: 0.8) = 50% from left, 80% from bottom
// Flip to SwiftUI (top-left origin):
swiftUIBox.origin.y = 1.0 - visionBox.origin.y - visionBox.size.height
```

This flip happens **at detection time** so that red overlay boxes and black redaction boxes land on identical pixels.

#### Orphan-Label Heuristic

If an observation matches a bare credential label with no value:
```
"password:" with no following colon-separated value
    ↓ is treated as an orphan label
    ↓
Next observation is treated as the password value
    ↓
Both are marked as `.password` type and grouped
```

This handles common patterns like:
```
Username: john.doe
Password: MySecureP@ss123
```

Instead of `Username:` and `Password:` being separate detections, the values are recognized as part of the PII.

---

### ImageRedactor

**File:** `PicStrip/Services/ImageRedactor.swift`

Burns opaque black rectangles over detected PII regions.

```swift
struct ImageRedactor {
    static func redact(
        image: UIImage,
        over detectionResult: DetectionResult,
        selectedTypes: [PIIType]
    ) async -> UIImage
}
```

#### Implementation

```swift
let renderer = UIGraphicsImageRenderer(size: image.size)
let redactedImage = renderer.image { context in
    image.draw(in: CGRect(origin: .zero, size: image.size))
    
    UIColor.black.setFill()
    for (type, result) in detectionResult {
        guard selectedTypes.contains(type) else { continue }
        for instance in result.allInstances {
            let rect = instance.boundingBox
            context.cgContext.fill(rect)
        }
    }
}
```

**Runs in:** `Task.detached` (off the main thread) to avoid UI jank on large images.

**Coordinate System:** Bounding boxes are already in SwiftUI normalized coordinates; they're multiplied by `image.size` to get renderer-space pixel coordinates.

---

## Image Processing Deep Dive

### Metadata Extraction Flow

```swift
// Step 1: Create image source
let source = CGImageSourceCreateWithData(imageData, nil)!

// Step 2: Get metadata
let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
let metadataDict = CGImageMetadataCreateMutableCopy(metadata)

// Step 3: Iterate all tags and extract key-value pairs
let tags = CGImageMetadataEnumerateTagsUnderPath(metadataDict, nil, nil, nil) as! [CGImageMetadataTag]

for tag in tags {
    let category = categorizeTag(tag)  // GPS, EXIF, TIFF, IPTC, etc.
    let key = extractKey(tag)
    let value = extractValue(tag)
    metadataFields.append(MetadataField(category: category, key: key, value: value, isStructural: isStructural(key)))
}
```

### Metadata Stripping Flow (Two-Pass)

```swift
// PASS 1: Normalize orientation and discard old metadata
let uiImage = UIImage(data: imageData).normalized()  // Forces orientation=1
let cgImage = uiImage.cgImage!

// PASS 2: Re-encode with selective metadata
let destination = CGImageDestinationCreateWithData(outputData, format, 1, nil)!

// Build filtered metadata based on StripConfig
let filteredMetadata = config.apply(to: strippedMetadata)
// filteredMetadata includes:
//   - Any categories user toggled ON
//   - Any individual fields user toggled ON
//   - Structural fields (always included)

let properties: [String: Any] = [
    kCGImagePropertyExifDictionary: filteredMetadata.exif,
    kCGImagePropertyExifAuxiliaryDictionary: filteredMetadata.exifAux,
    kCGImagePropertyTIFFDictionary: filteredMetadata.tiff,
    kCGImagePropertyIPTCDictionary: filteredMetadata.iptc,
    kCGImagePropertyMakerAppleDictionary: filteredMetadata.appleMN,
]

CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
CGImageDestinationFinalize(destination)
```

---

## PII Detection Engine

### DetectionRegistry

**File:** `PicStrip/Services/DetectionRegistry.swift`

A centralized registry of all PII detection rules.

```swift
enum DetectionRegistry {
    static let allRules: [DetectionRule] = [
        // Compiled once at app startup
        DetectionRule(
            type: .email,
            pattern: try! NSRegularExpression(pattern: emailRegex, options: []),
            baseScore: 0.95
        ),
        DetectionRule(
            type: .ssn,
            pattern: try! NSRegularExpression(pattern: "\\d{3}-\\d{2}-\\d{4}", options: []),
            baseScore: 0.98
        ),
        // ... 18 more rules
    ]
}
```

**Design Notes:**
- All regexes are compiled **once** at startup (in the `static let` initializer).
- Each rule has a `baseScore` reflecting pattern confidence (0.7–1.0).
- No regex compilation on each text observation — O(n) OCR text → O(1) per-rule matching.

### Scoring Algorithm

```swift
func scoreObservation(_ text: String, _ rule: DetectionRule, _ ocrConfidence: Double) -> Double {
    let regexMatches = rule.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
    if regexMatches.isEmpty { return 0.0 }
    return rule.baseScore * ocrConfidence
}

// Record logic: keep the highest score for each PII type
var detectionResult: [PIIType: DetectionResult] = [:]
for (type, score, instance) in candidatesWithScores {
    let currentBest = detectionResult[type]?.bestScore ?? 0.0
    if score > currentBest {
        detectionResult[type] = DetectionResult(
            type: type,
            bestScore: score,
            allInstances: [instance],
            matchCount: 1
        )
    }
}
```

---

## Batch Processing

### Sequential Design

Batch processing runs **one image at a time**, never concurrently, to avoid OOM on devices with limited memory (e.g., iPhone SE).

```swift
func processBatch(_ assets: [PHAsset], _ config: BatchConfig) async {
    var batchReports: [BatchAuditReport] = []
    
    for (index, asset) in assets.enumerated() {
        isProcessing = true
        currentBatchIndex = index
        
        do {
            // Load image
            let data = try await loadImageData(asset)
            var image = UIImage(data: data).normalized()
            
            // Scan for PII
            let detectionResult = await PIIScanner.scanImage(image.cgImage!)
            
            // Redact if enabled
            if config.redactPII {
                image = await ImageRedactor.redact(image, over: detectionResult, ...)
            }
            
            // Strip metadata
            let cleanData = ImageProcessor.process(
                imageData: image.jpegData(...),
                mode: .export,
                config: config.stripConfig
            )
            
            // Save to library
            try await saveToPhotos(cleanData)
            
            // Record audit
            batchReports.append(BatchAuditReport(...))
            
        } catch {
            batchErrors.append((asset: asset, error: error))
        }
        
        // Explicit cleanup for ARC pressure relief
        data = nil
        image = nil
        detectionResult = nil
    }
    
    isProcessing = false
    showBatchSummary(batchReports, batchErrors)
}
```

### Memory Management

Between iterations, we explicitly nil out large references:
```swift
var data: Data? = ...
// ... use data ...
data = nil  // ARC immediately deallocates
```

This prevents the OS from paging 10 high-resolution images into swap on low-memory devices.

---

## Share Extension

### Architecture

The Share Extension (`PicStripShareExtension` target) is a separate Xcode target that **does not link** to the main app binary. It includes **duplicate copies** of shared files.

```
ShareViewController (UIKit)
    ↓ UIHostingController
ExtensionConfigView (SwiftUI)
    ├─ Embedded SwiftUI view
    └─ Calls ExtensionViewModel
        ├─ Uses ImageProcessor.swift (duplicate)
        ├─ Uses PIIScanner.swift (shared logic, re-implemented in extension)
        └─ Uses ImageRedactor.swift (shared logic, re-implemented)
```

### Why Duplication?

iOS Share Extensions cannot link to the main app's `.app` binary. Instead:
1. `ImageProcessor.swift` and `ExportPreset.swift` are **copied** to the extension target.
2. A compiler-time check prevents linking `ExportFormat+AppEnum.swift` (which imports `AppIntents`) to the extension.
3. Both targets have independent `PrivacyInfo.xcprivacy` declarations.

### 120 MB Memory Ceiling

iOS imposes a **~120 MB memory limit** on Share Extension processes. To stay under this:
- Images are processed one at a time.
- Large `Data` buffers are explicitly deallocated after use.
- UIImage memory is released immediately after encoding.

Comments in `ExtensionViewModel.swift` document this constraint.

---

## App Intent & Siri

### StripImageIntent

**File:** `PicStrip/Services/StripImageIntent.swift`

Registers the **"Clean Photos with PicStrip"** intent for Siri, Shortcuts, and Spotlight.

```swift
struct StripImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Photos with PicStrip"
    static let openAppWhenRun: Bool = true
    
    @MainActor
    func perform() async throws -> some IntentResult {
        // Signal the main app to open the batch picker
        UserDefaults(suiteName: "group.com.northcutt.PicStrip")?
            .set(true, forKey: "picstrip.openBatchPicker")
        
        return .result()
    }
}
```

### IPC via App Group

When the intent is invoked:
1. `UserDefaults(suiteName: "group.com.northcutt.PicStrip")` is written with flag `picstrip.openBatchPicker = true`.
2. The main app's `ContentView` observes `@AppStorage("picstrip.openBatchPicker", store: UserDefaults(suiteName: "group.com.northcutt.PicStrip"))`.
3. On observing `true`, `ContentView` immediately presents `BatchConfigView` instead of home screen.

### Siri/Shortcuts Registration

```swift
struct PicStripShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] = [
        AppShortcut(
            intent: StripImageIntent(),
            phrases: ["Clean photos with PicStrip"],
            shortTitle: "Clean Photos",
            systemImageName: "photo"
        )
    ]
}
```

This registers the intent in:
- Siri voice command: "Clean photos with PicStrip"
- Shortcuts app: appears in the library for automation
- Spotlight search: "Clean Photos"

---

## Persistence Model

### What Is Stored

| Data | Storage | Key | Scope | Notes |
|------|---------|-----|-------|-------|
| Lifetime photos cleaned | `UserDefaults.standard` | `picstrip.lifetimePhotos` | App | Incremented after each save |
| Lifetime metadata fields stripped | `UserDefaults.standard` | `picstrip.lifetimeFields` | App | Incremented per field |
| Batch picker flag | `UserDefaults(suiteName: "group...")` | `picstrip.openBatchPicker` | App Group | IPC from App Intent to main app |
| Audit JSON (temporary) | `FileManager.default.temporaryDirectory` | `PicStrip_Audit_<UUID>.json` | Session | Auto-deleted after session or export |
| Batch audit JSON (temporary) | `FileManager.default.temporaryDirectory` | `PicStrip_BatchAudit_<UUID>.json` | Session | Auto-deleted after session or export |

### Why Minimal Persistence?

- **Photo metadata:** Always re-extracted from the current image (no cache).
- **User preferences:** Toggles are ephemeral (reset between sessions); advanced options are specified per-export.
- **Scanned images:** Not stored; only detection results exist in memory.
- **Settings:** No user configuration beyond the above stats.

This **privacy-first design** ensures no historical data persists about what photos users have processed or what PII was detected.

---

## Privacy & Security

### PrivacyInfo.xcprivacy

Both the main app and Share Extension declare:

```xml
<key>NSPrivacyTracking</key>
<false/>

<key>NSPrivacyCollectedDataTypes</key>
<array/>

<key>NSPrivacyTrackingDomains</key>
<array/>
```

**Zero data collection.** No analytics, no crash reporting, no telemetry.

### Required-Reason APIs

Only **one required-reason API** is declared:

| API | Reason | Why |
|-----|--------|-----|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | ImageIO reads file timestamps during metadata extraction (not for fingerprinting) |

All other frameworks (Vision, ImageIO for encoding, Photos) do not trigger required-reason APIs.

### Permissions Model

| Permission | Scope | When Used |
|-----------|-------|-----------|
| `NSPhotoLibraryAddUsageDescription` | Add-only | Saving cleaned photos (new asset) |
| `NSPhotoLibraryUsageDescription` | Read + write | "Replace Original" option (requires read access to delete original) |

The app defaults to **add-only** access (`.addOnly` in `PHAccessLevel`). Users must explicitly grant read+write if they want "Replace Original."

### On-Device Processing Guarantee

Every step of the pipeline runs locally:
1. **Image load:** `UIImage(data:)` (native iOS)
2. **Metadata extraction:** ImageIO (native iOS)
3. **OCR:** Vision framework (on-device, local model)
4. **Regex matching:** `NSRegularExpression` (native iOS)
5. **Image encoding:** ImageIO + CoreGraphics (native iOS)

**Zero network calls.** Network Inspector (in Xcode) will show zero outbound connections from the app.

---

## CI/CD Pipeline

### Workflows Overview

#### 1. PR Workflow (`pr.yml`)

Runs on every pull request targeting `main`:

```yaml
jobs:
  lint:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: fastlane lint

  analyze:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: fastlane analyze

  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: fastlane test
      - uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: fastlane/test_output/report.junit
```

#### 2. Main Workflow (`main.yml`)

Runs on every push to `main`. Six sequential jobs:

| Job | Command | Output |
|-----|---------|--------|
| **version** | `semantic-release --dry-run` | Determines if release warranted |
| **build** | `fastlane beta` | Signs, builds, uploads to TestFlight; computes IPA SHA-256 |
| **screenshots** | `fastlane screenshots` | Captures App Store screenshots |
| **release** | `semantic-release` | Publishes release, tags, updates CHANGELOG, patches version |
| **provenance** | SLSA generator | Generates SLSA Level 3 attestation |
| **attach-release-assets** | Upload to release | Attaches IPA + .sha256 to GitHub Release |

### Fastlane Lanes

| Lane | Purpose |
|------|---------|
| `lint` | SwiftLint strict mode; fails on warnings |
| `analyze` | `xcodebuild analyze` static analysis; flags potential bugs |
| `test` | Runs unit tests on iPhone 16 simulator; outputs JUnit XML |
| `certificates` | `fastlane match appstore` for code signing (readonly on CI) |
| `build` | Increments build number, exports IPA with App Store signing |
| `beta` | `certificates` + `build` + `pilot` (TestFlight upload) |
| `screenshots` | `capture_ios_screenshots` using Snapfile configuration |
| `upload_screenshots` | Uploads screenshots to App Store Connect |

### Semantic Release

Commits follow **Conventional Commits**:

```
feat: Add dark mode toggle
fix: Correct metadata stripping for HEIC format
perf: Optimize OCR performance
BREAKING CHANGE: Remove support for iOS 16
```

Rules:
- `feat:` → minor version bump (e.g., 1.0.0 → 1.1.0)
- `fix:` / `perf:` / `revert:` → patch bump (e.g., 1.0.0 → 1.0.1)
- `BREAKING CHANGE:` anywhere → major bump (e.g., 1.0.0 → 2.0.0)

On release, a `sed` command patches `MARKETING_VERSION` in `project.pbxproj`:
```sh
sed -i 's/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${nextRelease.version}/' PicStrip.xcodeproj/project.pbxproj
```

### SLSA Provenance (Level 3)

PicStrip generates a **SLSA Level 3 provenance attestation** for every IPA release using the `slsa-framework/slsa-github-generator` action. This cryptographically proves that the binary you download was built by our CI/CD pipeline with no manual modifications or post-build tampering.

#### What Is SLSA?

**SLSA** (Supply Chain Levels for Software Artifacts) is a security framework developed by Google and the Linux Foundation that establishes increasing levels of confidence in software artifact provenance.

| Level | Requirements | Security Guarantee |
|-------|--------------|-------------------|
| **Level 0** | No provenance | No assurances |
| **Level 1** | Provenance exists | Proof of existence (basic metadata) |
| **Level 2** | Version control + hosted CI | Proof of source and build environment |
| **Level 3** | Hardened CI + hermetic builds | Protection against tampering by insider threats |
| **Level 4** | Cryptographic verification | Protection against tampering by CI/CD admins |

**PicStrip achieves Level 3**, which means:
- ✅ Source code is hosted on GitHub with signed commits
- ✅ Builds run on GitHub Actions infrastructure (not a developer's local machine)
- ✅ Build process is deterministic and can be audited
- ✅ Attestation is cryptographically signed by GitHub
- ✅ IPA SHA-256 checksum is cryptographically bound to the build

#### SLSA Level 3 Attestation Structure

Every release generates a Rekor-signed SLSA v0.2 provenance attestation:

```json
{
  "subject": [
    {
      "name": "PicStrip.ipa",
      "digest": {
        "sha256": "abc123def456789..."
      }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "predicate": {
    "builder": {
      "id": "https://github.com/slsa-framework/slsa-github-generator@v1.9.0"
    },
    "buildType": "https://github.com/slsa-framework/slsa-github-generator/blob/main/internal/builders/github/github.go",
    "invocation": {
      "configSource": {
        "uri": "git+https://github.com/northcutt-dev/picstrip.git@refs/heads/main",
        "digest": { "sha1": "abc123..." }
      },
      "parameters": {
        "workflow": "main.yml",
        "ref": "refs/tags/v1.2.3"
      }
    },
    "materials": [
      {
        "uri": "git+https://github.com/northcutt-dev/picstrip.git",
        "digest": { "sha1": "abc123..." }
      }
    ],
    "metadata": {
      "buildStartedOn": "2024-05-04T12:30:00Z",
      "buildFinishedOn": "2024-05-04T12:45:00Z",
      "completeness": {
        "parameters": true,
        "environment": true,
        "materials": true
      },
      "reproducible": false
    },
    "byproducts": []
  }
}
```

#### What Each Field Proves

| Field | What It Proves |
|-------|---|
| `subject.name` | The exact IPA filename |
| `subject.digest.sha256` | Cryptographic fingerprint of the IPA (prevents tampering) |
| `builder.id` | The build system identity (SLSA generator + version) |
| `buildType` | The canonical build recipe/workflow |
| `invocation.configSource.uri` | The GitHub repo URL and branch/tag |
| `invocation.configSource.digest` | Commit SHA of the build workflow |
| `invocation.parameters.workflow` | The workflow file name (main.yml) |
| `materials` | The exact git commit of the source code built |
| `metadata.buildStartedOn/FinishedOn` | Precise timestamps (auditable timing) |
| `metadata.completeness` | Attestation is complete (all required fields present) |

#### How SLSA Prevents Tampering

1. **Post-Build Tampering**: The SHA-256 in the attestation cryptographically commits to the IPA. Any byte change → different SHA-256 → attestation invalid.
2. **Insider Threats**: The attestation is signed by Rekor (a public transparency log), making it immutable even if the GitHub repo is compromised.
3. **Build Injection**: The workflow file is pinned to a specific commit SHA; if the workflow is modified, the digest no longer matches.
4. **Source Tampering**: The source materials list includes the exact commit SHA of the code that was compiled.

#### How to Verify the Attestation

##### Option 1: Manual Verification Using `slsa-verifier`

Install `slsa-verifier`:
```bash
# macOS
brew install slsa-framework/slsa/slsa-verifier

# Or build from source
go install github.com/slsa-framework/slsa-verifier/cmd/slsa-verifier@v2.0.1
```

Download the IPA and attestation from the GitHub Release:
```bash
# From the release page, download:
# - PicStrip.ipa
# - PicStrip.ipa.attestation (or PicStrip.ipa.slsaprovenance.json)
```

Verify the IPA:
```bash
slsa-verifier verify-artifact PicStrip.ipa \
  --provenance-path PicStrip.ipa.attestation \
  --source-uri github.com/northcutt-dev/picstrip \
  --source-tag v1.2.3
```

Expected output:
```
Verified SLSA provenance for PicStrip.ipa
Verified that PicStrip.ipa was built by github.com/slsa-framework/slsa-github-generator
Verified that the source code was built from the GitHub branch main
Verified that the build was run using the GitHub Actions workflow main.yml
```

##### Option 2: Verify SHA-256 Checksum

Every release includes a `.sha256` file with the IPA checksum:

```bash
# Download both PicStrip.ipa and PicStrip.ipa.sha256
shasum -a 256 PicStrip.ipa > computed.sha256
diff computed.sha256 PicStrip.ipa.sha256
# If no output, checksums match ✅
```

##### Option 3: Check Rekor Transparency Log

The attestation is logged on Rekor (a public, immutable ledger):

```bash
# Verify via Rekor
rekor-cli search \
  --artifact PicStrip.ipa \
  --pki-format=x509 \
  --public-key=/path/to/github-public-key.pem
```

Or view in the web UI: https://search.sigstore.dev/?logIndex=<index>

#### Integration with App Store & TestFlight

- **TestFlight**: The signed IPA + attestation are uploaded to App Store Connect, providing proof of origin.
- **App Store**: Once approved, the app is notarized by Apple; the SLSA attestation remains as proof of the original source.
- **Users**: Although end users receive the app through Apple's official channels, transparency-conscious users and security auditors can verify the provenance chain.

#### Practical Workflow for Developers

1. **Every Release:** GitHub Actions automatically generates and attaches the attestation to the release.
2. **CI/CD Transparency:** The workflow log is public; anyone can see the exact build command, environment, and output.
3. **Artifact Immutability:** Once published, the SHA-256 + attestation binding is immutable (Rekor transparency log).
4. **Audit Trail:** All commits, tags, and workflow runs are auditable on GitHub.

#### References

- **SLSA Specification:** https://slsa.dev/
- **SLSA GitHub Generator:** https://github.com/slsa-framework/slsa-github-generator
- **slsa-verifier:** https://github.com/slsa-framework/slsa-verifier
- **Rekor Transparency Log:** https://transparency.sigstore.dev/
- **Sigstore:** https://sigstore.dev/ (end-to-end provenance & signing)

---

## Contributing: Adding a New PII Type

### Step 1: Define the PII Type

Add to `PIITypes.swift`:

```swift
enum PIIType: String, CaseIterable {
    case email, phone, ssn, creditCard, apiKey, jwt, privateKey, password, databaseConnection, awsKey, oauthToken, slackToken, githubToken, licenseKey, uuid, urls, addresses, blockchainAddress, socialSecurityCard, dateOfBirth
    
    // ADD HERE:
    case bankRoutingNumber  // New type
    
    var displayName: String {
        switch self {
        case .email: return "Email Address"
        case .phone: return "Phone Number"
        // ...
        case .bankRoutingNumber: return "Bank Routing Number"
        }
    }
}
```

### Step 2: Add a Detection Rule

In `DetectionRegistry.swift`, add a new `DetectionRule`:

```swift
enum DetectionRegistry {
    static let allRules: [DetectionRule] = [
        // ... existing rules ...
        
        DetectionRule(
            type: .bankRoutingNumber,
            pattern: try! NSRegularExpression(
                pattern: "\\d{9}",  // US routing numbers are 9 digits
                options: []
            ),
            baseScore: 0.85  // High confidence, but not as high as credit card (SSN-like)
        ),
    ]
}
```

### Step 3: Update the UI

In `PIIDetailsView.swift`, the detection result already iterates all `PIIType` cases, so the new type will automatically appear in the list.

Optional: Add a custom color in `CategoryBadgeView.swift`:

```swift
func badgeColor(for type: PIIType) -> Color {
    switch type {
    case .email: return Color.blue
    case .phone: return Color.green
    // ...
    case .bankRoutingNumber: return Color.purple
    }
}
```

### Step 4: Write Tests

In `PIIScannerTests.swift`, add a test case:

```swift
func testDetectsBankRoutingNumbers() async {
    let image = createTestImage(withText: "Routing: 021000021")
    let result = await PIIScanner.scanImage(image.cgImage!)
    
    XCTAssertTrue(result[.bankRoutingNumber]!.matchCount > 0)
    XCTAssertGreaterThan(result[.bankRoutingNumber]!.bestScore, 0.7)
}
```

### Step 5: Test End-to-End

1. Rebuild the app: **Cmd + B**
2. Create a test image (or screenshot) containing a bank routing number.
3. Run the app, pick the test image.
4. Verify the routing number is detected and highlighted in red.
5. Verify the "Bank Routing Number" category appears in the metadata badge row.
6. Toggle redaction and verify the black box lands on the number in the saved image.

---

## Known Constraints

### Share Extension Memory Ceiling

The Share Extension process has a **~120 MB memory limit** imposed by iOS. Mitigations:
- Sequential image processing (no concurrent Tasks).
- Explicit buffer deallocation between images.
- Smaller image resolution for preview/processing.

If processing large burst photos, users may see out-of-memory errors. Document this in the app's help text.

### Structural Metadata Fields

These fields **cannot be stripped** because the iOS encoder unconditionally re-injects them:
- `PixelWidth`, `PixelHeight` (dimensions)
- `Orientation` (1 = canonical, required by format spec)
- `ColorModel`, `XResolution`, `YResolution` (format metadata)

The UI marks these with a lock icon and explains they contain no personal data. Users cannot toggle them off.

### OCR Language Correction

Vision's `VNRecognizeTextRequest` has a `usesLanguageCorrection` option. PicStrip sets it to **false** because:
- If an image contains a password or API key, language correction might "normalize" it incorrectly.
- E.g., `api_sk_live_abc123xyz` might be auto-corrected to English-like words.

This trade-off prioritizes **raw accuracy** over readability.

### Two-Pass Encoding Overhead

The two-pass ImageIO strategy adds ~50–100 ms to export time (negligible on modern devices). It is **not optional** because:
- Single-pass re-encode still triggers auto-synthesis of minimal EXIF on iOS.
- Two-pass defeats this by force-reloading pixels.

If performance becomes a bottleneck, profile with Xcode Instruments; do not remove the two-pass logic.

### Batch Processing Sequential Design

Batch processing is deliberately **sequential** (not concurrent) to avoid OOM. On a device with limited memory:
- Concurrent processing of 10 4 MP photos = 10 × (4 MB + Vision overhead) = 40+ MB peak.
- Sequential processing = ~4 MB peak.

The trade-off is slower batch processing on modern devices (each image takes 2–5 seconds). This is acceptable for privacy-critical use cases.

---

## Summary

PicStrip is a minimal, privacy-focused app built with:
- **MVVM architecture** using Swift `@Observable` and `async/await`.
- **Zero third-party dependencies.**
- **Entirely on-device processing** with no network calls.
- **Comprehensive metadata extraction and stripping** via two-pass ImageIO encoding.
- **Multi-stage PII detection** combining Vision OCR, regex, and NSDataDetector.
- **Batch processing** with sequential, memory-conscious design.
- **Automated CI/CD** with semantic versioning, SLSA provenance, and TestFlight distribution.

For questions or contributions, see the main [README.md](README.md) and open an issue on GitHub.
