import UniformTypeIdentifiers

// MARK: - ExportFormat

/// Simple four-way format choice exposed in the UI.
/// Maps to an `ExportPreset` for the stripping engine.
/// Cases are ordered for display: lossless first.
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
        case .png:      return String(localized: "Lossless quality for screenshots and text. Larger files.")
        case .jpeg:     return String(localized: "Smaller files for everyday photos. Widely supported.")
        case .heic:     return String(localized: "Compact photos with high quality. Check receiver compatibility.")
        case .original: return String(localized: "Re-encodes in the source format when supported.")
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

/// What the stripping engine encodes to.  Users choose an `ExportFormat`;
/// this is the engine-side meaning of that choice.
nonisolated enum ExportPreset: Sendable {
    /// Re-encode in the same format as the source image.
    case matchSource
    case highQualityJPEG
    case losslessPNG
    case heicOriginal

    // MARK: - Output format

    /// The concrete UTType for this preset.
    /// Returns `nil` for `.matchSource` — the caller must resolve the type from the source image.
    var utType: UTType? {
        switch self {
        case .matchSource:      return nil
        case .highQualityJPEG:  return .jpeg
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
        case .losslessPNG:      return 1.0
        case .heicOriginal:     return 0.8
        }
    }
}
