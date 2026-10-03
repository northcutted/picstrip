import AppIntents
import Foundation
import UniformTypeIdentifiers

// MARK: - StripVideoMetadataIntent

/// The video counterpart of `StripMetadataIntent`: a background App Intent that
/// removes the hidden details from videos handed to it by Shortcuts and returns
/// clean copies — no UI, no photo library access.
///
/// Metadata only, like the Share Extension's Process & Save: the frames and
/// sound are copied as they are (`VideoMetadataCleaner.clean`), which keeps it
/// within a background intent's memory and time.  Finding and covering faces
/// and text in a video needs the app.
///
/// Shortcuts usage: "Select Photos" / "Get File" → "Strip Metadata from Videos" →
/// "Save to Photos" / "Save File" / "Share".
struct StripVideoMetadataIntent: AppIntent, ProgressReportingIntent {

    static let title: LocalizedStringResource = "Strip Metadata from Videos"

    static let description = IntentDescription(
        LocalizedStringResource("Removes location, device, date and other private metadata from videos and returns clean copies. Runs on this device without opening PicStrip. The frames are copied as they are, so faces and text are not covered."),
        categoryName: LocalizedStringResource("Privacy")
    )

    static let supportedModes: IntentModes = .background

    // The action's input, as in `StripMetadataIntent`: without
    // `connectToPreviousIntentResult` Shortcuts never wires the previous
    // action's output in and the intent runs with no videos.
    @Parameter(
        title: LocalizedStringResource("Videos"),
        supportedContentTypes: [.movie],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Strip metadata from \(\.$videos)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let files = videos
        progress.totalUnitCount = Int64(files.count)

        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            // Long videos can outlast the normal intent time limit; ask the
            // system for a long-running background task on OS versions that offer one.
            let cleaned = try await performBackgroundTask { [progress] in
                try await Self.clean(files, progress: progress)
            }
            return .result(value: cleaned)
        }
        #endif

        return .result(value: try await Self.clean(files, progress: progress))
    }

    // MARK: - Processing

    /// Cleans every video in turn, each as a file in the protected store,
    /// never in memory.
    ///
    /// Fails closed: if any video cannot be read or cleaned — or a location,
    /// device or date survives — the whole intent throws and the copies made so
    /// far are deleted, so a shortcut never passes an original on as clean.
    @concurrent
    nonisolated static func clean(
        _ files: [IntentFile],
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
            let source = try localCopy(of: file, in: store)
            defer { store.remove(source) }
            let output = try store.reserve(extension: "mov")
            written.append(output)
            do {
                try await VideoMetadataCleaner.clean(source, to: output)
            } catch {
                try Task.checkCancellation()
                throw StripVideoMetadataIntentError.couldNotClean(filename: file.filename)
            }
            // File-backed results keep earlier videos out of memory; they are
            // deleted when the shortcut finishes, or when the store's copies expire.
            var resultFile = IntentFile(
                fileURL: output,
                filename: StripMetadataIntent.outputFilename(for: file.filename, type: .quickTimeMovie),
                type: .quickTimeMovie
            )
            resultFile.removedOnCompletion = true
            cleaned.append(resultFile)
            progress?.completedUnitCount += 1
        }
        try Task.checkCancellation()
        completed = true
        return cleaned
    }

    /// The input as a file of PicStrip's own to read from.  A file is copied
    /// while its security scope lasts (a clone on the same volume, so not
    /// written twice); data Shortcuts holds in memory is written out.
    nonisolated private static func localCopy(of file: IntentFile, in store: PrivateFileStore) throws -> URL {
        let type = file.type ?? UTType(filenameExtension: (file.filename as NSString).pathExtension) ?? .quickTimeMovie
        let fileExtension = SharedItemKind.videoFileExtension(for: type.identifier)
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                return try store.copy(url, extension: fileExtension)
            } catch {
                throw StripVideoMetadataIntentError.couldNotRead(filename: file.filename)
            }
        }
        let inline = file.data
        guard !inline.isEmpty else { throw StripVideoMetadataIntentError.couldNotRead(filename: file.filename) }
        let url = try store.reserve(extension: fileExtension)
        try inline.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

#if compiler(>=6.4)
@available(iOS 27, *)
extension StripVideoMetadataIntent: LongRunningIntent {}
#endif

// MARK: - Errors

nonisolated enum StripVideoMetadataIntentError: Error, CustomLocalizedStringResourceConvertible {
    case couldNotRead(filename: String)
    case couldNotClean(filename: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .couldNotRead(let filename):
            return "PicStrip could not read “\(filename)”. No videos were returned."
        case .couldNotClean(let filename):
            return "PicStrip could not remove the metadata from “\(filename)”. No videos were returned."
        }
    }
}
