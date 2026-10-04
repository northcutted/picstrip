import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// An immutable decision applied uniformly by the editor, batch, extension and
/// background intent. Only the interactive editor may acknowledge missing checks.
nonisolated struct ExportPlan: Sendable {
    let preset: ExportPreset
    let metadata: StripConfig
}

nonisolated struct VerifiedExport: Sendable {
    let processed: ProcessedImage
    let outputFields: [MetadataField]
    let type: UTType
    let metadataRemoved: [MetadataCategoryReport]
}

nonisolated struct CleanedExport: Sendable {
    let export: VerifiedExport
    let redactions: [RedactionReport]
    let coverage: ScanCoverage
}

nonisolated enum ExportPipeline {
    enum ExportError: LocalizedError {
        case incompleteScan
        case redactionFailed
        case invalidOutput
        case metadataRetained

        var errorDescription: String? {
            switch self {
            case .incompleteScan:
                return String(localized: "Some privacy checks could not finish. Open this photo in PicStrip and review it manually.")
            case .redactionFailed:
                return String(localized: "Could not render redactions for this image.")
            case .invalidOutput:
                return String(localized: "The cleaned image could not be verified.")
            case .metadataRetained:
                return String(localized: "Some selected metadata could not be removed. Nothing was exported.")
            }
        }
    }

    /// Decode the actual output, then verify every requested non-structural
    /// source field is absent. Reports derive from this readback, not intent.
    static func encode(
        _ data: Data, imageOverride: UIImage? = nil, plan: ExportPlan
    ) throws -> VerifiedExport {
        try ImageResourceBudget.editor.validate(data)
        let result: ProcessedImage
        if let imageOverride {
            result = try ImageProcessor.process(image: imageOverride, sourceData: data, preset: plan.preset, config: plan.metadata)
        } else {
            result = try ImageProcessor.process(data: data, preset: plan.preset, config: plan.metadata)
        }
        guard let source = CGImageSourceCreateWithData(result.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image)
        else { throw ExportError.invalidOutput }

        let outputFields = ImageProcessor.readAllFields(from: result.data)
        let outputKeys = Set(outputFields.filter { !$0.isStructural }.map { "\($0.category).\($0.key)" })
        let sourceFields = ImageProcessor.readAllFields(from: data).filter { !$0.isStructural }
        guard !outputFields.contains(where: {
            !$0.isStructural && plan.metadata.shouldStrip(category: $0.category, key: $0.key)
        }) else { throw ExportError.metadataRetained }

        let removed = sourceFields.filter { !outputKeys.contains("\($0.category).\($0.key)") }
        let summary = Dictionary(grouping: removed, by: \.category)
            .map { MetadataCategoryReport(category: $0.key, strippedFields: $0.value.map(\.key).sorted()) }
            .sorted { $0.category < $1.category }
        return VerifiedExport(processed: result, outputFields: outputFields, type: type, metadataRemoved: summary)
    }

    /// Unattended workflows never accept an incomplete visual scan.
    @concurrent
    static func clean(
        _ data: Data,
        plan: ExportPlan,
        redact: Bool,
        hints: ScanHints = .none,
        budget: ImageResourceBudget = .editor,
        scan: @Sendable (Data, ScanHints, ScanProgressHandler?) async throws -> ScanOutput = {
            try await PIIScanner().scan(data: $0, hints: $1, progress: $2)
        }
    ) async throws -> CleanedExport {
        try Task.checkCancellation()
        try budget.validate(data)
        var coverage = ScanCoverage()
        var redactions: [RedactionReport] = []
        var image: UIImage?
        if redact {
            let output = try await scan(data, hints, nil)
            guard !output.coverage.requiresManualReview else { throw ExportError.incompleteScan }
            coverage = output.coverage
            let selected = output.results.filter(\.type.isRedactedByDefault)
            let instances = selected.flatMap(\.instances)
            if !instances.isEmpty {
                guard let original = ImageProcessor.orientedImage(from: data),
                      let rendered = await ImageRedactor().redact(image: original, instances: instances)
                else { throw ExportError.redactionFailed }
                image = rendered
            }
            redactions = selected.map { RedactionReport(type: $0.type.description, instanceCount: $0.matchCount) }
        }
        try Task.checkCancellation()
        return CleanedExport(export: try encode(data, imageOverride: image, plan: plan), redactions: redactions, coverage: coverage)
    }
}
