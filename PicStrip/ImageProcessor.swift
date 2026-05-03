import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

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
            "GPS":              true,
            "EXIF":             true,
            "EXIF Auxiliary":   true,
            "TIFF":             true,
            "IPTC":             true,
            "Apple Maker Note": true,
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
            groups[field.category]!.append(field)
        }
        return order.map { (category: $0, fields: groups[$0]!) }
    }

    var isEmpty: Bool { fields.isEmpty }
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
        (kCGImagePropertyGPSDictionary,        "GPS"),
        (kCGImagePropertyExifDictionary,       "EXIF"),
        (kCGImagePropertyExifAuxDictionary,    "EXIF Auxiliary"),
        (kCGImagePropertyTIFFDictionary,       "TIFF"),
        (kCGImagePropertyIPTCDictionary,       "IPTC"),
        (kCGImagePropertyMakerAppleDictionary, "Apple Maker Note"),
    ]

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
    ) throws -> (data: Data, sourceType: UTType, stripped: StrippedMetadata) {

        // 1. Create a CGImageSource from the input bytes.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ProcessingError.sourceCreationFailed
        }

        // 2. Resolve the output UTType.
        //    For .matchSource, use the source image's type; fall back to JPEG.
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
            // .matchSource — mirror the source, but only use types we can encode.
            // HEIC sources stay HEIC; everything else falls back to JPEG.
            outputUTType = (sourceUTType == .heic || sourceUTType == .jpeg || sourceUTType == .png)
                ? sourceUTType
                : .jpeg
        }

        // Compression quality: for .matchSource use lossless-equivalent (1.0) so
        // we don't degrade the image beyond what format conversion requires.
        let quality: Double
        if preset == .matchSource {
            quality = (outputUTType == .jpeg || outputUTType == .heic) ? 0.95 : 1.0
        } else {
            quality = preset.compressionQuality
        }

        // 3. Read the full source properties — used for metadata diff.
        let existingProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        // 4. Catalogue every field that will be stripped given the config.
        let stripped = catalogueStrippedMetadata(from: existingProps, config: config)

        // 5. Decode via UIImage — this always applies the orientation transform,
        //    giving us correctly-oriented pixels regardless of source format (HEIC, JPEG, PNG).
        //    Then draw into a new CGContext to produce a canonical orientation=1 CGImage.
        guard let uiImage = UIImage(data: data),
              let cgImage = uiImage.normalized().cgImage else {
            throw ProcessingError.imageDecodingFailed
        }

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

        let encodeProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
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
        let outputMetadata = CGImageMetadataCreateMutable()

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

        // b) Re-inject any category the user chose to keep.
        //    Walk categoryMap so we handle each dict in a consistent order.
        if let props = existingProps {
            for (dictKey, category) in categoryMap {
                // If the category is enabled (strip it), skip — those fields are gone.
                guard config.categoryEnabled[category] != true else { continue }
                guard let subDict = props[dictKey] as? [CFString: Any] else { continue }

                // Map each ImageIO property dict key to its XMP path components.
                // CGImageMetadata uses XMP namespaces; we only need to handle the
                // dicts users are likely to preserve (GPS is the main one).
                guard let (namespace, prefix) = xmpNamespace(for: dictKey) else { continue }

                for (fieldKey, fieldValue) in subDict {
                    // Skip per-field overrides that say "strip this individual field".
                    let keyStr = fieldKey as String
                    if config.fieldOverrides["\(category).\(keyStr)"] == true { continue }

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
            kCGImageDestinationMetadata:                outputMetadata,
            kCGImageDestinationMergeMetadata:           false,
            kCGImageDestinationLossyCompressionQuality: quality,
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

        return (data: finalBuffer as Data, sourceType: sourceUTType, stripped: stripped)
    }

    // MARK: - Metadata catalogue (public for preview use)

    /// Walks the source properties dictionary and collects every key/value pair
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

        for (dictKey, category) in categoryMap {
            // Skip this category entirely if it is disabled.
            guard config.categoryEnabled[category] == true else { continue }

            guard let subDict = props[dictKey] as? [CFString: Any] else { continue }
            for (rawKey, rawValue) in subDict {
                let keyString = rawKey as String
                // Honour per-field overrides.
                guard config.shouldStrip(category: category, key: keyString) else { continue }
                let valueString = stringify(rawValue)
                fields.append(MetadataField(category: category, key: keyString, value: valueString))
            }
        }

        // Sort within each category by key name for deterministic display order.
        fields.sort {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.key < $1.key
        }

        return StrippedMetadata(fields: fields)
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
