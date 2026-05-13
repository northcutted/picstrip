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
        case .low:    return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high:   return String(localized: "High")
        }
    }
}

// MARK: - RiskLevel

/// Editorial risk assessment — how sensitive this data type is if it is accidentally disclosed.
///
/// This is a separate axis from `ConfidenceLevel`:
///   • **Confidence** answers "how certain are we that this pattern is really what we think it is?"
///     (derived from Vision OCR quality and regex specificity)
///   • **Risk** answers "how bad would it be if this information were exposed?"
///     (an editorial judgement assigned per `PIIType`, independent of detection quality)
///
/// Levels:
///   • critical — immediate account takeover / major financial fraud risk (SSNs, API keys, credit cards)
///   • high     — significant personal or financial harm (IBANs, faces, physical credentials)
///   • medium   — useful to attackers but not immediately dangerous alone (emails, phone numbers, IPs)
///   • low      — contextual; risk depends heavily on the recipient and setting (URLs, dates, barcodes)
enum RiskLevel: Int, Comparable, CaseIterable {
    case low      = 0
    case medium   = 1
    case high     = 2
    case critical = 3

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Full human-readable label: "Critical Risk", "High Risk", etc.
    nonisolated var label: String {
        switch self {
        case .low:      return String(localized: "Low Risk")
        case .medium:   return String(localized: "Medium Risk")
        case .high:     return String(localized: "High Risk")
        case .critical: return String(localized: "Critical Risk")
        }
    }

    /// Short label used in compact UI contexts: "Low", "Medium", "High", "Critical".
    nonisolated var shortLabel: String {
        switch self {
        case .low:      return String(localized: "Low")
        case .medium:   return String(localized: "Medium")
        case .high:     return String(localized: "High")
        case .critical: return String(localized: "Critical")
        }
    }
}

// MARK: - PIISubtype

/// More specific evidence for broad detection categories.
///
/// This intentionally stays below `PIIType`: the app can still group and toggle
/// all government IDs together, while individual rows can explain which format
/// triggered the detection.
enum PIISubtype: String, Hashable, CaseIterable {
    case creditCardDocument
    case identityDocument
    case driversLicenseDocument
    case passportDocument
    case brazilianCPF
    case italianCodiceFiscale
    case spanishNIE
    case indianPAN
    case frenchINSEE
    case spanishDNI
    case aadhaarOrMyNumber
    case canadianSIN
    case germanTaxID
    case southKoreanRRN
    case chineseResidentID
    case polishPESEL
    case mexicanCURP
    case usITIN
    case usEIN
    case medicareMBI
    case usPassport
    case usDriversLicenseCalifornia
    case usDriversLicenseMassachusetts
    case usDriversLicenseIllinois
    case usDriversLicenseLetter12Digit
    case usDriversLicenseWisconsin
    case usDriversLicenseNewJersey

    nonisolated var displayName: String {
        switch self {
        case .creditCardDocument:             return String(localized: "Credit Card")
        case .identityDocument:               return String(localized: "Identity Document")
        case .driversLicenseDocument:         return String(localized: "Driver License")
        case .passportDocument:               return String(localized: "Passport")
        case .brazilianCPF:                    return String(localized: "Brazilian CPF")
        case .italianCodiceFiscale:            return String(localized: "Italian Codice Fiscale")
        case .spanishNIE:                      return String(localized: "Spanish NIE")
        case .indianPAN:                       return String(localized: "Indian PAN")
        case .frenchINSEE:                     return String(localized: "French INSEE")
        case .spanishDNI:                      return String(localized: "Spanish DNI")
        case .aadhaarOrMyNumber:               return String(localized: "Aadhaar / My Number")
        case .canadianSIN:                     return String(localized: "Canadian SIN")
        case .germanTaxID:                     return String(localized: "German Tax ID")
        case .southKoreanRRN:                  return String(localized: "South Korean RRN")
        case .chineseResidentID:               return String(localized: "Chinese Resident ID")
        case .polishPESEL:                     return String(localized: "Polish PESEL")
        case .mexicanCURP:                     return String(localized: "Mexican CURP")
        case .usITIN:                          return String(localized: "US ITIN")
        case .usEIN:                           return String(localized: "US EIN")
        case .medicareMBI:                     return String(localized: "Medicare MBI")
        case .usPassport:                      return String(localized: "US Passport")
        case .usDriversLicenseCalifornia:      return String(localized: "California Driver License")
        case .usDriversLicenseMassachusetts:   return String(localized: "Massachusetts Driver License")
        case .usDriversLicenseIllinois:        return String(localized: "Illinois Driver License")
        case .usDriversLicenseLetter12Digit:   return String(localized: "US Driver License")
        case .usDriversLicenseWisconsin:       return String(localized: "Wisconsin Driver License")
        case .usDriversLicenseNewJersey:       return String(localized: "New Jersey Driver License")
        }
    }
}

// MARK: - DetectedInstance

/// A single occurrence of a PII pattern within the image.
///
/// `snippet`     — the matched substring, truncated for display.
/// `subtype`     — optional format label for broad categories such as
///                 `governmentID`.
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
nonisolated struct DetectedInstance: Identifiable, Hashable {
    let id = UUID()
    let snippet: String
    let subtype: PIISubtype?
    let boundingBox: CGRect
    /// Rule base score × OCR confidence for this specific observation.
    let score: Double

    nonisolated init(
        snippet: String,
        subtype: PIISubtype? = nil,
        boundingBox: CGRect,
        score: Double
    ) {
        self.snippet = snippet
        self.subtype = subtype
        self.boundingBox = boundingBox
        self.score = score
    }

    static func == (lhs: DetectedInstance, rhs: DetectedInstance) -> Bool {
        lhs.snippet == rhs.snippet && lhs.subtype == rhs.subtype && lhs.boundingBox == rhs.boundingBox
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(snippet)
        hasher.combine(subtype)
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

    /// Specific formats represented by this result, when available.
    var subtypes: Set<PIISubtype> {
        Set(instances.compactMap(\.subtype))
    }

    /// Derived match count — replaces the old `matchCount` stored property.
    var matchCount: Int { instances.count }

    /// Percentage representation for display: e.g. 0.934 → 93.
    var scorePercent: Int { Int(round(score * 100)) }
}
