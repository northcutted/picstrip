import UniformTypeIdentifiers

// MARK: - ExportFormat

/// Simple four-way format choice exposed in the UI.
/// Maps to an `ExportPreset` for the stripping engine.
/// Cases are ordered for display: most private first.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png      = "png"
    case jpeg     = "jpeg"
    case heic     = "heic"
    case original = "original"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png:      return "PNG"
        case .jpeg:     return "JPEG"
        case .heic:     return "HEIC"
        case .original: return "Match Original"
        }
    }

    var description: String {
        switch self {
        case .png:      return "Maximum Privacy. Prevents OS from injecting format headers."
        case .jpeg:     return "Reduced file size. Standard compatibility."
        case .heic:     return "High efficiency. Apple OS may inject Maker data upon saving."
        case .original: return "Keeps original format. OS may re-encode and inject basic headers."
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
enum ExportPreset: String, Identifiable, CaseIterable {

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
        case .matchSource:      return "Same as Original"
        case .highQualityJPEG:  return "High Quality JPEG"
        case .webFriendlyJPEG:  return "Web-Friendly JPEG"
        case .losslessPNG:      return "Lossless PNG"
        case .heicOriginal:     return "HEIC"
        }
    }

    /// One-line description shown in the Advanced format picker.
    var description: String {
        switch self {
        case .matchSource:      return "Keeps the original file format"
        case .highQualityJPEG:  return "JPEG at 90 % quality — small file, excellent detail"
        case .webFriendlyJPEG:  return "JPEG at 60 % quality — optimised for sharing online"
        case .losslessPNG:      return "PNG with no quality loss — larger file"
        case .heicOriginal:     return "Apple HEIC — efficient compression, iOS/macOS native"
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
