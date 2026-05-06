import Foundation

// MARK: - AuditReport

/// Top-level Codable model representing the complete scan findings for one image.
/// Serialised to JSON via `ScrubberViewModel.generateAuditJSON()`.
struct AuditReport: Codable {
    let scanDate: Date
    let formatSelected: String
    let visualRedactions: [RedactionReport]
    let metadataStripped: [MetadataCategoryReport]
}

// MARK: - RedactionReport

/// One PII type that was detected and selected for visual redaction.
struct RedactionReport: Codable {
    let type: String
    let instanceCount: Int
}

// MARK: - MetadataCategoryReport

/// All non-structural fields stripped from a single metadata category (e.g. "GPS", "EXIF").
struct MetadataCategoryReport: Codable {
    let category: String
    /// Key-value pairs of the fields that were removed (field key → raw string value).
    let strippedFields: [String: String]
}

// MARK: - BatchAuditReport

/// Top-level container for a multi-photo batch audit log.
/// Wraps one `AuditReport` per processed image alongside batch-level metadata.
struct BatchAuditReport: Codable {
    let batchDate: Date
    let photoCount: Int
    let reports: [AuditReport]
}
