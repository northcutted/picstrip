import Foundation
import Photos

// MARK: - SharedItem
//
// The work the share extension and the two actions have in common: finding the
// photos and videos in what was shared and saving cleaned copies to Photos.
// Handing one to the app for editing is in SharedItem+Handoff.swift, compiled
// only into the extensions that do it.
//
// Item providers are not Sendable, so they stay on the main actor; only each
// image's `Data` and each video's file URL cross to background work.
// Videos are only ever copied as files, never read into memory.

struct SharedItem {
    let provider: NSItemProvider
    let kind: SharedItemKind

    var isVideo: Bool { kind.isVideo }

    /// The photos and videos shared, in order; anything else is left out.
    static func items(in context: NSExtensionContext?) -> [SharedItem] {
        guard let items = context?.inputItems as? [NSExtensionItem] else { return [] }
        return items.flatMap { $0.attachments ?? [] }.compactMap { provider in
            SharedItemKind(registeredTypeIdentifiers: provider.registeredTypeIdentifiers).map { SharedItem(provider: provider, kind: $0) }
        }
    }

    // MARK: - Save to Photos

    /// A cleaned copy saved to Photos.  A video only has its hidden details
    /// removed, its frames copied as they are: finding and covering faces in a
    /// video needs more memory and time than an extension gets.  Throws when
    /// nothing was saved; a step that cannot run fails the item rather than
    /// saving the untouched original as "cleaned".
    func saveCleanedCopy(stripMetadata: Bool = true, redactPII: Bool = false, reduceLargeImages: Bool = false) async throws {
        switch kind {
        case .video(let typeIdentifier):
            try await saveCleanedVideo(typeIdentifier: typeIdentifier)
        case .photo(let typeIdentifier):
            let rawData = try await loadPhotoData(typeIdentifier: typeIdentifier)
            try Task.checkCancellation()
            let cleaned = try await Self.clean(rawData, stripMetadata: stripMetadata,
                                               redactPII: redactPII, reduceLargeImages: reduceLargeImages)
            try Task.checkCancellation()
            try await PhotoLibraryWriter.save(cleaned)
        }
    }

    /// Asks for permission to add to Photos; `false` when it was refused.
    static func canSaveToPhotos() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Scans, redacts, and strips one image.  Metadata alone is held to the
    /// 13 MP background budget, redaction to the smaller extension one; a
    /// larger photo needs the user's consent to a smaller copy.
    @concurrent
    nonisolated private static func clean(
        _ rawData: Data,
        stripMetadata: Bool,
        redactPII: Bool,
        reduceLargeImages: Bool
    ) async throws -> Data {
        let metadata = stripMetadata ? StripConfig.allEnabled : StripConfig(categoryEnabled: [:], fieldOverrides: [:])
        let budget: ImageResourceBudget = redactPII ? .shareExtension : .background
        var input = rawData
        do { try budget.validate(input) } catch ImageResourceBudget.AdmissionError.resolutionTooLarge {
            guard reduceLargeImages else { throw ImageResourceBudget.AdmissionError.resolutionTooLarge }
            input = try ImageResourceBudget.smallerCopy(input, maximumPixels: redactPII ? 6_000_000 : 12_000_000)
        }
        let result = try await ExportPipeline.clean(
            input,
            plan: ExportPlan(preset: stripMetadata ? .losslessPNG : .matchSource, metadata: metadata),
            redact: redactPII,
            budget: budget
        )
        return result.export.processed.data
    }

    /// A copy of the video without its hidden details — the frames copied as
    /// they are, checked before it is kept — saved to Photos.  Both temporary
    /// files are deleted whatever happens.
    private func saveCleanedVideo(typeIdentifier: String) async throws {
        let store = PrivateFileStore.exports
        let original = try await copyVideo(typeIdentifier: typeIdentifier, into: store)
        defer { store.remove(original) }
        let cleaned = try store.reserve(extension: "mov")
        defer { store.remove(cleaned) }
        try await VideoMetadataCleaner.clean(original, to: cleaned)
        try Task.checkCancellation()
        try await PhotoLibraryWriter.saveVideo(at: cleaned)
    }

    // MARK: - Loading

    /// Copies the shared video into `store` as a file — never into memory —
    /// while the provider's temporary file exists: it is deleted when the
    /// callback returns.
    func copyVideo(typeIdentifier: String, into store: PrivateFileStore, now: Date = Date()) async throws -> URL {
        let fileExtension = SharedItemKind.videoFileExtension(for: typeIdentifier)
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? VideoMetadataCleaner.Failure.cannotExport)
                    return
                }
                continuation.resume(with: Result { try store.copy(url, extension: fileExtension, now: now) })
            }
        }
    }

    /// The photo's original bytes, from a file where the provider has one,
    /// within the extension's byte limit.
    func loadPhotoData(typeIdentifier: String) async throws -> Data {
        let budget = ImageResourceBudget.shareExtension
        let fromFile: Result<Data, any Error>? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                continuation.resume(returning: url.map { url in Result { try budget.read(url) } })
            }
        }
        switch fromFile {
        case .success(let data)?:
            return data
        case .failure(let error)? where (error as? ImageResourceBudget.AdmissionError) == .fileTooLarge:
            throw error
        default:
            break   // No file, or one that could not be read: ask for the bytes instead.
        }
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { throw ImageResourceBudget.AdmissionError.invalidImage }
        guard data.count <= budget.maximumBytes else { throw ImageResourceBudget.AdmissionError.fileTooLarge }
        return data
    }
}
