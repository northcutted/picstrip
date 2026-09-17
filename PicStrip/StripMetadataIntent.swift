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
/// "Save to Photo Album" / "Save File" / "Share".
struct StripMetadataIntent: AppIntent, ProgressReportingIntent {

    static let title: LocalizedStringResource = "Strip Metadata from Images"

    static let description = IntentDescription(
        LocalizedStringResource("Removes location, camera, and other private metadata from images and returns clean copies. Runs on this device without opening PicStrip. Visible text and faces are not redacted."),
        categoryName: LocalizedStringResource("Privacy")
    )

    static let supportedModes: IntentModes = .background

    @Parameter(
        title: LocalizedStringResource("Images"),
        supportedContentTypes: [.image]
    )
    var images: [IntentFile]

    @Parameter(title: LocalizedStringResource("Export Format"), default: .original)
    var format: ExportFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Strip metadata from \(\.$images)") {
            \.$format
        }
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
        progress: Progress? = nil
    ) async throws -> [IntentFile] {
        var cleaned: [IntentFile] = []
        cleaned.reserveCapacity(files.count)

        for file in files {
            try Task.checkCancellation()

            let source = try readData(of: file)
            guard let result = try? ImageProcessor.process(data: source, preset: preset, config: .allEnabled) else {
                throw StripMetadataIntentError.couldNotClean(filename: file.filename)
            }

            let outputType = imageType(of: result.data) ?? preset.utType ?? result.sourceType
            cleaned.append(IntentFile(
                data: result.data,
                filename: outputFilename(for: file.filename, type: outputType),
                type: outputType
            ))
            progress?.completedUnitCount += 1
        }
        return cleaned
    }

    /// `IntentFile.data` is empty for some providers (notably Photos-backed
    /// files), so fall back to reading the security-scoped URL directly.
    nonisolated private static func readData(of file: IntentFile) throws -> Data {
        let inline = file.data
        if !inline.isEmpty { return inline }

        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        throw StripMetadataIntentError.couldNotRead(filename: file.filename)
    }

    nonisolated private static func imageType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }

    /// Keeps the original base name and swaps in the extension of the type that
    /// was actually written ("IMG_0042.HEIC" → "IMG_0042.png").
    nonisolated static func outputFilename(for original: String, type: UTType) -> String {
        let base = (original as NSString).deletingPathExtension
        let name = base.isEmpty ? "Image" : base
        guard let ext = type.preferredFilenameExtension else { return name }
        return "\(name).\(ext)"
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
