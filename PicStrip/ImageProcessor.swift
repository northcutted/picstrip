import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Strip configuration

/// Controls which metadata categories are removed during processing.
///
/// Category-level switches are checked first. If a category is disabled the
/// entire sub-dictionary is preserved. If it is enabled, individual field
/// overrides (`fieldOverrides`) can still preserve specific keys.
///
/// Field override keys use the compound format `"<Category>.<KeyName>"`,
/// e.g. `"GPS.GPSLatitude"`. A value of `false` means "keep this field".
struct StripConfig {
    /// Per-category enable flags. `true` = strip the whole category.
    var categoryEnabled: [String: Bool]

    /// Per-field overrides within enabled categories.
    /// Key format: `"<Category>.<FieldKey>"`. `false` = preserve this field.
    var fieldOverrides: [String: Bool]

    /// Privacy-first default: strip everything.
    static let `default` = StripConfig(
        categoryEnabled: [
            "GPS": true,
            "EXIF": true,
            "EXIF Auxiliary": true,
            "TIFF": true,
            "IPTC": true,
            "Apple Maker Note": true
        ],
        fieldOverrides: [:]
    )

    /// Alias for batch processing — semantically identical to `.default` but
    /// named for clarity at the call-site: "strip every known category".
    static let allEnabled = StripConfig(
        categoryEnabled: [
            "GPS": true,
            "EXIF": true,
            "EXIF Auxiliary": true,
            "TIFF": true,
            "IPTC": true,
            "Apple Maker Note": true
        ],
        fieldOverrides: [:]
    )

    /// Returns `true` if `field` should be stripped given the current config.
    func shouldStrip(category: String, key: String) -> Bool {
        guard categoryEnabled[category] == true else { return false }
        let compoundKey = "\(category).\(key)"
        // An explicit `false` override means "keep this field".
        return fieldOverrides[compoundKey] != false
    }

    /// Returns `true` when a source metadata field should be written back into
    /// the output file. A disabled category preserves all supported fields; an
    /// enabled category preserves only fields with an explicit "keep" override.
    func shouldPreserve(category: String, key: String) -> Bool {
        let compoundKey = "\(category).\(key)"
        if categoryEnabled[category] == true {
            return fieldOverrides[compoundKey] == false
        }
        return fieldOverrides[compoundKey] != true
    }
}

// MARK: - Metadata value types

/// A single metadata field that was present in the source image and stripped during processing.
struct MetadataField: Identifiable {
    let id: UUID = UUID()
    /// Human-readable category, e.g. "GPS", "EXIF", "TIFF", "IPTC", "Apple Maker Note".
    let category: String
    /// The raw key name, e.g. "GPSLatitude", "DateTimeOriginal".
    let key: String
    /// The original value rendered as a human-readable string.
    let value: String
    /// `true` when this field is a structural rendering requirement (e.g. ColorSpace,
    /// XResolution) that ImageIO re-synthesises unconditionally.  These fields are
    /// displayed for transparency but cannot be stripped — the toggle is replaced with
    /// a read-only lock indicator in the UI.
    let isStructural: Bool

    init(category: String, key: String, value: String, isStructural: Bool = false) {
        self.category     = category
        self.key          = key
        self.value        = value
        self.isStructural = isStructural
    }
}

/// The complete set of metadata fields removed from a source image during a processing run.
struct StrippedMetadata {
    let fields: [MetadataField]

    /// Convenience: fields grouped by category, preserving category insertion order.
    var byCategory: [(category: String, fields: [MetadataField])] {
        var order: [String] = []
        var groups: [String: [MetadataField]] = [:]
        for field in fields {
            if groups[field.category] == nil {
                order.append(field.category)
                groups[field.category] = []
            }
            groups[field.category, default: []].append(field)
        }
        return order.compactMap { category in
            groups[category].map { fields in (category: category, fields: fields) }
        }
    }

    var isEmpty: Bool { fields.isEmpty }
}

struct ProcessedImage {
    let data: Data
    let sourceType: UTType
    let stripped: StrippedMetadata
}

// MARK: - Processing engine

/// A stateless image processing engine responsible for stripping private metadata
/// from image data and re-encoding it according to an `ExportPreset`.
///
/// All methods are static; no instances of this type should be created.
enum ImageProcessor {

