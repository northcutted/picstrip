import CoreImage
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ActiveSheet

/// Single source of truth for all bottom sheets.
/// Only one sheet can be presented at a time; setting `activeSheet` to a new
/// value automatically dismisses any currently-open sheet first.
enum ActiveSheet: String, Identifiable {
    case pii
    case preSave
    case batch
    var id: String { rawValue }
}

// MARK: - BatchSaveMode

/// Whether batch-processed photos are saved as new assets or replace the originals.
enum BatchSaveMode {
    case saveAsNew
    case replaceOriginal
}

// MARK: - BatchConfig

/// Global privacy policy applied uniformly to every photo in a batch run.
struct BatchConfig {
    /// Strip all privacy metadata from each image before saving.
    var stripMetadata: Bool = true
    /// Run the PII scanner and burn redaction boxes over all detected instances.
    var redactVisualPII: Bool = true
    /// The output format for every processed image.
    var outputFormat: ExportFormat = .png
    /// Whether to save cleaned photos as new assets or overwrite the originals.
    var saveMode: BatchSaveMode = .saveAsNew
}

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

    /// The source `UIImage` retained so ContentView can use it in an
    /// `aspectRatio`-constrained overlay without re-decoding raw bytes.
    var sourceUIImage: UIImage?

    /// The scrubbed, re-encoded image bytes ready for saving or sharing.
    var processedData: Data?

    /// Every metadata field actually present in the output file after encoding.
    /// Populated after each processing pass — including the redacted path — so the
    /// review screen can show exactly what the encoder wrote into the final bytes,
    /// including any fields that were re-injected by the iOS JPEG/HEIC encoder.
    var outputFileFields: [MetadataField] = []

    /// The active export format chosen by the user.
    /// Changing this updates `selectedPreset` and re-triggers processing.
    var selectedExportFormat: ExportFormat = .original {
        didSet { selectedPreset = selectedExportFormat.exportPreset }
    }

    /// The active export preset. Changing it re-triggers processing if data is loaded.
    var selectedPreset: ExportPreset = .matchSource {
        didSet {
            guard rawImageData != nil else { return }
            if activeSheet == .preSave {
                Task { await prepareAndReview(presentSheet: false) }
            } else {
                processCurrentImage()
            }
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

    /// `true` while the current image's OCR pass is still running.
    var isScanningPII: Bool = false

    /// Populated when any step throws; `nil` on success.
    var errorMessage: String?

    // MARK: - Save flow state

    /// Controls which bottom sheet (if any) is currently presented.
    /// Only one sheet can be open at a time — assigning a new value safely
    /// replaces whatever is currently showing.
    var activeSheet: ActiveSheet?

    /// Shown when the user chose "Replace Original" but no asset identifier is available.
    var showReplaceUnavailableAlert: Bool = false

    /// PII types detected in the currently loaded image via on-device OCR.
    /// Empty when no image is loaded or the scan found nothing.
    var detectedPII: [DetectionResult] = []

    /// Pixel dimensions of the currently loaded image.
    /// Used by ContentView to compute the exact rendered frame of a .scaledToFit()
    /// image inside its container, so PII highlight boxes land on the right pixels.
    var imageSize: CGSize = .zero

    /// The result whose bounding boxes are currently highlighted on the image.
    /// `nil` means no row is selected and no boxes are drawn.
    var selectedPIIResult: DetectionResult?

    /// The set of `PIIType`s whose instances will be burned black on export.
    /// Auto-populated with every detected type when a scan completes (privacy by
    /// default).  The user can remove individual types in the PII details sheet.
    var typesToRedact: Set<PIIType> = []

    /// The redacted `UIImage` produced by `ImageRedactor`, cached so `requestSave()`
    /// and the share sheet both use the same rendered output without re-running the
    /// renderer twice.  Cleared whenever a new image is loaded.
    var redactedUIImage: UIImage?

    // MARK: - Batch state

    /// Items selected for batch processing via the multi-photo picker.
    var batchItems: [PhotosPickerItem] = []

    /// `true` while the sequential batch processing loop is running.
    var isBatchProcessing: Bool = false

    /// Current position within the batch — (photosProcessedSoFar, totalPhotos).
    var batchProgress: (current: Int, total: Int) = (0, 0)

    /// Set to `true` when `processBatch()` finishes — drives the transition to `BatchSummaryView`.
    var batchComplete: Bool = false

    /// Per-photo audit reports accumulated during the batch run.
    var batchReports: [AuditReport] = []

    /// Non-nil when the batch encounters a fatal error (e.g. photo library access denied).
    var batchErrorMessage: String?

    // MARK: - Private

    private let piiScanner = PIIScanner()

    private var isClearing: Bool = false
    private var piiScanTask: Task<Void, Never>?
    private var piiScanToken = UUID()

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
        sourceUIImage = nil
        pendingStrippedMetadata = nil
        sourceUTType = nil
        rawSourceProps = nil
        piiScanTask?.cancel()
        piiScanTask = nil
        piiScanToken = UUID()
        isScanningPII     = false
        detectedPII       = []
        imageSize         = .zero
        activeSheet       = nil
        selectedPIIResult = nil
        redactedUIImage   = nil
        typesToRedact     = []

        defer { isProcessing = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "The selected item could not be loaded as image data."
                return
            }

            rawImageData = data

            if let uiImage = UIImage(data: data) {
                inputImage    = Image(uiImage: uiImage)
                sourceUIImage = uiImage
                // Store point dimensions (not pixel dimensions).
                // ContentView's .scaledToFit() math operates in SwiftUI points,
                // so we match that coordinate space here.
                imageSize = uiImage.size
            }

            startPIIScan(data: data)

            processCurrentImage()
        } catch {
            errorMessage = error.localizedDescription
            rawImageData = nil
        }
    }

    // MARK: - Processing

    func processCurrentImage() {
        guard rawImageData != nil else { return }
        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }
        processImage()
    }

    private func startPIIScan(data: Data) {
        piiScanTask?.cancel()
        let token = UUID()
        piiScanToken = token
        isScanningPII = true

        piiScanTask = Task { [piiScanner] in
            let result: [DetectionResult]
            do {
                result = try await piiScanner.scanImage(data: data)
            } catch {
                result = []
            }

            await MainActor.run {
                guard self.piiScanToken == token, !Task.isCancelled else { return }
                self.detectedPII = result
                // Privacy by default: pre-select every detected type for redaction.
                self.typesToRedact = Set(result.map(\.type))
                self.isScanningPII = false
                self.piiScanTask = nil
            }
        }
    }

    private func waitForCurrentPIIScan() async {
        let task = piiScanTask
        await task?.value
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
    ///
    /// When `shouldRedactPII` is enabled and PII was detected, `ImageRedactor`
    /// burns the bounding boxes into the image first; the redacted pixel data is
    /// then fed into `ImageProcessor` for EXIF stripping before the review sheet
    /// appears.  The whole sequence runs in a detached `Task` so the call-site
    /// (a SwiftUI `Button`) can remain synchronous.
    func requestSave() {
        guard rawImageData != nil else { return }
        Task { await prepareAndReview() }
    }

    private func prepareAndReview(presentSheet: Bool = true) async {
        isProcessing = true
        defer { isProcessing = false }

        await waitForCurrentPIIScan()

        // Redaction path: burn only the instances whose type is in typesToRedact.
        let instancesToRedact = detectedPII
            .filter { typesToRedact.contains($0.type) }
            .flatMap(\.instances)

        if !instancesToRedact.isEmpty,
           let raw = rawImageData,
           let uiImage = UIImage(data: raw) {

            if let burned = await ImageRedactor().redact(image: uiImage, instances: instancesToRedact) {
                redactedUIImage = burned
                processImage(overridingImage: burned)
            } else {
                errorMessage = "Could not render redactions for this image."
                processedData = nil
                return
            }
        } else {
            redactedUIImage = nil
            processImage()
        }

        if presentSheet {
            activeSheet = .preSave
        }
    }

    /// Processes `override` data (or `rawImageData` when nil) through the EXIF
    /// stripping pipeline, updating `processedData` and related state.
    ///
    /// `rawSourceProps` and `allSourceMetadata` are derived from the *original*
    /// image only — they must never be overwritten by intermediate redacted data,
    /// which carries ghost iOS-injected TIFF/EXIF fields.
    private func processImage(overridingRawData override: Data? = nil, overridingImage imageOverride: UIImage? = nil) {
        guard let raw = override ?? rawImageData else { return }

        errorMessage = nil

        do {
            let result: ProcessedImage
            if let imageOverride, let sourceData = rawImageData {
                result = try ImageProcessor.process(
                    image: imageOverride,
                    sourceData: sourceData,
                    preset: selectedPreset,
                    config: stripConfig
                )
            } else {
                result = try ImageProcessor.process(data: raw, preset: selectedPreset, config: stripConfig)
            }
            processedData           = result.data
            sourceUTType            = result.sourceType
            pendingStrippedMetadata = result.stripped
            // Read the actual metadata present in the encoded output — captures any
            // fields the iOS encoder re-injected regardless of our stripping efforts.
            outputFileFields        = ImageProcessor.readAllFields(from: result.data)

            // Only update source props and display metadata when processing the
            // original image — not when processing redacted intermediate data.
            if override == nil && imageOverride == nil {
                if let source = CGImageSourceCreateWithData(raw as CFData, nil) {
                    rawSourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                }
                allSourceMetadata = ImageProcessor.catalogueStrippedMetadata(
                    from: rawSourceProps,
                    config: StripConfig(
                        categoryEnabled: Dictionary(
                            uniqueKeysWithValues: ImageProcessor.categoryMap.map { ($0.category, true) }
                        ),
                        fieldOverrides: [:]
                    )
                )
            }
        } catch {
            processedData           = nil
            pendingStrippedMetadata = nil
            errorMessage            = error.localizedDescription
        }
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
            incrementStats(photos: 1, fields: pendingFieldCount)
            activeSheet = nil
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
            incrementStats(photos: 1, fields: pendingFieldCount)
            activeSheet = nil
        } catch {
            errorMessage = "Could not replace photo: \(error.localizedDescription)"
        }
    }

    // MARK: - Lifetime stats

    /// Atomically increments the lifetime counters stored in `UserDefaults.standard`.
    ///
    /// - Parameters:
    ///   - photos: Number of photos successfully saved in this operation.
    ///   - fields: Number of non-structural metadata fields stripped in this operation.
    private func incrementStats(photos: Int = 0, fields: Int = 0) {
        let d = UserDefaults.standard
        if photos > 0 {
            d.set(d.integer(forKey: "picstrip.lifetimePhotos") + photos,
                  forKey: "picstrip.lifetimePhotos")
        }
        if fields > 0 {
            d.set(d.integer(forKey: "picstrip.lifetimeFields") + fields,
                  forKey: "picstrip.lifetimeFields")
        }
    }

    /// Number of non-structural metadata fields that will be stripped given the current config.
    private var pendingFieldCount: Int {
        pendingStrippedMetadata?.fields.filter { !$0.isStructural }.count ?? 0
    }

    // MARK: - Helpers

    /// Builds an `AuditReport` from current scan state, encodes it as pretty-printed
    /// JSON, writes it to a uniquely-named temp file, and returns the URL.
    /// Returns `nil` if encoding or writing fails.
    func generateAuditJSON() -> URL? {
        // 1. Visual redactions — only types the user has opted to redact.
        let visualRedactions: [RedactionReport] = detectedPII
            .filter { typesToRedact.contains($0.type) }
            .map { RedactionReport(type: $0.type.description, instanceCount: $0.matchCount) }

        // 2. Metadata stripped — non-structural fields grouped by category,
        //    respecting the current strip config (disabled categories are excluded).
        let metadataStripped: [MetadataCategoryReport] = {
            guard let source = allSourceMetadata else { return [] }
            var grouped: [String: [String: String]] = [:]
            for field in source.fields where !field.isStructural {
                guard ImageProcessor.shouldReportStripped(
                    category: field.category,
                    key: field.key,
                    isStructural: field.isStructural,
                    config: stripConfig
                ) else { continue }
                grouped[field.category, default: [:]][field.key] = field.value
            }
            return grouped
                .map { MetadataCategoryReport(category: $0.key, strippedFields: $0.value) }
                .sorted { $0.category < $1.category }
        }()

        // 3. Encode.
        let report = AuditReport(
            scanDate: Date(),
            formatSelected: selectedExportFormat.title,
            visualRedactions: visualRedactions,
            metadataStripped: metadataStripped
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting  = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(report) else { return nil }

        // 4. Write to temp file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicStrip_Audit_\(UUID().uuidString).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Batch processing

    /// Sequentially processes every item in `batchItems` using the supplied config.
    ///
    /// **Memory safety:** Images are processed one-at-a-time.  Local `UIImage` and
    /// `Data` references are explicitly nullified at the end of each iteration so ARC
    /// can reclaim the memory before the next image is decoded.  Concurrent
    /// `TaskGroup` execution is intentionally avoided — parallel Vision / CoreGraphics
    /// workers spike RAM and cause OOM crashes on device.
    func processBatch(config: BatchConfig) async {
        isBatchProcessing = true
        batchProgress     = (0, batchItems.count)
        batchReports      = []
        batchErrorMessage = nil

        // Capture the list once; `batchItems` must not be mutated during the loop.
        let items = batchItems

        // Request photo library authorization once before entering the loop.
        // Replace mode needs readWrite; save-as-new only needs addOnly.
        let requiredLevel: PHAccessLevel = config.saveMode == .replaceOriginal ? .readWrite : .addOnly
        let status = await PHPhotoLibrary.requestAuthorization(for: requiredLevel)
        guard status == .authorized || status == .limited else {
            batchErrorMessage = "Photo library access was denied. Please enable it in Settings."
            isBatchProcessing = false
            return
        }

        for (index, item) in items.enumerated() {
            batchProgress = (index + 1, items.count)

            // ── Step 1: Load raw bytes ──────────────────────────────────────
            guard var imageData = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let sourceData = imageData

            var visualRedactions: [RedactionReport] = []
            var redactedImage: UIImage?

            // ── Step 2: Visual PII redaction ────────────────────────────────
            // Sequential scan + render — no concurrent Tasks to avoid OOM.
            if config.redactVisualPII {
                if let scanResults = try? await PIIScanner().scanImage(data: imageData) {
                    let allInstances = scanResults.flatMap(\.instances)
                    if !allInstances.isEmpty {
                        var localImage: UIImage? = UIImage(data: imageData)
                        if let img = localImage,
                           let burned = await ImageRedactor().redact(image: img, instances: allInstances) {
                            redactedImage = burned
                        }
                        localImage = nil   // explicit release before metadata step
                    }
                    visualRedactions = scanResults.map {
                        RedactionReport(type: $0.type.description, instanceCount: $0.matchCount)
                    }
                }
            }

            // ── Step 3: Metadata stripping ──────────────────────────────────
            var metadataStripped: [MetadataCategoryReport] = []
            var finalData = imageData

            if config.stripMetadata {
                let preset = config.outputFormat.exportPreset
                let result: ProcessedImage?
                if let redactedImage {
                    result = try? ImageProcessor.process(
                        image: redactedImage,
                        sourceData: sourceData,
                        preset: preset,
                        config: .allEnabled
                    )
                } else {
                    result = try? ImageProcessor.process(
                        data: sourceData,
                        preset: preset,
                        config: .allEnabled
                    )
                }

                if let result {
                    finalData = result.data

                    // Build the per-category report from the *pre-strip* source props.
                    var rawProps: [CFString: Any]?
                    if let src = CGImageSourceCreateWithData(sourceData as CFData, nil) {
                        rawProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                    }
                    let sourceMeta = ImageProcessor.catalogueStrippedMetadata(
                        from: rawProps, config: .allEnabled
                    )
                    var grouped: [String: [String: String]] = [:]
                    for field in sourceMeta.fields where !field.isStructural {
                        grouped[field.category, default: [:]][field.key] = field.value
                    }
                    metadataStripped = grouped
                        .map { MetadataCategoryReport(category: $0.key, strippedFields: $0.value) }
                        .sorted { $0.category < $1.category }
                }
            } else if let redactedImage,
                      let result = try? ImageProcessor.process(
                        image: redactedImage,
                        sourceData: sourceData,
                        preset: config.outputFormat.exportPreset,
                        config: StripConfig(categoryEnabled: [:], fieldOverrides: [:])
                      ) {
                finalData = result.data
            }

            // ── Step 4: Save to Photo Library ───────────────────────────────
            let dataToSave = finalData
            var saveSucceeded = false
            switch config.saveMode {
            case .saveAsNew:
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: dataToSave, options: nil)
                    }
                    saveSucceeded = true
                } catch {
                    batchErrorMessage = "Some photos could not be saved."
                }
            case .replaceOriginal:
                if let identifier = item.itemIdentifier,
                   let asset = PHAsset.fetchAssets(
                       withLocalIdentifiers: [identifier], options: nil
                   ).firstObject {
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            let createRequest = PHAssetCreationRequest.forAsset()
                            createRequest.addResource(with: .photo, data: dataToSave, options: nil)
                            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                        }
                        saveSucceeded = true
                    } catch {
                        batchErrorMessage = "Some photos could not be replaced."
                    }
                } else {
                    // Fallback: original not found (e.g. not yet downloaded from iCloud).
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            let request = PHAssetCreationRequest.forAsset()
                            request.addResource(with: .photo, data: dataToSave, options: nil)
                        }
                        saveSucceeded = true
                        batchErrorMessage = "Some originals could not be identified, so cleaned copies were saved instead."
                    } catch {
                        batchErrorMessage = "Some photos could not be saved."
                    }
                }
            }

            // ── Step 5: Accumulate audit entry ──────────────────────────────
            if saveSucceeded {
                batchReports.append(AuditReport(
                    scanDate: Date(),
                    formatSelected: config.outputFormat.title,
                    visualRedactions: visualRedactions,
                    metadataStripped: metadataStripped
                ))
            }

            // OOM prevention: release large buffers before the next iteration.
            imageData = Data()
            finalData = Data()
        }

        isBatchProcessing = false
        batchComplete     = true

        // Tally lifetime stats for the completed batch.
        let totalFields = batchReports.reduce(0) {
            $0 + $1.metadataStripped.reduce(0) { $0 + $1.strippedFields.count }
        }
        incrementStats(photos: batchReports.count, fields: totalFields)
    }

    /// Wraps all per-photo `AuditReport`s in a `BatchAuditReport`, encodes it as
    /// pretty-printed JSON, writes it to a temp file, and returns the URL.
    func generateBatchAuditJSON() -> URL? {
        let batch = BatchAuditReport(
            batchDate: Date(),
            photoCount: batchItems.count,
            reports: batchReports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting     = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(batch) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicStrip_BatchAudit_\(UUID().uuidString).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// Resets all batch-related state and dismisses the batch sheet.
    func clearBatchState() {
        batchItems        = []
        isBatchProcessing = false
        batchProgress     = (0, 0)
        batchComplete     = false
        batchReports      = []
        batchErrorMessage = nil
        activeSheet       = nil
    }

    func clearState() {
        selectedItem            = nil
        isClearing              = false
        rawImageData            = nil
        rawSourceProps          = nil
        inputImage              = nil
        sourceUIImage           = nil
        processedData           = nil
        allSourceMetadata       = nil
        pendingStrippedMetadata = nil
        outputFileFields        = []
        sourceUTType            = nil
        errorMessage            = nil
        isProcessing            = false
        detectedPII             = []
        imageSize               = .zero
        activeSheet             = nil
        selectedPIIResult       = nil
        redactedUIImage         = nil
        typesToRedact           = []
        stripConfig             = .default
        piiScanTask?.cancel()
        piiScanTask             = nil
        piiScanToken            = UUID()
        isScanningPII           = false
    }
}
