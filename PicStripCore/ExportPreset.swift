import UniformTypeIdentifiers

// MARK: - ExportFormat

/// Simple four-way format choice exposed in the UI.
/// Maps to an `ExportPreset` for the stripping engine.
/// Cases are ordered for display: most private first.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case heic
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png:      return String(localized: "PNG")
        case .jpeg:     return String(localized: "JPEG")
        case .heic:     return String(localized: "HEIC")
        case .original: return String(localized: "Match Original")
        }
    }

    var description: String {
        switch self {
        case .png:      return String(localized: "Maximum Privacy. Prevents OS from injecting format headers.")
        case .jpeg:     return String(localized: "Reduced file size. Standard compatibility.")
        case .heic:     return String(localized: "High efficiency. Apple OS may inject Maker data upon saving.")
        case .original: return String(localized: "Keeps original format. OS may re-encode and inject basic headers.")
        }
    }

    /// Maps to the stripping engine's `ExportPreset`.
    var exportPreset: ExportPreset {
        switch self {
        case .png:      return .losslessPNG
        case .jpeg:     return .highQualityJPEG
        case .heic:     return .heicOriginal
        case .original: return .matchSource
        }
    }
}

// MARK: - ExportPreset
nonisolated enum ExportPreset: String, Identifiable, CaseIterable {

    private static func localizedJPEGDescription(quality: Double, detail: LocalizedStringResource) -> String {
        String(
            localized: "JPEG at \(quality, format: .percent.precision(.fractionLength(0))) quality — \(detail)"
        )
    }

    /// Re-encode in the same format as the source image (default).
    case matchSource      = "match_source"
    case highQualityJPEG  = "high_quality_jpeg"
    case webFriendlyJPEG  = "web_friendly_jpeg"
    case losslessPNG      = "lossless_png"
    case heicOriginal     = "heic_original"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Display

    var title: String {
        switch self {
        case .matchSource:      return String(localized: "Same as Original")
        case .highQualityJPEG:  return String(localized: "High Quality JPEG")
        case .webFriendlyJPEG:  return String(localized: "Web-Friendly JPEG")
        case .losslessPNG:      return String(localized: "Lossless PNG")
        case .heicOriginal:     return String(localized: "HEIC")
        }
    }

    /// One-line description shown in the Advanced format picker.
    var description: String {
        switch self {
        case .matchSource:      return String(localized: "Keeps the original file format")
        case .highQualityJPEG:
            return Self.localizedJPEGDescription(
                quality: 0.9,
                detail: "small file, excellent detail"
            )
        case .webFriendlyJPEG:
            return Self.localizedJPEGDescription(
                quality: 0.6,
                detail: "optimised for sharing online"
            )
        case .losslessPNG:      return String(localized: "PNG with no quality loss — larger file")
        case .heicOriginal:     return String(localized: "Apple HEIC — efficient compression, iOS/macOS native")
        }
    }

    // MARK: - Output format

    /// The concrete UTType for this preset.
    /// Returns `nil` for `.matchSource` — the caller must resolve the type from the source image.
    var utType: UTType? {
        switch self {
        case .matchSource:      return nil
        case .highQualityJPEG:  return .jpeg
        case .webFriendlyJPEG:  return .jpeg
        case .losslessPNG:      return .png
        case .heicOriginal:     return .heic
        }
    }

    // MARK: - Compression

    /// Value passed to `kCGImageDestinationLossyCompressionQuality`.
    /// PNG is lossless; the value is included for API uniformity but has no effect on PNG output.
    var compressionQuality: Double {
        switch self {
        case .matchSource:      return 1.0   // deferred to source-format logic
        case .highQualityJPEG:  return 0.9
        case .webFriendlyJPEG:  return 0.6
        case .losslessPNG:      return 1.0
        case .heicOriginal:     return 0.8
        }
    }
}
