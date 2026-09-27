import Foundation

// MARK: - AuditReport

/// Top-level Codable model representing the complete scan findings for one image.
/// Shared export receipt. No original metadata values or detected snippets.
nonisolated struct AuditReport: Codable, Sendable {
    let scanDate: Date
    let formatSelected: String
    let visualRedactions: [RedactionReport]
    let metadataStripped: [MetadataCategoryReport]
    var scanCoverage: ScanCoverage = ScanCoverage()
    var findingsLeftVisible: Int = 0
    var manualReviewAcknowledged: Bool = false
}

// MARK: - RedactionReport

/// One PII type that was detected and selected for visual redaction.
nonisolated struct RedactionReport: Codable, Sendable {
    let type: String
    let instanceCount: Int
}

// MARK: - MetadataCategoryReport

/// All non-structural fields stripped from a single metadata category (e.g. "GPS", "EXIF").
nonisolated struct MetadataCategoryReport: Codable, Sendable {
    let category: String
    /// Field names only. Original values must never enter a shareable report.
    let strippedFields: [String]
}

// MARK: - BatchAuditReport

/// Top-level container for a multi-photo batch audit log.
/// Wraps one `AuditReport` per processed image alongside batch-level metadata.
nonisolated struct BatchAuditReport: Codable, Sendable {
    let batchDate: Date
    /// Photos that were cleaned **and** accepted by the photo library.
    let photoCount: Int
    /// Photos that could not be loaded, cleaned, or saved. Nothing was written for these.
    let failedCount: Int
    let reports: [AuditReport]
}