    // MARK: - Errors

    enum ProcessingError: LocalizedError {
        case sourceCreationFailed
        case imageDecodingFailed
        case destinationCreationFailed
        case finalizationFailed
        case unsupportedSourceFormat

        var errorDescription: String? {
            switch self {
            case .sourceCreationFailed:
                return "Could not create a CGImageSource from the supplied data. The data may be corrupt or an unsupported format."
            case .imageDecodingFailed:
                return "Could not decode pixel data from the image source."
            case .destinationCreationFailed:
                return "Could not create a CGImageDestination for the requested output format."
            case .finalizationFailed:
                return "CGImageDestination finalization failed. The image could not be encoded."
            case .unsupportedSourceFormat:
                return "The source image format is not supported for re-encoding."
            }
        }
    }

    // MARK: - Metadata catalogue

    /// Ordered list of (ImageIO property dict key, human-readable category name) pairs.
    /// Order determines display order in the UI.
    static let categoryMap: [(key: CFString, category: String)] = [
        (kCGImagePropertyGPSDictionary, "GPS"),
        (kCGImagePropertyExifDictionary, "EXIF"),
        (kCGImagePropertyExifAuxDictionary, "EXIF Auxiliary"),
        (kCGImagePropertyTIFFDictionary, "TIFF"),
        (kCGImagePropertyIPTCDictionary, "IPTC"),
        (kCGImagePropertyMakerAppleDictionary, "Apple Maker Note")
    ]

    /// Keys that ImageIO unconditionally re-synthesises into any JPEG/HEIC it produces,
    /// regardless of `kCGImageDestinationMergeMetadata: false`.  These are structural
    /// rendering requirements (colour space, dimensions, resolution, orientation) —
    /// not privacy-sensitive data.  They are excluded from the UI catalogue so the
    /// app never falsely claims it can strip them, and so an image with *only* these
    /// fields correctly reports "0 fields to remove".
    static let structuralKeys: Set<String> = [
        // ── Root-level properties injected by the iOS encoder ──────────────────
        // These live at the top of the CGImageSource dictionary, not inside any
        // sub-dictionary.  They are format/rendering metadata, not personal data.
        kCGImagePropertyPixelWidth   as String,  // "PixelWidth"
        kCGImagePropertyPixelHeight  as String,  // "PixelHeight"
        kCGImagePropertyColorModel   as String,  // "ColorModel"
        kCGImagePropertyDepth        as String,  // "Depth"
        kCGImagePropertyHasAlpha     as String,  // "HasAlpha"
        kCGImagePropertyOrientation  as String,  // "Orientation"  (root alias)
        kCGImagePropertyProfileName  as String,  // "ProfileName"
        kCGImagePropertyDPIWidth     as String,  // "DPIWidth"
        kCGImagePropertyDPIHeight    as String,  // "DPIHeight"
        kCGImagePropertyFileSize     as String,  // "FileSize"
        // ── TIFF sub-dictionary — strictly rendering requirements only ──────────
        // kCGImagePropertyTIFFSoftware is intentionally excluded: it reveals
        // the user's editing workflow ("PicMonkey.com", etc.) and is strippable.
        kCGImagePropertyTIFFOrientation     as String,  // "Orientation"
        kCGImagePropertyTIFFXResolution     as String,  // "XResolution"
        kCGImagePropertyTIFFYResolution     as String,  // "YResolution"
        kCGImagePropertyTIFFResolutionUnit  as String,  // "ResolutionUnit"
        // ── EXIF sub-dictionary ─────────────────────────────────────────────────
        kCGImagePropertyExifColorSpace           as String,  // "ColorSpace"
        kCGImagePropertyExifPixelXDimension      as String,  // "PixelXDimension"
        kCGImagePropertyExifPixelYDimension      as String,  // "PixelYDimension"
        // OS-mandated EXIF version strings — ImageIO injects these unconditionally
        // to keep the JPEG/HEIC container spec-valid.
        kCGImagePropertyExifVersion              as String,  // "ExifVersion"
        kCGImagePropertyExifFlashPixVersion      as String,  // "FlashPixVersion"
        kCGImagePropertyExifComponentsConfiguration as String // "ComponentsConfiguration"
    ]

