import Foundation

// MARK: - ScanProgress

/// How far one privacy scan has got, built from the scanner's own milestones
/// (`ScanStep`) rather than from a clock, so the bar only ever claims work that
/// has actually finished.
///
/// The Vision requests run together and finish in any order.  Reading text is
/// by far the slowest of them, so it carries most of the weight.
nonisolated struct ScanProgress: Equatable, Sendable {

    enum Stage: Equatable, Sendable {
        /// Vision is reading text and looking for faces, codes and document edges.
        case analysing
        /// The recognised text is being checked against the detection rules.
        case matching
    }

    /// Completed share of the scan, 0 … 1.  Never moves backwards.
    private(set) var fraction: Double
    private(set) var stage: Stage
    private var analysed: Set<ScanStep.Subject> = []

    static let notStarted = ScanProgress(fraction: 0, stage: .analysing)
    /// Validating and handing the bytes to Vision is a small but real first step.
    static let started = ScanProgress(fraction: 0.04, stage: .analysing)
    static let finished = ScanProgress(fraction: 1, stage: .matching)

    private init(fraction: Double, stage: Stage) {
        self.fraction = fraction
        self.stage = stage
    }

    /// The share of the whole scan each Vision request accounts for.
    static func weight(of subject: ScanStep.Subject) -> Double {
        switch subject {
        case .text:          return 0.56
        case .faces:         return 0.12
        case .barcodes:      return 0.10
        case .documentEdges: return 0.06
        }
    }

    /// Where the bar stands once pattern matching has begun; the rest is the
    /// matching itself and publishing the result.
    static let matchingFraction = 0.9

    mutating func record(_ step: ScanStep) {
        switch step {
        case .analysed(let subject):
            // A retried request (the fast-text fallback) must not count twice.
            guard analysed.insert(subject).inserted else { return }
            fraction = min(Self.matchingFraction, fraction + Self.weight(of: subject))
        case .matchingPatterns:
            stage = .matching
            fraction = max(fraction, Self.matchingFraction)
        }
    }
}
