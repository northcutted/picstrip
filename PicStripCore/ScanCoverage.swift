import Foundation

/// Coverage is independent of findings: an empty result cannot establish that a
/// detector ran. Required checks must complete before an unattended export.
nonisolated struct ScanCoverage: Codable, Equatable, Sendable {
    enum Check: String, Codable, CodingKey, CaseIterable, Sendable {
        case text, faces, barcodes, documentContext, names

        var title: String {
            switch self {
            case .text: return String(localized: "Text")
            case .faces: return String(localized: "Faces")
            case .barcodes: return String(localized: "Barcodes")
            case .documentContext: return String(localized: "Document context")
            case .names: return String(localized: "People's names")
            }
        }
    }

    enum Status: String, Codable, Sendable {
        case notChecked, checking, complete, failed, unavailable, partial

        var title: String {
            switch self {
            case .notChecked: return String(localized: "Not checked")
            case .checking: return String(localized: "Checking")
            case .complete: return String(localized: "Checked")
            case .failed: return String(localized: "Could not check")
            case .unavailable: return String(localized: "Unavailable on this device")
            case .partial: return String(localized: "Partly checked")
            }
        }
    }

    private var checks: [Check: Status] = [:]
    init() { }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Check.self)
        for check in Check.allCases { checks[check] = try container.decodeIfPresent(Status.self, forKey: check) ?? .notChecked }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Check.self)
        for check in Check.allCases { try container.encode(self[check], forKey: check) }
    }

    static let requiredChecks: [Check] = [.text, .faces, .barcodes]

    subscript(_ check: Check) -> Status {
        get { checks[check] ?? .notChecked }
        set { checks[check] = newValue }
    }

    var incompleteRequiredChecks: [Check] {
        Self.requiredChecks.filter { self[$0] != .complete }
    }

    var requiresManualReview: Bool { !incompleteRequiredChecks.isEmpty }

    static var complete: ScanCoverage {
        var coverage = ScanCoverage()
        for check in requiredChecks + [.documentContext] { coverage[check] = .complete }
        coverage[.names] = .notChecked
        return coverage
    }

    static var failed: ScanCoverage {
        var coverage = ScanCoverage()
        for check in requiredChecks { coverage[check] = .failed }
        return coverage
    }
}