    /// Returns `true` when a category can be written back through the XMP
    /// metadata APIs used by the safe two-pass encoder.
    static func canPreserveMetadata(category: String) -> Bool {
        guard let entry = categoryMap.first(where: { $0.category == category }) else { return false }
        return xmpNamespace(for: entry.key) != nil
    }

    /// Returns `true` when a field should be reported as stripped in review and
    /// audit output. Unsupported categories remain reported even if the user tried
    /// to keep them, because ImageIO cannot safely re-inject those dictionaries.
    static func shouldReportStripped(
        category: String,
        key: String,
        isStructural: Bool,
        config: StripConfig
    ) -> Bool {
        guard !isStructural else { return false }
        if config.shouldStrip(category: category, key: key) { return true }
        let compoundKey = "\(category).\(key)"
        return config.fieldOverrides[compoundKey] == false && !canPreserveMetadata(category: category)
    }

    // MARK: - Public API

    /// Strips private metadata from `data`, re-encodes the image using `preset`, and
    /// returns the scrubbed `Data`, the detected source `UTType`, and a `StrippedMetadata`
    /// record of what was (or will be) removed given `config`.
    ///
    /// ## Strategy
    ///
    /// **Pass 1** — Decode the source to raw pixels (`CGImageSourceCreateImageAtIndex`)
    /// and re-encode with `CGImageDestinationAddImage`. This removes user-written EXIF
    /// fields but ImageIO auto-synthesises a minimal EXIF block for JPEG/HEIC output
    /// (ColorSpace, PixelXDimension, PixelYDimension).
    ///
    /// **Pass 2** — Use `CGImageDestinationCopyImageSource` with:
    ///   - `kCGImageDestinationMetadata`: a `CGMutableImageMetadata` containing *only*
    ///     the tags we explicitly want to preserve (orientation + any fields kept by config).
    ///   - `kCGImageDestinationMergeMetadata: false`: wipes the auto-synthesised EXIF block.
    ///
    /// - Parameters:
    ///   - data:   Raw image bytes in any format supported by `ImageIO`.
    ///   - preset: The `ExportPreset` controlling output format and compression quality.
    ///             `.matchSource` resolves the UTType from the source image.
    ///   - config: Controls which metadata categories and fields are stripped.
    ///             Defaults to `StripConfig.default` (strip everything).
    /// - Returns: A tuple of the scrubbed `Data`, the resolved source `UTType`,
    ///            and a `StrippedMetadata` record.
    /// - Throws: `ProcessingError` if any `ImageIO` operation fails.
    static func process(
        data: Data,
        preset: ExportPreset,
        config: StripConfig = .default
    ) throws -> ProcessedImage {
        guard let uiImage = UIImage(data: data),
              let cgImage = uiImage.normalized().cgImage else {
            throw ProcessingError.imageDecodingFailed
        }

        return try process(
            cgImage: cgImage,
            sourceData: data,
            preset: preset,
            config: config
        )
    }

    /// Re-encodes an already-rendered image while using metadata from the
    /// original source bytes. This is used after visual redaction so export
    /// changes never fall back to the unredacted source image.
    static func process(
        image: UIImage,
        sourceData: Data,
        preset: ExportPreset,
        config: StripConfig = .default
    ) throws -> ProcessedImage {
        guard let cgImage = image.normalized().cgImage else {
            throw ProcessingError.imageDecodingFailed
        }

        return try process(
            cgImage: cgImage,
            sourceData: sourceData,
            preset: preset,
            config: config
        )
    }

    private static func process(
        cgImage: CGImage,
        sourceData: Data,
        preset: ExportPreset,
        config: StripConfig
    ) throws -> ProcessedImage {

        // 1. Create a CGImageSource from the original bytes. The source supplies
        //    both format selection for .matchSource and the metadata catalogue.
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw ProcessingError.sourceCreationFailed
        }

        // 2. Resolve the output UTType.
        let outputUTType: UTType
        let sourceUTType: UTType
        if let cfType = CGImageSourceGetType(source),
           let detected = UTType(cfType as String) {
            sourceUTType = detected
        } else {
            sourceUTType = .jpeg
        }

