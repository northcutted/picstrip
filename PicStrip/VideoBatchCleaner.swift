import AVFoundation
import Foundation

// MARK: - VideoBatchCleaner

/// Cleans one video of a batch, with nobody reviewing it: when covering is on,
/// every face found is blurred and every piece of sensitive text, code and
/// Always Cover word is covered with a solid box — the defaults of the video
/// editor — and the copy always leaves without its location, device and dates.
nonisolated enum VideoBatchCleaner {

    struct Result: Sendable {
        /// The cleaned copy, in the protected store; the caller saves and deletes it.
        let url: URL
        let report: AuditReport
    }

    /// Scanning is most of the work; writing the copy the rest.
    private static let scanShare = 0.7

    @concurrent
    static func clean(
        _ source: URL, covering: Bool, alwaysCover: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        let found = try await VideoCleaner.findings(in: source)
        var composition: AVVideoComposition?
        var redactions: [RedactionReport] = []
        var coverage = ScanCoverage()
        if covering {
            let scan = try await VideoScanner.scan(source, alwaysCover: alwaysCover) { update in
                progress(update.fraction * scanShare)
            }
            try Task.checkCancellation()
            let groups = FindingGroup.groups(of: scan.findings)
            var plan = VideoRedactor.Plan(path: scan.path)
            plan.faces = scan.faces.map { VideoRedactor.FaceCoverage(track: $0, style: .blur, range: nil) }
            plan.findings = groups.flatMap { group in
                group.tracks.map { VideoRedactor.FindingCoverage(track: $0, style: .solid) }
            }
            if !plan.isEmpty {
                composition = try await VideoRedactor.composition(for: AVURLAsset(url: source), plan: plan)
            }
            redactions = Self.redactions(faces: scan.faces.count, groups: groups)
            coverage = .complete
        }

        let output = try PrivateFileStore.exports.reserve(extension: "mov")
        do {
            try await VideoCleaner.clean(source, to: output, videoComposition: composition) { fraction in
                progress((covering ? scanShare : 0) + fraction * (covering ? 1 - scanShare : 1))
            }
        } catch {
            PrivateFileStore.exports.remove(output)
            throw error
        }
        let report = AuditReport(
            scanDate: Date(),
            formatSelected: composition == nil ? "MOV" : "MOV (HEVC)",
            visualRedactions: redactions,
            // Kinds only: the values removed never go into a report.
            metadataStripped: Dictionary(grouping: found.filter { $0.kind != .other }, by: \.kind)
                .keys.sorted().map { MetadataCategoryReport(category: $0.title, strippedFields: []) },
            scanCoverage: coverage
        )
        return Result(url: output, report: report)
    }

    /// One row per kind of thing covered, with how many were followed.
    static func redactions(faces: Int, groups: [FindingGroup]) -> [RedactionReport] {
        var rows: [RedactionReport] = []
        if faces > 0 { rows.append(RedactionReport(type: PIIType.face.description, instanceCount: faces)) }
        let byType = Dictionary(grouping: groups, by: \.type)
        for type in byType.keys.sorted(by: { $0.description < $1.description }) {
            rows.append(RedactionReport(type: type.description, instanceCount: byType[type]?.count ?? 0))
        }
        return rows
    }
}
