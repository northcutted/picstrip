import SwiftUI
import PhotosUI
import Photos
import CoreImage
import UniformTypeIdentifiers

/// ViewModel driving the scrubber interface.
///
/// Owns the full data-flow pipeline:
/// picker selection → raw `Data` load → `ImageProcessor` scrub → save / share.
///
/// All mutations to state properties are performed on the `@MainActor` so SwiftUI
/// can safely observe them from any call-site.
@Observable
@MainActor
final class ScrubberViewModel {

    // MARK: - State

    /// The raw item vended by `PhotosPicker`. Setting this triggers an async load.
    var selectedItem: PhotosPickerItem? {
        didSet { handleItemChange() }
    }

    /// A displayable SwiftUI `Image` derived from the raw loaded data.
    var inputImage: Image?

    /// The scrubbed, re-encoded image bytes ready for saving or sharing.
    var processedData: Data?

    /// The active export preset. Changing it re-triggers processing if data is loaded.
    var selectedPreset: ExportPreset = .matchSource {
        didSet {
            guard rawImageData != nil else { return }
            processCurrentImage()
        }
    }

    /// The detected UTType of the source image (e.g. `.jpeg`, `.heic`).
    var sourceUTType: UTType?

    /// The current strip configuration.
    /// Changes are recorded immediately but re-encoding is deferred to save time
    /// (via `requestSave()`) to avoid a processing spinner on every toggle flip.
    var stripConfig: StripConfig = .default {
        didSet {
            // Cheaply recompute what *will* be stripped so the badge row and
            // category panels stay in sync without re-encoding.
            refreshPendingMetadata()
        }
    }

    /// All metadata fields present in the source image, regardless of strip config.
    /// Used for display — badges and the detail panel always show what's in the image,
    /// not just what will be stripped.
    var allSourceMetadata: StrippedMetadata?

    /// The metadata fields that *will* be stripped given the current `stripConfig`.
    /// Populated immediately after load — no save required.
    var pendingStrippedMetadata: StrippedMetadata?

    /// `true` while an async load, processing, or save operation is in flight.
    var isProcessing: Bool = false

    /// Populated when any step throws; `nil` on success.
    var errorMessage: String?

    // MARK: - Save flow state

    /// Controls the pre-save review sheet.
    var showPreSaveReview: Bool = false

    /// Shown when the user chose "Replace Original" but no asset identifier is available.
    var showReplaceUnavailableAlert: Bool = false

    // MARK: - Private

    private var isClearing: Bool = false

    /// The unprocessed image bytes retained so preset / config changes can re-process
    /// without requiring the user to re-pick the image.
    private var rawImageData: Data?

    /// The raw source properties from ImageIO — used to rebuild pendingStrippedMetadata
    /// cheaply when only the config changes (without re-running the full encode pipeline).
    private var rawSourceProps: [CFString: Any]?

    // MARK: - Item change handler

    private func handleItemChange() {
        guard !isClearing else { return }
        guard let item = selectedItem else { return }
        Task { await loadAndProcess(item: item) }
    }

    // MARK: - Async load pipeline

    private func loadAndProcess(item: PhotosPickerItem) async {
        isProcessing = true
        errorMessage = nil
        processedData = nil
        inputImage = nil
        pendingStrippedMetadata = nil
        sourceUTType = nil
        rawSourceProps = nil

        defer { isProcessing = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "The selected item could not be loaded as image data."
                return
            }

            rawImageData = data

            if let uiImage = UIImage(data: data) {
                inputImage = Image(uiImage: uiImage)
            }

            processCurrentImage()
        } catch {
            errorMessage = error.localizedDescription
            rawImageData = nil
        }
    }

    // MARK: - Processing

    func processCurrentImage() {
        guard let raw = rawImageData else { return }

        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try ImageProcessor.process(data: raw, preset: selectedPreset, config: stripConfig)
            processedData        = result.data
            sourceUTType         = result.sourceType
            pendingStrippedMetadata = result.stripped

            // Cache source props for cheap config-only re-catalogues.
            if let source = CGImageSourceCreateWithData(raw as CFData, nil) {
                rawSourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            }
            // Full catalogue — all fields, no filtering — drives badges and detail panel.
            allSourceMetadata = ImageProcessor.catalogueStrippedMetadata(
                from: rawSourceProps,
                config: StripConfig(
                    categoryEnabled: Dictionary(
                        uniqueKeysWithValues: ImageProcessor.categoryMap.map { ($0.category, true) }
                    ),
                    fieldOverrides: [:]
                )
            )
        } catch {
            processedData           = nil
            pendingStrippedMetadata = nil
            errorMessage            = error.localizedDescription
        }
    }

    /// Recomputes `pendingStrippedMetadata` from cached source props without re-encoding.
    /// Called when only `stripConfig` changes and a full re-process would be redundant.
    func refreshPendingMetadata() {
        pendingStrippedMetadata = ImageProcessor.catalogueStrippedMetadata(
            from: rawSourceProps,
            config: stripConfig
        )
    }

    // MARK: - Save to Photos

    /// Entry-point called from the UI's "Save" button.
    /// Re-encodes with the current config first, then presents the review sheet.
    func requestSave() {
        guard rawImageData != nil else { return }
        processCurrentImage()
        showPreSaveReview = true
    }

    /// Saves the processed image to the photo library.
    ///
    /// - Parameter replacing: When `true`, also deletes the original asset.
    func saveToPhotos(replacing: Bool) async {
        guard let data = processedData else { return }

        let requiredLevel: PHAccessLevel = replacing ? .readWrite : .addOnly
        let status = await PHPhotoLibrary.requestAuthorization(for: requiredLevel)
        guard status == .authorized || status == .limited else {
            errorMessage = "Photo library access was denied. Please enable it in Settings."
            return
        }

        if replacing {
            await saveReplacing(data: data)
        } else {
            await saveAsNew(data: data)
        }
    }

    private func saveAsNew(data: Data) async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            showPreSaveReview = false
        } catch {
            errorMessage = "Could not save to Photos: \(error.localizedDescription)"
        }
    }

    private func saveReplacing(data: Data) async {
        guard let identifier = selectedItem?.itemIdentifier,
              let asset = PHAsset.fetchAssets(
                  withLocalIdentifiers: [identifier],
                  options: nil
              ).firstObject else {
            showReplaceUnavailableAlert = true
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let createRequest = PHAssetCreationRequest.forAsset()
                createRequest.addResource(with: .photo, data: data, options: nil)
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            showPreSaveReview = false
        } catch {
            errorMessage = "Could not replace photo: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    func clearState() {
        isClearing              = true
        selectedItem            = nil
        isClearing              = false
        rawImageData            = nil
        rawSourceProps          = nil
        inputImage              = nil
        processedData           = nil
        allSourceMetadata       = nil
        pendingStrippedMetadata = nil
        sourceUTType            = nil
        errorMessage            = nil
        isProcessing            = false
        stripConfig             = .default
    }
}
