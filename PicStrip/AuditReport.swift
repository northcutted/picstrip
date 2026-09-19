import Foundation

// MARK: - AuditReport

/// Top-level Codable model representing the complete scan findings for one image.
/// Serialised to JSON via `ScrubberViewModel.generateAuditJSON()`.
nonisolated struct AuditReport: Codable, Sendable {
    let scanDate: Date
    let formatSelected: String
    let visualRedactions: [RedactionReport]
    let metadataStripped: [MetadataCategoryReport]
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
    /// Key-value pairs of the fields that were removed (field key → raw string value).
    let strippedFields: [String: String]
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
