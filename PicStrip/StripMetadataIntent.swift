import AppIntents
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - StripMetadataIntent

/// A background App Intent that strips privacy metadata from images handed to it
/// by Shortcuts and returns clean copies — no UI, no photo library access.
///
/// This complements `StripImageIntent` (which opens the app for the full
/// scan-and-redact flow).  It deliberately does **metadata only**:
///   - Vision OCR in a background intent process is what previously blew the
///     memory ceiling; the two-pass ImageIO encode on its own stays well inside it.
///   - Returning files instead of saving means no `PHPhotoLibrary` authorization
///     prompt, which a background intent cannot present.
///
/// Shortcuts usage: "Select Photos" / "Get File" → "Strip Metadata from Images" →
/// "Save to Photos" / "Save File" / "Share".
struct StripMetadataIntent: AppIntent, ProgressReportingIntent {

    static let title: LocalizedStringResource = "Strip Metadata from Images"

    static let description = IntentDescription(
        LocalizedStringResource("Removes location, camera, and other private metadata from images and returns clean copies. Runs on this device without opening PicStrip. Visible text and faces are not redacted."),
        categoryName: LocalizedStringResource("Privacy")
    )

    static let supportedModes: IntentModes = .background

    // `connectToPreviousIntentResult` marks this as the action's input, so
    // Shortcuts wires the previous action's output ("Select Photos", "Get File",
    // …) into it.  Without it the parameter is never connected and the intent
    // runs with no images at all.
    @Parameter(
        title: LocalizedStringResource("Images"),
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var images: [IntentFile]

    @Parameter(title: LocalizedStringResource("Export Format"), default: .original)
    var format: ExportFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Strip metadata from \(\.$images) as \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let files = images
        let preset = format.exportPreset
        progress.totalUnitCount = Int64(files.count)

        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            // A large selection can outlast the normal intent time limit; ask the
            // system for a long-running background task on OS versions that offer one.
            let cleaned = try await performBackgroundTask { [progress] in
                try await Self.clean(files, preset: preset, progress: progress)
            }
            return .result(value: cleaned)
        }
        #endif

        return .result(value: try await Self.clean(files, preset: preset, progress: progress))
    }

    // MARK: - Processing

    /// Strips every file sequentially — one decoded image in memory at a time, the
    /// same budget rule the batch pipeline and the Share Extension follow.
    ///
    /// Fails closed: if any image cannot be read or cleaned the whole intent
    /// throws, so a shortcut never passes an untouched original downstream as if
    /// it were clean.
    @concurrent
    nonisolated static func clean(
        _ files: [IntentFile],
        preset: ExportPreset,
        progress: Progress? = nil,
        store: PrivateFileStore = .exports
    ) async throws -> [IntentFile] {
        var cleaned: [IntentFile] = []
        var written: [URL] = []
        var completed = false
        defer {
            if !completed { written.forEach { store.remove($0) } }
        }
        cleaned.reserveCapacity(files.count)
        for file in files {
            try Task.checkCancellation()
            let output: (URL, UTType) = try autoreleasepool {
                let source = try readData(of: file)
                do { try ImageResourceBudget.background.validate(source) } catch {
                    if case ImageResourceBudget.AdmissionError.invalidImage = error {
                        throw StripMetadataIntentError.couldNotClean(filename: file.filename)
                    }
                    throw error
                }
                let result: VerifiedExport
                do {
                    result = try ExportPipeline.encode(source, plan: ExportPlan(preset: preset, metadata: .allEnabled))
                } catch {
                    throw StripMetadataIntentError.couldNotClean(filename: file.filename)
                }
                let url = try store.write(result.processed.data, extension: result.type.preferredFilenameExtension ?? "data")
                return (url, result.type)
            }
            written.append(output.0)
            // File-backed results keep prior outputs out of memory while the next
            // image is processed. Expiring protected files outlive the receiving shortcut.
            var resultFile = IntentFile(fileURL: output.0, filename: outputFilename(for: file.filename, type: output.1), type: output.1)
            resultFile.removedOnCompletion = true
            cleaned.append(resultFile)
            progress?.completedUnitCount += 1
        }
        try Task.checkCancellation()
        completed = true
        return cleaned
    }

    /// `IntentFile.data` is empty for some providers (notably Photos-backed
    /// files), so fall back to reading the security-scoped URL directly.
    nonisolated private static func readData(of file: IntentFile) throws -> Data {
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try ImageResourceBudget.background.read(url)
        }
        let inline = file.data
        guard !inline.isEmpty else { throw StripMetadataIntentError.couldNotRead(filename: file.filename) }
        return inline
    }

    /// A neutral name avoids disclosing a source filename in downstream shares.
    nonisolated static func outputFilename(for _: String, type: UTType) -> String {
        "PicStrip.\(type.preferredFilenameExtension ?? "data")"
    }

}

#if compiler(>=6.4)
@available(iOS 27, *)
extension StripMetadataIntent: LongRunningIntent {}
#endif

// MARK: - Errors

nonisolated enum StripMetadataIntentError: Error, CustomLocalizedStringResourceConvertible {
    case couldNotRead(filename: String)
    case couldNotClean(filename: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .couldNotRead(let filename):
            return "PicStrip could not read “\(filename)”. No images were returned."
        case .couldNotClean(let filename):
            return "PicStrip could not remove the metadata from “\(filename)”. No images were returned."
        }
    }
}
