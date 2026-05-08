import CoreGraphics
import Foundation

// MARK: - ConfidenceLevel

/// Represents how certain the scanner is that a detection is a true positive.
///
/// Derived from a numeric `score` (0.0–1.0) via `ConfidenceLevel(score:)` rather
/// than hardcoded at rule declaration time. Three named bands are kept for
/// icon and colour rendering; the underlying score is always surfaced numerically
/// to the user so they can distinguish a 94% regex hit from a 63% NLP guess.
///
/// Band thresholds:
///   • high   — score ≥ 0.80   (structurally unambiguous patterns, strong OCR)
///   • medium — score ≥ 0.55   (NLP-based detectors, OCR-fragile patterns)
///   • low    — score  < 0.55  (heuristic / context-dependent matches)
enum ConfidenceLevel: Int, Comparable, CaseIterable {
    case low    = 0
    case medium = 1
    case high   = 2

    static func < (lhs: ConfidenceLevel, rhs: ConfidenceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Derives a named band from a raw 0.0–1.0 score.
    nonisolated init(score: Double) {
        switch score {
        case 0.80...: self = .high
        case 0.55...: self = .medium
        default:      self = .low
        }
    }

    /// Human-readable label used in UI.
    var label: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }
}

// MARK: - DetectedInstance

/// A single occurrence of a PII pattern within the image.
///
/// `snippet`     — the matched substring, truncated for display.
/// `boundingBox` — normalised rect in SwiftUI coordinates (top-left origin,
///                 values in 0.0…1.0). Multiply by the rendered image size to
///                 get absolute frame coordinates for overlay drawing.
/// `score`       — combined confidence for this occurrence: rule base score ×
///                 Vision OCR confidence for the observation it came from.
///                 Range 0.0–1.0; multiply by 100 for a percentage.
///
/// `Identifiable` — each instance carries a stable UUID for SwiftUI `ForEach`.
/// `Equatable` / `Hashable` — deliberately exclude `id` and `score` so two
///   instances with the same snippet and bounding box are treated as duplicates
///   regardless of when they were created (used for deduplication in PIIScanner).
struct DetectedInstance: Identifiable, Hashable {
    let id = UUID()
    let snippet: String
    let boundingBox: CGRect
    /// Rule base score × OCR confidence for this specific observation.
    let score: Double

    static func == (lhs: DetectedInstance, rhs: DetectedInstance) -> Bool {
        lhs.snippet == rhs.snippet && lhs.boundingBox == rhs.boundingBox
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(snippet)
        hasher.combine(boundingBox.minX)
        hasher.combine(boundingBox.minY)
        hasher.combine(boundingBox.width)
        hasher.combine(boundingBox.height)
    }
}

// MARK: - DetectionResult

/// An aggregated PII finding for one `PIIType`, collecting every individual
/// occurrence (snippet + location) across all OCR observations.
///
/// `score` — the best (highest) instance score seen so far across all matches
///   for this type. Starts at the score of the first detection and is upgraded
///   whenever a subsequent detection achieves a higher score, so the reported
///   certainty always reflects the strongest evidence available.
///
/// `confidence` — named band derived from `score` for icon/colour rendering.
///   A separate numeric percentage (`Int(round(score * 100))`) is shown in the
///   UI instead of the legacy "High / Medium / Low Confidence" text.
///
/// `Identifiable` — safe for `ForEach` in SwiftUI.
/// `Hashable`     — can be stored in Sets and used as dictionary keys.
struct DetectionResult: Identifiable, Hashable {
    /// Stable identifier derived from the underlying PIIType.
    var id: String { type.id }

    let type: PIIType

    /// Best instance score seen for this type (rule base × OCR confidence).
    /// Mutable so `PIIScanner.record()` can upgrade it when a stronger match
    /// is found for the same type (e.g. regex firing after NSDataDetector).
    var score: Double

    /// Named confidence band derived from `score`. Used only for icon + colour.
    var confidence: ConfidenceLevel { ConfidenceLevel(score: score) }

    /// All individual occurrences of this PII type found in the image.
    var instances: [DetectedInstance]

    /// Derived match count — replaces the old `matchCount` stored property.
    var matchCount: Int { instances.count }

    /// Percentage representation for display: e.g. 0.934 → 93.
    var scorePercent: Int { Int(round(score * 100)) }
}
