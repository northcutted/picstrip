# Image processing

[Developer guide](../../DEVELOPMENT.md)

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

The method is `@concurrent`, so it always runs off the caller's actor. It throws `invalidImageData` for undecodable bytes and `textRecognitionFailed` when neither OCR model could run — "could not look" is never reported as "found nothing". See [PII Detection Engine](pii-detection.md#pii-detection-engine) for the full pipeline.

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