        if let explicitType = preset.utType {
            outputUTType = explicitType
        } else {
            outputUTType = (sourceUTType == .heic || sourceUTType == .jpeg || sourceUTType == .png)
                ? sourceUTType
                : .jpeg
        }

        let quality: Double
        if preset == .matchSource {
            quality = (outputUTType == .jpeg || outputUTType == .heic) ? 0.95 : 1.0
        } else {
            quality = preset.compressionQuality
        }

        // 3. Read the full source properties and catalogue every field that will
        //    be stripped given the config.
        let existingProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let stripped = catalogueStrippedMetadata(from: existingProps, config: config)

        // 6. Pass 1: encode pixels with compression quality.
        //    ImageIO will auto-synthesise a minimal EXIF block; scrubbed in pass 2.
        let firstBuffer = NSMutableData()
        guard let firstDest = CGImageDestinationCreateWithData(
            firstBuffer,
            outputUTType.identifier as CFString,
            1,
            nil
        ) else {
            throw ProcessingError.destinationCreationFailed
        }

        // "Hail Mary" encoder hardening: pass empty dictionaries for {Exif} and {TIFF}
        // to signal ImageIO that these blocks should be zeroed out rather than
        // auto-synthesised.  An empty dict is more aggressively respected than
        // kCFNull for individual keys — it tells the encoder there is nothing to write
        // in those sub-dictionaries at all.  Pass 2 (MergeMetadata: false) wipes
        // whatever survives anyway, but belt-and-suspenders here minimises ghost fields
        // in the intermediate firstBuffer that could be copied across unexpectedly.
        let encodeProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyExifDictionary: [:] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [:] as [CFString: Any]
        ]
        CGImageDestinationAddImage(firstDest, cgImage, encodeProps as CFDictionary)
        guard CGImageDestinationFinalize(firstDest) else {
            throw ProcessingError.finalizationFailed
        }

        // 7. Build a CGMutableImageMetadata containing:
        //    a) orientation = 1 (pixels are already display-oriented after UIImage decode)
        //    b) any metadata sub-dictionaries that the config says to KEEP (category disabled)
        //
        //    kCGImageDestinationMergeMetadata: false in pass 2 wipes everything ImageIO
        //    auto-synthesised, so we must explicitly re-inject anything we want to survive.
        //
        //    PNG optimisation: PNG has no native EXIF/TIFF block — keep metadata entirely
        //    empty for PNG output so the file is as flat as possible.
        let outputMetadata = CGImageMetadataCreateMutable()

        if outputUTType != .png {
            // a) Always write orientation 1 — pixels are display-oriented from UIImage.normalized().
            if let tag = CGImageMetadataTagCreate(
                kCGImageMetadataNamespaceTIFF as CFString,
                kCGImageMetadataPrefixTIFF,
                kCGImagePropertyTIFFOrientation as CFString,
                .string,
                "1" as CFTypeRef
            ) {
                CGImageMetadataSetTagWithPath(outputMetadata, nil, "tiff:Orientation" as CFString, tag)
            }

            // b) Re-inject any category or individual field the user chose to keep.
            //    Walk categoryMap so we handle each dict in a consistent order.
            if let props = existingProps {
                for (dictKey, category) in categoryMap {
                    guard let subDict = props[dictKey] as? [CFString: Any] else { continue }

                    // Map each ImageIO property dict key to its XMP path components.
                    // CGImageMetadata uses XMP namespaces; we only need to handle the
                    // dicts users are likely to preserve (GPS is the main one).
                    guard let (namespace, prefix) = xmpNamespace(for: dictKey) else { continue }

                    for (fieldKey, fieldValue) in subDict {
                        let keyStr = fieldKey as String
                        guard config.shouldPreserve(category: category, key: keyStr) else { continue }

                        guard let tag = CGImageMetadataTagCreate(
                            namespace as CFString,
                            prefix as CFString,
                            fieldKey,
                            .string,
                            "\(fieldValue)" as CFTypeRef
                        ) else { continue }

                        let path = "\(prefix):\(keyStr)" as CFString
                        CGImageMetadataSetTagWithPath(outputMetadata, nil, path, tag)
                    }
                }
            }
        }

        // 8. Pass 2: replace all metadata with our controlled metadata object.
        guard let cleanSource = CGImageSourceCreateWithData(firstBuffer, nil) else {
            throw ProcessingError.sourceCreationFailed
        }

        let finalBuffer = NSMutableData()
        guard let finalDest = CGImageDestinationCreateWithData(
            finalBuffer,
            outputUTType.identifier as CFString,
            1,
            nil
        ) else {
            throw ProcessingError.destinationCreationFailed
        }

        let copyOptions: [CFString: Any] = [
            kCGImageDestinationMetadata: outputMetadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageDestinationLossyCompressionQuality: quality
        ]

        var copyError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            finalDest,
            cleanSource,
            copyOptions as CFDictionary,
            &copyError
        ) else {
            throw ProcessingError.finalizationFailed
        }

        return ProcessedImage(data: finalBuffer as Data, sourceType: sourceUTType, stripped: stripped)
    }

    // MARK: - Metadata catalogue (public for preview use)

    /// Returns every metadata field present in `data` as decoded by ImageIO, with no
    /// strip-config filtering.  Used to read the *output* file and compare it against
    /// the source so the UI can identify encoder-injected fields.
    ///
    /// Two-pass walk:
    ///   **Step A** — Root-level primitives (PixelWidth, ColorModel, Depth, etc.).
    ///               The iOS encoder injects these directly into the top-level dict,
    ///               bypassing any sub-dictionary.  They are filed under "General".
    ///   **Step B** — Sub-dictionary properties (TIFF, EXIF, GPS, …) via `categoryMap`.
    ///
    /// - Parameter data: Any image bytes supported by ImageIO.
    /// - Returns: All key/value pairs found in the image, with structural keys tagged
    ///            `isStructural: true`.  Fields are sorted by key for stable display.
    static func readAllFields(from data: Data) -> [MetadataField] {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [] }

        var fields: [MetadataField] = []

        // ── Step A: Root-level primitives ──────────────────────────────────────
        // Skip any value that is a dictionary — those belong to Step B.
        // NSDictionary covers all CF/Swift dict bridge forms ([CFString: Any], etc.)
        for (key, value) in props {
            guard !(value is NSDictionary) else { continue }
            let keyStr = key as String
            fields.append(MetadataField(
                category: "General",
                key: keyStr,
                value: "\(value)",
                isStructural: structuralKeys.contains(keyStr)
            ))
        }

        // ── Step B: Sub-dictionary properties (TIFF, EXIF, GPS, …) ───────────
        for (dictKey, category) in categoryMap {
            guard let subDict = props[dictKey] as? [CFString: Any] else { continue }
            for (fieldKey, fieldValue) in subDict {
                let keyStr = fieldKey as String
                fields.append(MetadataField(
                    category: category,
                    key: keyStr,
                    value: "\(fieldValue)",
                    isStructural: structuralKeys.contains(keyStr)
                ))
            }
        }

        // ── Deduplication ─────────────────────────────────────────────────────
        // ImageIO mirrors some keys (e.g. "Orientation") into both the root dict
        // and a sub-dictionary ({TIFF}).  Prefer the sub-dict version — it carries
        // the correct category name.  Walk all fields and let sub-dict entries
        // overwrite root ("General") entries for the same key string.
        var byKey: [String: MetadataField] = [:]
        for field in fields {
            if byKey[field.key] == nil || field.category != "General" {
                byKey[field.key] = field
            }
        }

        // Stable display order: General first, then by category, then by key.
        return byKey.values.sorted {
            if $0.category != $1.category {
                return $0.category == "General" || $0.category < $1.category
            }
            return $0.key < $1.key
        }
    }
    /// inside the metadata sub-dictionaries that *will* be stripped given `config`.
    ///
    /// This is also called by `ScrubberViewModel` to produce `pendingStrippedMetadata`
    /// without running the full encode pipeline.
    static func catalogueStrippedMetadata(
        from props: [CFString: Any]?,
        config: StripConfig = .default
    ) -> StrippedMetadata {
        guard let props else { return StrippedMetadata(fields: []) }

        var fields: [MetadataField] = []

        // ── Step A: Root-level primitives ──────────────────────────────────────
        // PixelWidth, PixelHeight, ColorModel, Depth, etc. live at the top of the
        // root dictionary — not inside any sub-dict.  They are always structural
        // and never privacy-sensitive, so they are included unconditionally to
        // ensure allSourceMetadata covers the same scope as readAllFields.
        for (key, value) in props {
            guard !(value is NSDictionary) else { continue }
            let keyStr = key as String
            fields.append(MetadataField(
                category: "General",
                key: keyStr,
                value: stringify(value),
                isStructural: structuralKeys.contains(keyStr)
            ))
        }

        // ── Step B: Sub-dictionary properties (TIFF, EXIF, GPS, …) ───────────
        for (dictKey, category) in categoryMap {
            // Skip this category entirely if it is disabled.
            guard config.categoryEnabled[category] == true else { continue }

            guard let subDict = props[dictKey] as? [CFString: Any] else { continue }
            for (rawKey, rawValue) in subDict {
                let keyString    = rawKey as String
                let isStructural = structuralKeys.contains(keyString)
                // Honour per-field overrides (structural fields are never in fieldOverrides,
                // but the guard keeps the logic consistent).
                guard isStructural ||
                        shouldReportStripped(
                            category: category,
                            key: keyString,
                            isStructural: isStructural,
                            config: config
                        )
                else { continue }
                fields.append(MetadataField(
                    category: category,
                    key: keyString,
                    value: stringify(rawValue),
                    isStructural: isStructural
                ))
            }
        }

        // ── Deduplication ─────────────────────────────────────────────────────
        // Same strategy as readAllFields: sub-dict entries overwrite root ("General")
        // entries for the same key string, so "TIFF.Orientation" wins over
        // "General.Orientation".
        var byKey: [String: MetadataField] = [:]
        for field in fields {
            if byKey[field.key] == nil || field.category != "General" {
                byKey[field.key] = field
            }
        }

        // Stable sort: General first, then by category, then by key — matches readAllFields.
        let deduplicated = byKey.values.sorted {
            if $0.category != $1.category {
                return $0.category == "General" || $0.category < $1.category
            }
            return $0.key < $1.key
        }

        return StrippedMetadata(fields: deduplicated)
    }

    // MARK: - Private helpers

    /// Maps an ImageIO property dictionary key to its XMP (namespace, prefix) pair,
    /// used when re-injecting preserved metadata into CGMutableImageMetadata.
    /// Returns `nil` for dictionaries that have no direct XMP representation.
    private static func xmpNamespace(for dictKey: CFString) -> (namespace: String, prefix: String)? {
        switch dictKey {
        case kCGImagePropertyGPSDictionary:
            // GPS uses its own XMP sub-namespace under the EXIF namespace.
            return ("http://ns.adobe.com/exif/1.0/gps/", "exifGPS")
        case kCGImagePropertyExifDictionary:
            return (kCGImageMetadataNamespaceExif as String, kCGImageMetadataPrefixExif as String)
        case kCGImagePropertyTIFFDictionary:
            return (kCGImageMetadataNamespaceTIFF as String, kCGImageMetadataPrefixTIFF as String)
        case kCGImagePropertyIPTCDictionary:
            return (kCGImageMetadataNamespaceIPTCCore as String, kCGImageMetadataPrefixIPTCCore as String)
        default:
            // EXIF Auxiliary and Apple Maker Note don't map cleanly to XMP paths.
            return nil
        }
    }

    /// Renders an arbitrary property list value as a human-readable string.
    private static func stringify(_ value: Any) -> String {
        switch value {
        case let dict as [AnyHashable: Any]:
            return dict
                .sorted { "\($0.key)" < "\($1.key)" }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
        case let array as [Any]:
            return array.map { stringify($0) }.joined(separator: ", ")
        case let number as NSNumber:
            if number.doubleValue == number.doubleValue.rounded() &&
               abs(number.doubleValue) < 1_000_000 {
                return String(Int(number.doubleValue))
            }
            return number.stringValue
        default:
            return "\(value)"
        }
    }
}

// MARK: - UIImage orientation normalisation

private extension UIImage {
    /// Returns a new `UIImage` whose pixel data is in the canonical up orientation
    /// (imageOrientation == .up) by redrawing into a fresh CGContext.
    /// This ensures the CGImage we hand to ImageIO is already correctly oriented
    /// regardless of the source format (HEIC stores pixels in sensor orientation
    /// and relies on the EXIF tag to rotate on display).
    func normalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
