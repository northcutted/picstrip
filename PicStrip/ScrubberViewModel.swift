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
    var outputFormat: ExportFormat = .heic
    /// Whether to save cleaned photos as new assets or overwrite the originals.
    var saveMode: BatchSaveMode = .saveAsNew

    /// `false` when neither option is on — the batch would only duplicate photos.
    var hasWork: Bool { stripMetadata || redactVisualPII }
}

// MARK: - Batch plumbing

/// One photo queued for batch processing, abstracted from `PhotosPickerItem` so
/// the batch loop can be unit-tested without the system picker.
struct BatchSource {
    /// Photo library identifier of the original, when the picker supplied one.
    let assetIdentifier: String?
    /// What is already known about the image (e.g. it is a document scan).
    var hints: ScanHints = .none
    /// Loads the photo's raw bytes; `nil` when the item cannot be read.
    let load: @Sendable () async -> Data?
}

enum BatchSaveResult {
    case saved
    /// Replace mode could not find the original, so a cleaned copy was saved instead.
    case savedCopyOriginalMissing
    case failed
}

/// Persists one cleaned photo. Injected so tests never touch the photo library.
typealias BatchSaver = (_ data: Data, _ assetIdentifier: String?, _ mode: BatchSaveMode) async -> BatchSaveResult

/// One video queued for a batch, abstracted from `PhotosPickerItem` like `BatchSource`.
struct VideoBatchSource {
    let assetIdentifier: String?
    /// Copies the video into the protected store; `nil` when it cannot be read.
    let load: @Sendable () async -> URL?
}

/// Persists one cleaned video. Injected so tests never touch the photo library.
typealias VideoBatchSaver = (_ url: URL, _ assetIdentifier: String?, _ mode: BatchSaveMode) async -> BatchSaveResult

/// Cleans one video of a batch (`VideoBatchCleaner.clean`); injected for tests.
typealias VideoBatchCleaning = @Sendable (
    _ url: URL, _ covering: Bool, _ alwaysCover: [String], _ progress: @escaping @Sendable (Double) -> Void
) async throws -> VideoBatchCleaner.Result

/// What `processBatchItem` hands back to the main actor for one photo.
nonisolated private struct BatchItemOutput: Sendable {
    let data: Data
    let visualRedactions: [RedactionReport]
    let metadataStripped: [MetadataCategoryReport]
    let coverage: ScanCoverage
}

/// An image's ImageIO property dictionary, frozen so it can be handed between
/// the background decoders and the main actor.
///
/// `@unchecked Sendable`: the dictionary comes straight from
/// `CGImageSourceCopyPropertiesAtIndex` and is never mutated afterwards; its
/// values are immutable property-list objects (strings, numbers, arrays,
/// dictionaries), which are safe to read from any thread.
nonisolated struct SourceProperties: @unchecked Sendable {
    let dictionary: [CFString: Any]

    init?(_ dictionary: [CFString: Any]?) {
        guard let dictionary else { return nil }
        self.dictionary = dictionary
    }

    init?(imageData: Data) {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        self.init(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}

/// What a freshly loaded image's metadata looks like, computed off the main actor.
nonisolated private struct SourceCatalog: Sendable {
    let props: SourceProperties?
    let stripped: StrippedMetadata
    let all: StrippedMetadata
    let utType: UTType?
}

nonisolated private struct ProcessingSnapshot: Sendable {
    let processed: ProcessedImage
    let outputFileFields: [MetadataField]
    let processedPreviewUIImage: UIImage?
    let rawSourceProps: SourceProperties?
    let allSourceMetadata: StrippedMetadata?
}

nonisolated private struct ProcessingRequest: Sendable {
    let raw: Data
    let sourceData: Data
    let imageOverride: UIImage?
    let preset: ExportPreset
    let config: StripConfig
    let updateSourceMetadata: Bool
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
    var isDemo = false
    var showResizeOffer = false
    private var pendingLargeImage: Data?

    /// The source `UIImage` retained so ContentView can use it in an
    /// `aspectRatio`-constrained overlay without re-decoding raw bytes.
    var sourceUIImage: UIImage?

    /// How many times larger the exported image is than `sourceUIImage` (≥ 1).
    /// The editor's live preview scales pixel-based effects by this so a box
    /// looks the way it will in the saved file.
    private(set) var exportScale: CGFloat = 1

    /// The scrubbed, re-encoded image bytes ready for saving or sharing.
    var processedData: Data?

    /// Downsampled preview decoded from `processedData` off the main actor.
    /// Avoids repeatedly decoding the export bytes from SwiftUI computed
    /// properties while preserving full-resolution bytes for save/share.
    var processedPreviewUIImage: UIImage?

    /// Every metadata field actually present in the output file after encoding.
    /// Populated after each processing pass — including the redacted path — so the
    /// review screen can show exactly what the encoder wrote into the final bytes,
    /// including any fields that were re-injected by the iOS JPEG/HEIC encoder.
    var outputFileFields: [MetadataField] = [] {
        didSet { outputFieldKeys = Set(outputFileFields.map { "\($0.category).\($0.key)" }) }
    }

    /// `"<Category>.<Key>"` for every field in `outputFileFields`, for O(1) lookup.
    @ObservationIgnored private var outputFieldKeys: Set<String> = []

    /// The active export format chosen by the user.
    ///
    /// Changing it re-triggers processing only when the review sheet is currently
    /// open; otherwise the change is recorded and a fresh encode runs the next
    /// time the user opens review.  This avoids re-encoding on every format
    /// toggle when nothing on screen actually depends on `processedData`.
    var selectedExportFormat: ExportFormat = .png {
        didSet {
            guard selectedExportFormat != oldValue, rawImageData != nil else { return }
            if activeSheet == .preSave {
                Task { await prepareAndReview(presentSheet: false) }
            }
        }
    }

    /// The stripping-engine preset for `selectedExportFormat`.
    ///
    /// Derived rather than stored so the format shown in the UI and audit report
    /// can never drift from the format the encoder actually uses.
    var selectedPreset: ExportPreset { selectedExportFormat.exportPreset }

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

    /// How far the running scan has got, from the scanner's own milestones.
    private(set) var scanProgress = ScanProgress.notStarted

    /// `true` while the on-device language model is still looking for names in a
    /// scan that has already been published.  Nothing waits on it.
    private(set) var isFindingNames = false

    /// A failed detector is never represented as an empty successful result.
    private(set) var scanCoverage = ScanCoverage()
    private(set) var scanFailureMessage: String?
    var manualReviewAcknowledged = false

    var canExport: Bool {
        processedData != nil && !isProcessing && (!scanCoverage.requiresManualReview || manualReviewAcknowledged)
    }

    var findingsLeftVisible: Int {
        detectedPII.flatMap(\.instances).filter { finding in
            !enabledRedactionRegions.contains {
                $0.rect.insetBy(dx: -0.001, dy: -0.001).contains(finding.boundingBox)
            }
        }.count
    }

    var shareImage: CleanedImage? {
        processedData.flatMap(CleanedImage.init(data:))
    }

    /// Populated when any step throws; `nil` on success.
    var errorMessage: String?

    /// What cleaning takes out of the current image — for the review sheet and
    /// the confirmation after saving.  Counts only, never a value.
    struct SharingSummary: Equatable {
        var locationRemoved = false
        var metadataFieldsRemoved = 0
        var detailsCovered = 0
    }

    var sharingSummary: SharingSummary {
        let removed = allSourceMetadata?.fields.filter(isRemoved) ?? []
        return SharingSummary(
            locationRemoved: removed.contains { $0.category == "GPS" },
            metadataFieldsRemoved: removed.count,
            detailsCovered: enabledRedactionRegions.count
        )
    }

    /// Set when a cleaned copy has reached the photo library, for the
    /// confirmation shown over the editor; cleared when it has been seen.
    struct SavedConfirmation: Identifiable, Equatable {
        let id = UUID()
        let summary: SharingSummary
        let replacedOriginal: Bool
    }

    var savedConfirmation: SavedConfirmation?

    /// The picker item when the open photo is a Live Photo, whose motion can be
    /// kept on save; `nil` for everything else.
    private(set) var livePhotoItem: PhotosPickerItem?
    var keepsLivePhotoMotion = false

    /// The motion is not covered like the still, so it may only be kept when
    /// nothing is covered — and in a format that can carry the pairing (not PNG).
    var canKeepLivePhotoMotion: Bool {
        livePhotoItem != nil && enabledRedactionRegions.isEmpty && selectedExportFormat != .png
    }

    // MARK: - Save flow state

    /// Controls which bottom sheet (if any) is currently presented.
    /// Only one sheet can be open at a time — assigning a new value safely
    /// replaces whatever is currently showing.
    var activeSheet: ActiveSheet? {
        didSet {
            // A full-size render is only worth its memory while Review & Share is open.
            if activeSheet != .preSave { reviewRedaction = nil }
        }
    }

    /// What a render of the enabled regions depends on.
    struct RedactionKey: Equatable {
        /// The load the bytes came from (`loadToken`).
        let image: UUID
        let specs: [RedactionSpec]
    }

    /// The enabled regions rendered at full size, kept while Review & Share is
    /// open so that changing the format there pays only for the encode.
    struct ReviewRedaction {
        let key: RedactionKey
        let image: UIImage
    }

    @ObservationIgnored private(set) var reviewRedaction: ReviewRedaction?

    /// What `processedData` was encoded from, so opening the review again with
    /// nothing changed shows those bytes instead of encoding them again.
    private struct ExportKey: Equatable {
        let redaction: RedactionKey
        let preset: ExportPreset
        let config: StripConfig
    }

    @ObservationIgnored private var processedKey: ExportKey?

    /// Lets go of the full-size render, e.g. on a memory warning.  The next
    /// format change in the review renders the regions again.
    func releaseReviewRedaction() {
        reviewRedaction = nil
    }

    /// Shown when the user chose "Replace Original" but no asset identifier is available.
    var showReplaceUnavailableAlert: Bool = false

    /// `true` when the loaded image came from the Photos picker with a library
    /// identifier — i.e. there is an original asset "Replace Original" can target.
    /// Images from Files, drag and drop, paste, or the Share Extension have none.
    var canReplaceOriginal: Bool { selectedItem?.itemIdentifier != nil }

    /// PII types detected in the currently loaded image via on-device OCR.
    /// Empty when no image is loaded or the scan found nothing.
    /// Setting this property automatically rebuilds `redactionRegions` from
    /// the new results so that `redactionPreviewResults` and derived views
    /// stay in sync without requiring callers to call
    /// `replaceDetectedRedactionRegions` separately.
    var detectedPII: [DetectionResult] = [] {
        didSet {
            guard !isAppendingDetections else { return }
            replaceDetectedRedactionRegions(from: detectedPII)
        }
    }

    /// Set while late findings are added, so the regions the user may already
    /// have moved, restyled or deleted are not rebuilt from scratch.
    @ObservationIgnored private var isAppendingDetections = false

    /// Pixel dimensions of the currently loaded image.
    /// Used by ContentView to compute the exact rendered frame of a .scaledToFit()
    /// image inside its container, so PII highlight boxes land on the right pixels.
    var imageSize: CGSize = .zero

    /// The result whose bounding boxes are temporarily emphasized on the image.
    /// `nil` means the image falls back to the subtle all-redactions overlay.
    var selectedPIIResult: DetectionResult?

    /// The set of `PIIType`s whose instances will be burned black on export.
    /// Auto-populated with every detected type when a scan completes (privacy by
    /// default).  The user can remove individual types in the PII details sheet.
    var typesToRedact: Set<PIIType> = [] {
        didSet { syncDetectedRegionEnablement() }
    }

    /// What the current image is being shared as: it picks the export format and
    /// which findings are covered straight away.  Guessed when an image loads
    /// (`SharingPurpose.detect`); the user can change it.
    var sharingPurpose: SharingPurpose = .photo

    /// The words and phrases the user wants covered in every photo.
    let alwaysCoverList: AlwaysCoverList

    /// The text the last scan read, kept so a new Always Cover term can be
    /// found in the open photo without scanning it again.
    @ObservationIgnored private var scannedLines: [ScannedLine] = []
    @ObservationIgnored private var currentHints: ScanHints = .none

    /// Editable per-photo redaction boxes. Detected boxes are seeded from OCR;
    /// custom boxes are user-created and never persisted across photos.
    var redactionRegions: [RedactionRegion] = []

    /// Currently selected redaction box in the preview editor.
    var selectedRedactionRegionID: String?

    private var selectedRedactionRegion: RedactionRegion? {
        guard let selectedRedactionRegionID else { return nil }
        return redactionRegions.first { $0.id == selectedRedactionRegionID }
    }

    var enabledRedactionRegions: [RedactionRegion] {
        redactionRegions.filter(\.isEnabled)
    }

    /// Detected visual results that currently have at least one enabled region.
    /// Used by the photo preview to show subtle always-on redaction outlines.
    /// Derived from `enabledRedactionRegions` so per-instance toggles are reflected
    /// immediately without needing to consult `typesToRedact`.
    var redactionPreviewResults: [DetectionResult] {
        let enabledTypes = Set(enabledRedactionRegions.compactMap(\.type))
        return detectedPII.filter { enabledTypes.contains($0.type) && !$0.instances.isEmpty }
    }

    /// The redacted `UIImage` produced by `ImageRedactor`, cached so `requestSave()`
    /// and the share sheet both use the same rendered output without re-running the
    /// renderer twice.  Cleared whenever a new image is loaded.
    var redactedUIImage: UIImage?

    /// Image shown in the review sheet preview.
    ///
    /// Prefer the rendered redaction image whenever selected visual redactions
    /// exist so the user can inspect blacked-out regions before saving. Saving
    /// and sharing still use `processedData`, which has passed through metadata
    /// stripping.
    var reviewPreviewUIImage: UIImage? {
        processedPreviewUIImage ?? redactedUIImage ?? sourceUIImage
    }

    // MARK: - Batch state

    /// Items selected for batch processing via the multi-photo picker.
    var batchItems: [PhotosPickerItem] = []

    /// Videos picked for the batch, cleaned after its photos.
    var batchVideoItems: [PhotosPickerItem] = []

    /// How far the video being cleaned has got, 0 … 1; `nil` while a photo is.
    var batchVideoFraction: Double?

    /// Pages captured in-app (document scanner) queued for batch processing.
    /// They exist only in memory: there is no library original to replace, and
    /// dropping this array is what releases the un-redacted capture.
    var scannedBatchSources: [BatchSource] = []

    /// How many images the batch sheet is about to process.
    var batchCount: Int {
        scannedBatchSources.isEmpty ? batchItems.count : scannedBatchSources.count
    }

    /// Videos read from files rather than picked: the UI tests' batch fixture
    /// (`openFileBatch`).
    var fileBatchVideos: [URL] = []

    /// How many videos the batch sheet is about to process.
    var batchVideoCount: Int { batchVideoItems.count + fileBatchVideos.count }

    /// Captured pages were never in the photo library, so "Replace Original"
    /// has nothing to replace.
    var batchAllowsReplaceOriginal: Bool { scannedBatchSources.isEmpty }

    /// `true` while the sequential batch processing loop is running.
    var isBatchProcessing: Bool = false

    /// Current position within the batch — (photosProcessedSoFar, totalPhotos).
    var batchProgress: (current: Int, total: Int) = (0, 0)

    /// Set to `true` when `processBatch()` finishes — drives the transition to `BatchSummaryView`.
    var batchComplete: Bool = false

    /// Per-photo audit reports accumulated during the batch run — one per photo
    /// that was cleaned **and** accepted by the photo library.
    var batchReports: [AuditReport] = []

    /// Photos in the current batch that could not be loaded, cleaned, or saved.
    var batchFailedCount: Int = 0

    /// Photos in the current batch that were cleaned and saved.
    var batchSucceededCount: Int { batchReports.count }

    /// Non-nil when the batch encounters a fatal error (e.g. photo library access denied).
    var batchErrorMessage: String?

    // MARK: - Undo / Redo

    /// Whether there is at least one action to undo.
    var canUndo: Bool { !undoStack.isEmpty }

    /// Whether there is at least one action to redo.
    var canRedo: Bool { !redoStack.isEmpty }

    /// Snapshots of `redactionRegions` taken before each user-driven mutation.
    /// Capped at 50 entries to avoid unbounded memory growth.
    private var undoStack: [[RedactionRegion]] = []

    /// Snapshots pushed when the user undoes an action, enabling redo.
    private var redoStack: [[RedactionRegion]] = []

    /// The region ID currently being moved or resized by a drag gesture.
    /// Used to push exactly one snapshot per drag gesture (not one per event).
    private var activeDragID: String?

    /// Saves the current `redactionRegions` to the undo stack and clears the
    /// redo stack. Call this before any mutation that should be undoable.
    private func pushUndoSnapshot() {
        undoStack.append(redactionRegions)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        activeDragID = nil
    }

    private func clearUndoRedoStacks() {
        undoStack.removeAll()
        redoStack.removeAll()
        activeDragID = nil
    }

    /// Called by the view when a move or resize drag gesture begins for a region.
    ///
    /// Pushes exactly one undo snapshot per gesture, regardless of how many
    /// `.onChanged` events fire. Subsequent calls for the same `id` within
    /// the same gesture are no-ops.
    func beginRedactionUpdate(id: String) {
        guard activeDragID != id else { return }
        pushUndoSnapshot()
        activeDragID = id
    }

    /// Restores `redactionRegions` to the state before the last user action.
    func undoRedaction() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(redactionRegions)
        redactionRegions = snapshot
        // Deselect if the selected region no longer exists after undo.
        if let id = selectedRedactionRegionID,
           !redactionRegions.contains(where: { $0.id == id }) {
            selectedRedactionRegionID = nil
        }
        redactedUIImage = nil
        activeDragID = nil
    }

    /// Re-applies the most recently undone action.
    func redoRedaction() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(redactionRegions)
        redactionRegions = snapshot
        // Deselect if the selected region no longer exists after redo.
        if let id = selectedRedactionRegionID,
           !redactionRegions.contains(where: { $0.id == id }) {
            selectedRedactionRegionID = nil
        }
        redactedUIImage = nil
        activeDragID = nil
    }

    // MARK: - Private

    @ObservationIgnored private let scan: @Sendable (Data, ScanHints, ScanProgressHandler?) async throws -> ScanOutput
    @ObservationIgnored private let semantic: SemanticPII
    @ObservationIgnored private let objectSelection: ObjectSelection

    /// The application uses the real on-device scanner, language model and
    /// segmentation; tests inject their own so they never boot Vision or a model.
    init(
        scan: @escaping @Sendable (Data, ScanHints, ScanProgressHandler?) async throws -> ScanOutput = {
            try await PIIScanner().scan(data: $0, hints: $1, progress: $2)
        },
        semantic: SemanticPII = .live,
        objectSelection: ObjectSelection = .live,
        alwaysCoverList: AlwaysCoverList = .shared
    ) {
        self.scan = scan
        self.semantic = semantic
        self.objectSelection = objectSelection
        self.alwaysCoverList = alwaysCoverList
    }

    /// For tests that supply findings directly: no recognised text, so no name pass.
    convenience init(
        scanImageWithHints: @escaping @Sendable (Data, ScanHints) async throws -> [DetectionResult],
        objectSelection: ObjectSelection = .unsupported,
        alwaysCoverList: AlwaysCoverList = AlwaysCoverList(fileURL: nil)
    ) {
        self.init(
            scan: { data, hints, _ in ScanOutput(results: try await scanImageWithHints(data, hints), lines: []) },
            semantic: .unavailable,
            objectSelection: objectSelection,
            alwaysCoverList: alwaysCoverList
        )
    }

    /// For tests that do not care about scan hints.
    convenience init(
        scanImage: @escaping @Sendable (Data) async throws -> [DetectionResult],
        objectSelection: ObjectSelection = .unsupported
    ) {
        self.init(scanImageWithHints: { data, _ in try await scanImage(data) }, objectSelection: objectSelection)
    }

    /// The in-flight picker load, cancelled when a newer selection supersedes it.
    private var loadTask: Task<Void, Never>?

    /// Rejects stale load completions: a slow `loadTransferable` for photo A must
    /// not overwrite state after the user has already moved on to photo B.
    private var loadToken = UUID()

    private var piiScanTask: Task<Void, Never>?
    /// The on-device name pass.  It runs after the scan has been published, so
    /// neither the editor nor a save ever waits for the language model.
    private var nameScanTask: Task<Void, Never>?
    private var piiScanToken = UUID()
    private(set) var piiFocusTask: Task<Void, Never>?

    /// The unprocessed image bytes retained so preset / config changes can re-process
    /// without requiring the user to re-pick the image.
    private var rawImageData: Data?

    /// The raw source properties from ImageIO — used to rebuild pendingStrippedMetadata
    /// cheaply when only the config changes (without re-running the full encode pipeline).
    private var rawSourceProps: SourceProperties?

    /// Rejects stale processing completions when the user changes photo, preset,
    /// or redaction settings while an off-main encode is still running.
    private var processingToken = UUID()
    private var reviewToken = UUID()
    private var batchCancellationRequested = false
    /// Originals replace mode could not find, across the photos and videos of a batch.
    private var batchOriginalsNotFound = 0
    /// The video being cleaned, so Stop does not wait for the whole of it.
    private var batchVideoTask: Task<VideoBatchCleaner.Result, Error>?

    // MARK: - Item change handler

    private func handleItemChange() {
        guard let item = selectedItem else { return }
        loadTask?.cancel()
        loadTask = Task { await loadAndProcess(item: item) }
    }

    // MARK: - Async load pipeline

    /// Loads image bytes directly — bypasses `PhotosPickerItem`.
    ///
    /// Used for every input that is not a Photos picker selection: Files, drag
    /// and drop, paste, the Share Extension hand-off, and UITest fixture
    /// injection (`PICSTRIP_FIXTURE` in `launchEnvironment`).
    func loadData(_ data: Data, hints: ScanHints = .none, isDemo: Bool = false) async {
        loadTask?.cancel()
        loadTask = nil
        // These bytes did not come from the picker, so any previous selection no
        // longer describes the loaded image.  Leaving it set would let "Replace
        // Original" delete an unrelated library asset.
        selectedItem = nil

        let token = resetForNewImage()
        self.isDemo = isDemo
        await ingest(data, token: token, hints: hints)
    }

    /// Loads images captured inside the app.  One page opens in the editor like
    /// any other image; several pages go through the batch flow.
    func loadCaptured(_ pages: CapturedPages) async {
        guard pages.count >= 1 else { return }
        if pages.count == 1 {
            let token = loadToken
            let data = await pages.data(0)
            guard loadToken == token, !Task.isCancelled else { return }
            guard let data else {
                errorMessage = pages.hints.wholeImageIsDocument
                    ? String(localized: "The document could not be scanned.")
                    : String(localized: "The selected item could not be loaded as image data.")
                return
            }
            await loadData(data, hints: pages.hints)
        } else {
            batchItems = []
            scannedBatchSources = (0..<pages.count).map { index in
                BatchSource(assetIdentifier: nil, hints: pages.hints) { await pages.data(index) }
            }
            activeSheet = .batch
        }
    }

    private func loadAndProcess(item: PhotosPickerItem) async {
        let token = resetForNewImage()
        livePhotoItem = item.supportedContentTypes.contains(.livePhoto) ? item : nil

        do {
            let incoming = try await item.loadTransferable(type: IncomingImage.self)
            guard loadToken == token else { return }
            guard let data = incoming?.data else {
                errorMessage = String(localized: "The selected item could not be loaded as image data.")
                isProcessing = false
                return
            }
            await ingest(data, token: token)
        } catch {
            guard loadToken == token, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
            rawImageData = nil
            isProcessing = false
        }
    }

    /// Clears all per-photo state and returns the token identifying the new load.
    private func resetForNewImage() -> UUID {
        isDemo = false
        pendingLargeImage = nil
        showResizeOffer = false
        let token = UUID()
        loadToken = token

        isProcessing = true
        errorMessage = nil
        rawImageData = nil
        processedData = nil
        processedKey = nil
        processedPreviewUIImage = nil
        inputImage = nil
        sourceUIImage = nil
        allSourceMetadata = nil
        pendingStrippedMetadata = nil
        outputFileFields = []
        sourceUTType = nil
        rawSourceProps = nil
        piiScanTask?.cancel()
        piiScanTask = nil
        nameScanTask?.cancel()
        nameScanTask = nil
        piiFocusTask?.cancel()
        piiFocusTask = nil
        piiScanToken = UUID()
        isScanningPII = false
        isFindingNames = false
        scanProgress = .notStarted
        scanCoverage = ScanCoverage()
        scanFailureMessage = nil
        manualReviewAcknowledged = false
        detectedPII = []
        imageSize = .zero
        activeSheet = nil
        selectedPIIResult = nil
        redactionRegions = []
        selectedRedactionRegionID = nil
        redactedUIImage = nil
        typesToRedact = []
        savedConfirmation = nil
        livePhotoItem = nil
        keepsLivePhotoMotion = false
        scannedLines = []
        currentHints = .none
        sharingPurpose = .photo
        clearUndoRedoStacks()

        return token
    }

    /// Decoding the preview, reading the metadata and scanning do not depend on
    /// each other, so they all start at once: a large PNG takes seconds to decode,
    /// and nothing else should queue behind that.
    private func ingest(_ data: Data, token: UUID, hints: ScanHints = .none) async {
        do {
            try ImageResourceBudget.editor.validate(data)
        } catch ImageResourceBudget.AdmissionError.resolutionTooLarge {
            pendingLargeImage = data
            showResizeOffer = true
            isProcessing = false
            return
        } catch {
            errorMessage = error.localizedDescription
            isProcessing = false
            return
        }
        currentHints = hints
        startPIIScan(data: data, hints: hints)
        async let metadata: Void = catalogSourceMetadata(from: data)
        let preview = await Self.makePreviewImage(from: data)
        guard loadToken == token else { return }

        // Pasted, dropped, and shared bytes are not guaranteed to be an image
        // ImageIO can decode.  Without a preview there is nothing to show or edit,
        // and the scan's own complaint about the same bytes would be noise.
        guard let preview else {
            piiScanTask?.cancel()
            piiScanTask = nil
            piiScanToken = UUID()
            isScanningPII = false
            errorMessage = String(localized: "The selected item could not be loaded as image data.")
            isProcessing = false
            return
        }

        rawImageData  = data
        inputImage    = Image(uiImage: preview)
        sourceUIImage = preview
        let previewLongEdge = max(preview.size.width, preview.size.height) * preview.scale
        let fullLongEdge = ImageProcessor.pixelSize(of: data).map { max($0.width, $0.height) } ?? previewLongEdge
        exportScale = previewLongEdge > 0 ? max(1, fullLongEdge / previewLongEdge) : 1
        // Store point dimensions (not pixel dimensions).
        // ContentView's .scaledToFit() math operates in SwiftUI points,
        // so we match that coordinate space here.
        imageSize = preview.size
        isProcessing = false

        await metadata
    }

    func discardLargeImage() {
        pendingLargeImage = nil
        showResizeOffer = false
    }

    func useSmallerCopy() async {
        guard let data = pendingLargeImage else { return }
        pendingLargeImage = nil
        showResizeOffer = false
        isProcessing = true
        let token = loadToken
        do {
            let resized = try await Task.detached(priority: .userInitiated) {
                try ImageResourceBudget.smallerCopy(data)
            }.value
            guard loadToken == token else { return }
            await loadData(resized)
        } catch {
            guard loadToken == token else { return }
            errorMessage = error.localizedDescription
            isProcessing = false
        }
    }

    // MARK: - Processing

    /// `true` when the encode's result was stored.
    private func processCurrentImageNow(plan: ExportPlan) async -> Bool {
        guard let raw = rawImageData else {
            isProcessing = false
            return false
        }
        return await processImage(
            raw: raw,
            sourceData: raw,
            imageOverride: nil,
            plan: plan,
            updateSourceMetadata: true
        )
    }

    /// Reads source metadata properties without re-encoding the image.
    ///
    /// Called immediately after a photo loads so the badge row and category panels
    /// populate without paying the cost of a full ImageProcessor encode.  The
    /// encode itself is deferred to `prepareAndReview`, which runs only when the
    /// user opens the review sheet to save or share.
    private func catalogSourceMetadata(from data: Data) async {
        let token = UUID()
        processingToken = token

        let catalog = await Self.makeSourceCatalog(from: data, config: stripConfig)

        guard processingToken == token else { return }
        rawSourceProps          = catalog.props
        pendingStrippedMetadata = catalog.stripped
        allSourceMetadata       = catalog.all
        sourceUTType            = catalog.utType
        adoptDetectedPurpose(SharingPurpose.detect(properties: catalog.props?.dictionary, hints: currentHints))
    }

    /// Takes on the purpose guessed for a freshly loaded image — its format, and
    /// its selection if the scan has already finished.
    private func adoptDetectedPurpose(_ purpose: SharingPurpose) {
        sharingPurpose = purpose
        selectedExportFormat = purpose.format
        if !isScanningPII, !detectedPII.isEmpty {
            typesToRedact = Set(detectedPII.map(\.type).filter(purpose.coversByDefault))
        }
    }

    private static func makePreviewImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            ImageProcessor.downsampledUIImage(from: data)
        }.value
    }

    private func startPIIScan(data: Data, hints: ScanHints = .none) {
        piiScanTask?.cancel()
        let token = UUID()
        piiScanToken = token
        isScanningPII = true
        scanProgress = .started
        scanCoverage = ScanCoverage()
        for check in ScanCoverage.requiredChecks { scanCoverage[check] = .checking }
        scanFailureMessage = nil
        manualReviewAcknowledged = false

        nameScanTask?.cancel()
        nameScanTask = nil
        isFindingNames = false

        // The scanner reports from its own executor; hop back before touching state.
        let report: ScanProgressHandler = { [weak self] step in
            Task { @MainActor in
                guard let self, self.piiScanToken == token, self.isScanningPII else { return }
                self.scanProgress.record(step)
            }
        }

        piiScanTask = Task { [scan] in
            let result: [DetectionResult]
            var lines: [ScannedLine] = []
            var scanError: String?
            var coverage = ScanCoverage.failed
            do {
                let output = try await scan(data, hints, report)
                result = output.results
                lines = output.lines
                coverage = output.coverage
            } catch {
                // Never let a failed scan look like a clean one: tell the user so
                // they know to check the photo themselves.
                result = []
                scanError = error.localizedDescription
            }

            await MainActor.run {
                guard self.piiScanToken == token, !Task.isCancelled else { return }
                if let scanError { self.errorMessage = scanError }
                self.scanFailureMessage = scanError
                self.scanCoverage = coverage
                self.scannedLines = lines
                let findings = PIIScanner.sorted(
                    result + AlwaysCoverMatcher.results(terms: self.alwaysCoverList.terms, lines: lines)
                )
                self.detectedPII = findings
                // Privacy by default: pre-select every detected type the sharing
                // purpose covers.  `detectedPII.didSet` already called
                // replaceDetectedRedactionRegions; syncDetectedRegionEnablement (via
                // typesToRedact.didSet) then enables each region whose type is in
                // typesToRedact.
                self.typesToRedact = Set(findings.map(\.type).filter(self.sharingPurpose.coversByDefault))
                self.isScanningPII = false
                self.scanProgress = .finished
                self.piiScanTask = nil
                self.startNameScan(lines: lines, token: token)
            }
        }
    }

    /// Asks the on-device language model for people's names in the recognised
    /// text and adds what it finds to the already-published scan.
    private func startNameScan(lines: [ScannedLine], token: UUID) {
        guard semantic.isAvailable() else {
            scanCoverage[.names] = .unavailable
            return
        }
        guard !lines.isEmpty else {
            scanCoverage[.names] = scanCoverage[.text] == .complete ? .complete : .notChecked
            return
        }
        isFindingNames = true
        scanCoverage[.names] = .checking
        nameScanTask = Task { [semantic] in
            let outcome = await semantic.scan(lines.map(\.text))
            // The photo may have been replaced while the model was thinking.
            guard !Task.isCancelled, self.piiScanToken == token else { return }
            self.appendDetections(SemanticPIIMerger.merge(names: outcome.names, lines: lines, into: []))
            self.nameScanTask = nil
            self.isFindingNames = false
            self.scanCoverage[.names] = outcome.status
        }
    }

    /// Adds findings that arrived after the scan was published.  Unlike setting
    /// `detectedPII`, this leaves every existing region exactly as the user has
    /// it — moved, restyled, disabled or deleted — and adds the new ones to the
    /// undo history too, so an undo cannot make them vanish.
    private func appendDetections(_ results: [DetectionResult]) {
        var merged = detectedPII
        var regions: [RedactionRegion] = []
        for result in results {
            // A kind already found gains instances; its regions' ids carry on
            // from the existing ones so none repeats.
            let index = merged.firstIndex { $0.type == result.type }
            let existing = index.map { merged[$0].instances } ?? []
            let added = result.instances.filter { instance in
                !existing.contains { PIIScanner.representsSameRegion($0.boundingBox, instance.boundingBox) }
            }
            guard !added.isEmpty else { continue }
            if let index {
                merged[index].instances += added
                merged[index].score = max(merged[index].score, result.score)
            } else {
                merged.append(result)
            }
            regions += added.enumerated().map { offset, instance in
                RedactionRegion.detected(
                    result: result, instance: instance, index: existing.count + offset,
                    isEnabled: typesToRedact.contains(result.type)
                )
            }
        }
        guard !regions.isEmpty else { return }
        isAppendingDetections = true
        detectedPII = PIIScanner.sorted(merged)
        isAppendingDetections = false

        // Detected regions come before custom ones, as in `replaceDetectedRedactionRegions`.
        func adding(to existing: [RedactionRegion]) -> [RedactionRegion] {
            let firstCustom = existing.firstIndex { $0.source == .custom } ?? existing.endIndex
            var updated = existing
            updated.insert(contentsOf: regions, at: firstCustom)
            return updated
        }
        redactionRegions = adding(to: redactionRegions)
        undoStack = undoStack.map(adding)
        redoStack = redoStack.map(adding)
        if regions.contains(where: \.isEnabled) { redactedUIImage = nil }
    }

    private func waitForCurrentPIIScan() async {
        let task = piiScanTask
        await task?.value
    }

    func focusPIIResult(_ result: DetectionResult) {
        selectedPIIResult = result
        selectedRedactionRegionID = redactionRegions.first {
            $0.source == .detected && $0.type == result.type
        }?.id
        piiFocusTask?.cancel()
        piiFocusTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self.selectedPIIResult == result {
                    self.selectedPIIResult = nil
                    if self.selectedRedactionRegion?.type == result.type {
                        self.selectedRedactionRegionID = nil
                    }
                }
                self.piiFocusTask = nil
            }
        }
    }

    /// Adds `term` to the Always Cover list and covers it in the open photo.
    func alwaysCover(_ term: String) {
        alwaysCoverList.add(term)
        refreshAlwaysCover()
    }

    /// Finds Always Cover terms added since the open photo was scanned.
    func refreshAlwaysCover() {
        let found = AlwaysCoverMatcher.results(terms: alwaysCoverList.terms, lines: scannedLines)
        guard !found.isEmpty else { return }
        typesToRedact.insert(.alwaysCover)
        appendDetections(found)
    }

    func addCustomRedaction(rect: CGRect) {
        pushUndoSnapshot()
        let region = RedactionRegion.custom(rect: rect)
        redactionRegions.append(region)
        selectedRedactionRegionID = region.id
        redactedUIImage = nil
    }

    // MARK: - Tap an object to redact it

    /// Whether tapping an object can be offered at all on this OS.
    private(set) var isObjectSelectionSupported = false

    /// `true` while the consent prompt for the one-time model download is due.
    /// The model is fetched by the OS from Apple; PicStrip never starts that
    /// without asking, because the app otherwise never touches the network.
    var isAskingToDownloadObjectModel = false

    /// `true` while the model downloads or an object is being outlined.
    private(set) var isSelectingObject = false

    /// Set when a tap found nothing, or the model could not be fetched.
    var objectSelectionMessage: String?

    /// The tap waiting for the user's answer to the download prompt.
    @ObservationIgnored private var pendingObjectPoint: CGPoint?

    func refreshObjectSelectionSupport() async {
        isObjectSelectionSupported = await objectSelection.availability() != .unsupported
    }

    /// Adds a region around the object under `point` (normalised, top-left origin).
    func selectObject(at point: CGPoint) async {
        guard let data = rawImageData, !isSelectingObject else { return }
        switch await objectSelection.availability() {
        case .unsupported:
            return
        case .needsDownload:
            pendingObjectPoint = point
            isAskingToDownloadObjectModel = true
        case .ready:
            await outlineObject(at: point, in: data)
        }
    }

    /// The user agreed to the download: fetch the model, then finish the tap that asked for it.
    func downloadObjectModelAndContinue() async {
        guard let point = pendingObjectPoint else { return }
        pendingObjectPoint = nil
        isSelectingObject = true
        do {
            try await objectSelection.downloadModel()
        } catch {
            isSelectingObject = false
            objectSelectionMessage = String(localized: "The object selection model could not be downloaded. You can still drag to draw a box.")
            return
        }
        isSelectingObject = false
        guard let data = rawImageData else { return }
        await outlineObject(at: point, in: data)
    }

    func declineObjectModelDownload() {
        pendingObjectPoint = nil
    }

    private func outlineObject(at point: CGPoint, in data: Data) async {
        isSelectingObject = true
        defer { isSelectingObject = false }
        let token = loadToken
        let box = try? await objectSelection.boundingBox(point, data)
        // The photo may have been replaced while the model was working.
        guard loadToken == token else { return }
        guard let box else {
            objectSelectionMessage = String(localized: "No object was found there. Drag to draw a box instead.")
            return
        }
        addCustomRedaction(rect: RedactionRegion.clamped(box))
    }

    /// One accessible adjustment is one undo step, just like a drag gesture.
    func adjustRedactionRegion(id: String, rect: CGRect) {
        guard redactionRegions.contains(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        updateRedactionRegion(id: id, rect: rect)
    }

    func updateRedactionRegion(id: String, rect: CGRect) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }) else { return }
        redactionRegions[index].rect = RedactionRegion.clamped(rect)
        redactedUIImage = nil
    }

    func selectRedactionRegion(id: String?) {
        selectedRedactionRegionID = id
        if let id,
           let region = redactionRegions.first(where: { $0.id == id }),
           let type = region.type,
           let result = detectedPII.first(where: { $0.type == type }) {
            selectedPIIResult = result
        } else {
            selectedPIIResult = nil
        }
    }

    func deleteSelectedRedactionRegion() {
        guard let id = selectedRedactionRegionID else { return }
        deleteRedactionRegion(id: id)
    }

    /// Deletes the region with the given ID without requiring it to be selected first.
    /// Used by the region list in `RedactionEditorDrawer` where each row has its own delete button.
    func deleteRedactionRegion(id: String) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        let region = redactionRegions[index]
        redactionRegions.remove(at: index)
        if selectedRedactionRegionID == id {
            selectedRedactionRegionID = nil
        }
        if let type = region.type,
           !redactionRegions.contains(where: { $0.type == type && $0.isEnabled }) {
            typesToRedact.remove(type)
        }
        redactedUIImage = nil
    }

    /// Toggles the enabled state of a specific redaction region.
    ///
    /// `isEnabled` is toggled directly on the individual region for both detected
    /// and custom sources, giving per-instance granularity. `typesToRedact` is **not**
    /// modified here — it remains the initial-seeding mechanism used when a PII scan
    /// completes. An undo snapshot is pushed so every toggle is reversible.
    func toggleRedactionRegion(id: String) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        redactionRegions[index].isEnabled.toggle()
        redactedUIImage = nil
    }

    /// Changes the visual style for a specific redaction region.
    /// The mutation is undoable and clears any cached redacted image.
    func changeRedactionStyle(id: String, style: RedactionStyle) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }) else { return }
        guard redactionRegions[index].style != style else { return }
        pushUndoSnapshot()
        redactionRegions[index].style = style
        redactedUIImage = nil
    }

    /// Changes the fill colour for a specific redaction region.
    /// Ignored if the region's current style does not support colour (`.pixelate`, `.blur`).
    /// The mutation is undoable and clears any cached redacted image.
    func changeRedactionColor(id: String, color: RedactionColor) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }) else { return }
        guard redactionRegions[index].color != color else { return }
        pushUndoSnapshot()
        redactionRegions[index].color = color
        redactedUIImage = nil
    }

    /// Covers only part of a finding — all but the last four digits, or the
    /// name before an email's "@" — or the whole of it again.  Switching resets
    /// the box to the one the scanner found.
    func setPartialCover(id: String, _ isPartial: Bool) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }),
              let cover = redactionRegions[index].partialCover,
              redactionRegions[index].isPartial != isPartial
        else { return }
        pushUndoSnapshot()
        redactionRegions[index].isPartial = isPartial
        redactionRegions[index].rect = isPartial ? cover.partial : cover.full
        redactedUIImage = nil
    }

    /// Changes the emoji an `.emoji` region is covered with — per region, so
    /// every face can have its own.  Undoable.
    func changeRedactionEmoji(id: String, emoji: String) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }),
              redactionRegions[index].emoji != emoji
        else { return }
        pushUndoSnapshot()
        redactionRegions[index].emoji = emoji
        redactedUIImage = nil
    }

    /// Gives every face the style — and, for `.emoji`, the emoji — of the face
    /// `id`, in one undoable step.
    func applyStyleToAllFaces(from id: String) {
        guard let source = redactionRegions.first(where: { $0.id == id }) else { return }
        let indices = redactionRegions.indices.filter {
            redactionRegions[$0].type == .face
                && (redactionRegions[$0].style != source.style || redactionRegions[$0].emoji != source.emoji)
        }
        guard !indices.isEmpty else { return }
        pushUndoSnapshot()
        for index in indices {
            redactionRegions[index].style = source.style
            redactionRegions[index].emoji = source.emoji
        }
        redactedUIImage = nil
    }

    /// Changes how hard a `.pixelate` / `.blur` region scrambles what is under it.
    /// The mutation is undoable and clears any cached redacted image.
    func changeRedactionStrength(id: String, strength: Double) {
        bulkChangeRedactionStrength(ids: [id], strength: strength)
    }

    // MARK: - Bulk Redaction Operations

    /// Applies `strength` to every region in `ids` whose style uses it.
    /// A single undo snapshot is pushed for the batch.
    func bulkChangeRedactionStrength(ids: Set<String>, strength: Double) {
        let strength = RedactionStrength.clamped(strength)
        let indicesToChange = redactionRegions.indices.filter {
            ids.contains(redactionRegions[$0].id)
                && redactionRegions[$0].style.supportsStrength
                && redactionRegions[$0].strength != strength
        }
        guard !indicesToChange.isEmpty else { return }
        pushUndoSnapshot()
        for index in indicesToChange {
            redactionRegions[index].strength = strength
        }
        redactedUIImage = nil
    }

    /// Applies `style` to every region whose ID is in `ids`.
    ///
    /// A single undo snapshot is pushed for the entire batch so the user can
    /// reverse the operation with one tap. Regions that already have the target
    /// style are skipped to avoid creating a redundant snapshot.
    func bulkChangeRedactionStyle(ids: Set<String>, style: RedactionStyle) {
        let indicesToChange = redactionRegions.indices.filter {
            ids.contains(redactionRegions[$0].id) && redactionRegions[$0].style != style
        }
        guard !indicesToChange.isEmpty else { return }
        pushUndoSnapshot()
        for index in indicesToChange {
            redactionRegions[index].style = style
        }
        redactedUIImage = nil
    }

    /// Applies `color` to every region whose ID is in `ids` and whose style supports colour.
    ///
    /// Regions whose style has no colour (`.pixelate`, `.blur`) are silently skipped.
    /// A single undo snapshot is pushed for the batch.
    func bulkChangeRedactionEmoji(ids: Set<String>, emoji: String) {
        let indices = redactionRegions.indices.filter {
            ids.contains(redactionRegions[$0].id) && redactionRegions[$0].emoji != emoji
        }
        guard !indices.isEmpty else { return }
        pushUndoSnapshot()
        for index in indices {
            redactionRegions[index].emoji = emoji
        }
        redactedUIImage = nil
    }

    func bulkChangeRedactionColor(ids: Set<String>, color: RedactionColor) {
        let indicesToChange = redactionRegions.indices.filter {
            ids.contains(redactionRegions[$0].id)
                && redactionRegions[$0].style.supportsColor
                && redactionRegions[$0].color != color
        }
        guard !indicesToChange.isEmpty else { return }
        pushUndoSnapshot()
        for index in indicesToChange {
            redactionRegions[index].color = color
        }
        redactedUIImage = nil
    }

    /// Deletes all regions whose IDs are in `ids`.
    ///
    /// A single undo snapshot is pushed for the batch.
    /// `typesToRedact` is cleaned up for any PII type that has no remaining
    /// enabled regions after the deletion.
    func bulkDeleteRedactionRegions(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let indicesToRemove = redactionRegions.indices.filter { ids.contains(redactionRegions[$0].id) }
        guard !indicesToRemove.isEmpty else { return }
        pushUndoSnapshot()
        let removedTypes = Set(indicesToRemove.compactMap { redactionRegions[$0].type })
        redactionRegions.removeAll { ids.contains($0.id) }
        if let id = selectedRedactionRegionID, ids.contains(id) {
            selectedRedactionRegionID = nil
        }
        for type in removedTypes where !redactionRegions.contains(where: { $0.type == type && $0.isEnabled }) {
            typesToRedact.remove(type)
        }
        redactedUIImage = nil
    }

    /// Toggles the `isEnabled` state of every region whose ID is in `ids`.
    ///
    /// **Policy:** if any region in the set is currently disabled, ALL are enabled
    /// (opt-in first). Only when all are already enabled are they all disabled.
    /// This matches the iOS multi-select convention used in Mail and Reminders.
    /// A single undo snapshot is pushed for the batch.
    func bulkToggleRedactionRegions(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let indices = redactionRegions.indices.filter { ids.contains(redactionRegions[$0].id) }
        guard !indices.isEmpty else { return }
        pushUndoSnapshot()
        // Enable all if any are disabled; otherwise disable all.
        let anyDisabled = indices.contains { !redactionRegions[$0].isEnabled }
        let newState = anyDisabled
        for index in indices {
            redactionRegions[index].isEnabled = newState
        }
        redactedUIImage = nil
    }

    func resetDetectedRedactionRegions() {
        replaceDetectedRedactionRegions(from: detectedPII)
        selectedRedactionRegionID = nil
        redactedUIImage = nil
    }

    private func replaceDetectedRedactionRegions(from results: [DetectionResult]) {
        let customRegions = redactionRegions.filter { $0.source == .custom }
        let detectedRegions = results.flatMap { result in
            result.instances.enumerated().map { index, instance in
                RedactionRegion.detected(
                    result: result,
                    instance: instance,
                    index: index,
                    isEnabled: typesToRedact.contains(result.type)
                )
            }
        }
        redactionRegions = detectedRegions + customRegions
        if let selectedRedactionRegionID,
           !redactionRegions.contains(where: { $0.id == selectedRedactionRegionID }) {
            self.selectedRedactionRegionID = nil
        }
        redactedUIImage = nil
    }

    private func syncDetectedRegionEnablement() {
        guard !redactionRegions.isEmpty else { return }
        for index in redactionRegions.indices where redactionRegions[index].source == .detected {
            if let type = redactionRegions[index].type {
                redactionRegions[index].isEnabled = typesToRedact.contains(type)
            }
        }
        redactedUIImage = nil
    }

    /// Recomputes `pendingStrippedMetadata` from cached source props without re-encoding.
    /// Called when only `stripConfig` changes and a full re-process would be redundant.
    private func refreshPendingMetadata() {
        pendingStrippedMetadata = ImageProcessor.catalogueStrippedMetadata(
            from: rawSourceProps?.dictionary,
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
        let imageToken = loadToken
        let token = UUID()
        reviewToken = token
        processingToken = UUID()
        isProcessing = true

        await waitForCurrentPIIScan()
        guard imageToken == loadToken, reviewToken == token, !Task.isCancelled else { return }

        // Redaction path: burn only the instances whose type is in typesToRedact.
        let regionsToRedact = enabledRedactionRegions
        let redactionKey = RedactionKey(image: imageToken, specs: regionsToRedact.map(\.spec))
        let exportKey = ExportKey(redaction: redactionKey, preset: selectedPreset, config: stripConfig)

        // Nothing has changed since the last encode: show those bytes again.
        if processedData != nil, processedKey == exportKey {
            isProcessing = false
            if presentSheet { activeSheet = .preSave }
            return
        }
        processedKey = nil

        let stored: Bool
        if !regionsToRedact.isEmpty, let raw = rawImageData {
            let burned: UIImage?
            if let cached = reviewRedaction, cached.key == redactionKey {
                burned = cached.image
            } else {
                // Never hold two full-size renders at once.
                reviewRedaction = nil
                let uiImage = await Task.detached(priority: .userInitiated) {
                    ImageProcessor.orientedImage(from: raw)
                }.value
                guard imageToken == loadToken, reviewToken == token, !Task.isCancelled else { return }
                burned = if let uiImage {
                    await ImageRedactor().redact(image: uiImage, specs: redactionKey.specs)
                } else {
                    nil
                }
            }

            guard let burned else {
                guard imageToken == loadToken, reviewToken == token else { return }
                errorMessage = String(localized: "Could not render redactions for this image.")
                processedData = nil
                processedPreviewUIImage = nil
                isProcessing = false
                return
            }

            guard imageToken == loadToken, reviewToken == token, !Task.isCancelled else { return }
            // Kept while the review is open (see `activeSheet`), so that a
            // format change there only encodes again.
            reviewRedaction = ReviewRedaction(key: redactionKey, image: burned)
            stored = await processImage(
                raw: raw,
                sourceData: raw,
                imageOverride: burned,
                plan: ExportPlan(preset: exportKey.preset, metadata: exportKey.config),
                updateSourceMetadata: false
            )
            // The processed bytes now include redactions; the review shows only
            // the downsampled processed preview, never the full-size render.
            redactedUIImage = nil
        } else {
            reviewRedaction = nil
            redactedUIImage = nil
            stored = await processCurrentImageNow(plan: ExportPlan(preset: exportKey.preset, metadata: exportKey.config))
        }

        guard imageToken == loadToken, reviewToken == token, !Task.isCancelled else { return }
        if stored { processedKey = exportKey }
        if presentSheet, processedData != nil {
            activeSheet = .preSave
        }
        if activeSheet != .preSave { reviewRedaction = nil }
    }

    /// Processes `override` data (or `rawImageData` when nil) through the EXIF
    /// stripping pipeline, updating `processedData` and related state.
    ///
    /// `rawSourceProps` and `allSourceMetadata` are derived from the *original*
    /// image only — they must never be overwritten by intermediate redacted data,
    /// which carries ghost iOS-injected TIFF/EXIF fields.
    ///
    /// Returns `true` when the encode's result was stored — `false` when it
    /// failed or a newer one superseded it.
    private func processImage(
        raw: Data,
        sourceData: Data,
        imageOverride: UIImage?,
        plan: ExportPlan,
        updateSourceMetadata: Bool
    ) async -> Bool {
        let token = UUID()
        processingToken = token
        errorMessage = scanFailureMessage
        isProcessing = true

        do {
            let snapshot = try await Self.makeProcessingSnapshot(ProcessingRequest(
                raw: raw,
                sourceData: sourceData,
                imageOverride: imageOverride,
                preset: plan.preset,
                config: plan.metadata,
                updateSourceMetadata: updateSourceMetadata
            ))
            guard processingToken == token else { return false }

            processedData           = snapshot.processed.data
            processedPreviewUIImage = snapshot.processedPreviewUIImage
            sourceUTType            = snapshot.processed.sourceType
            pendingStrippedMetadata = snapshot.processed.stripped
            outputFileFields        = snapshot.outputFileFields

            if updateSourceMetadata {
                rawSourceProps = snapshot.rawSourceProps
                allSourceMetadata = snapshot.allSourceMetadata
            }
            isProcessing = false
            return true
        } catch {
            guard processingToken == token else { return false }
            processedData           = nil
            processedPreviewUIImage = nil
            pendingStrippedMetadata = nil
            errorMessage            = error.localizedDescription
            isProcessing            = false
            return false
        }
    }

    /// Reads the source's properties and catalogues them off the main actor.
    @concurrent
    nonisolated private static func makeSourceCatalog(from data: Data, config: StripConfig) async -> SourceCatalog {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return SourceCatalog(
                props: nil,
                stripped: StrippedMetadata(fields: []),
                all: StrippedMetadata(fields: []),
                utType: nil
            )
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let utType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        return SourceCatalog(
            props: SourceProperties(props),
            stripped: ImageProcessor.catalogueStrippedMetadata(from: props, config: config),
            all: ImageProcessor.catalogueStrippedMetadata(from: props, config: .allEnabled),
            utType: utType
        )
    }

    /// Runs the full encode plus the output read-back off the main actor.
    @concurrent
    nonisolated private static func makeProcessingSnapshot(
        _ request: ProcessingRequest
    ) async throws -> ProcessingSnapshot {
        let verified = try ExportPipeline.encode(
            request.sourceData, imageOverride: request.imageOverride,
            plan: ExportPlan(preset: request.preset, metadata: request.config)
        )
        let result = verified.processed
        let outputFileFields = verified.outputFields
        let processedPreview = ImageProcessor.downsampledUIImage(
            from: result.data,
            maxPixelDimension: 1_600
        )

        let rawSourceProps: SourceProperties?
        let allSourceMetadata: StrippedMetadata?
        if request.updateSourceMetadata {
            rawSourceProps = SourceProperties(imageData: request.sourceData)
            allSourceMetadata = ImageProcessor.catalogueStrippedMetadata(
                from: rawSourceProps?.dictionary,
                config: .allEnabled
            )
        } else {
            rawSourceProps = nil
            allSourceMetadata = nil
        }

        return ProcessingSnapshot(
            processed: result,
            outputFileFields: outputFileFields,
            processedPreviewUIImage: processedPreview,
            rawSourceProps: rawSourceProps,
            allSourceMetadata: allSourceMetadata
        )
    }

    /// Saves the processed image to the photo library.
    ///
    /// - Parameter replacing: When `true`, also deletes the original asset.
    func saveToPhotos(replacing: Bool) async {
        guard canExport, let data = processedData else { return }

        let token = loadToken
        let requiredLevel: PHAccessLevel = replacing ? .readWrite : .addOnly
        let status = await PHPhotoLibrary.requestAuthorization(for: requiredLevel)
        guard loadToken == token, !Task.isCancelled else { return }
        guard status == .authorized || status == .limited else {
            errorMessage = String(localized: "Photo library access was denied. Please enable it in Settings.")
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

        if keepsLivePhotoMotion, canKeepLivePhotoMotion, let item = livePhotoItem {
            do {
                try await saveLivePhoto(still: data, item: item)
                savedConfirmation = SavedConfirmation(summary: sharingSummary, replacedOriginal: false)
                activeSheet = nil
                return
            } catch {
                // The still is still worth saving; say that the motion was not kept.
                errorMessage = String(localized: "The motion could not be kept, so the photo was saved as a still.")
            }
        }

        do {
            try await PhotoLibraryWriter.save(data)
            savedConfirmation = SavedConfirmation(summary: sharingSummary, replacedOriginal: false)
            activeSheet = nil
        } catch {
            errorMessage = String(localized: "Could not save to Photos: \(error.localizedDescription)")
        }
    }

    /// Saves `still` with the Live Photo's paired video, cleaned, as a Live Photo.
    private func saveLivePhoto(still: Data, item: PhotosPickerItem) async throws {
        guard let livePhoto = try await item.loadTransferable(type: PHLivePhoto.self) else {
            throw VideoCleaner.Failure.cannotExport
        }
        let video = try await LivePhotoCleaner.cleanPairedVideo(of: livePhoto)
        defer { PrivateFileStore.exports.remove(video.url) }
        guard let pairedStill = LivePhotoCleaner.pairedStill(still, identifier: video.identifier) else {
            throw VideoCleaner.Failure.cannotExport
        }
        try await PhotoLibraryWriter.saveLivePhoto(photo: pairedStill, pairedVideo: video.url)
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
            try await PhotoLibraryWriter.save(data, deleting: asset)
            savedConfirmation = SavedConfirmation(summary: sharingSummary, replacedOriginal: true)
            activeSheet = nil
        } catch {
            errorMessage = String(localized: "Could not replace photo: \(error.localizedDescription)")
        }
    }

    /// `true` when `field` will be — or, once an encode has run, actually was —
    /// left out of the exported file.
    ///
    /// Before an encode this is a prediction from `stripConfig`.  Afterwards the
    /// output bytes are the authority: ImageIO cannot write every field back
    /// (TIFF DateTime, Software, and Artist have no writable mapping, for
    /// example), so a field the user asked to keep that did not survive is
    /// reported as removed instead of being silently claimed as kept.
    func isRemoved(_ field: MetadataField) -> Bool {
        guard !field.isStructural else { return false }
        if ImageProcessor.shouldReportStripped(
            category: field.category,
            key: field.key,
            isStructural: field.isStructural,
            config: stripConfig
        ) {
            return true
        }
        guard processedData != nil else { return false }
        return !outputFieldKeys.contains("\(field.category).\(field.key)")
    }

    // MARK: - Helpers

    /// Builds an `AuditReport` from current scan state, encodes it as pretty-printed
    /// JSON, writes it to a uniquely-named temp file, and returns the URL.
    /// Returns `nil` if encoding or writing fails.
    func generateAuditJSON() -> URL? {
        // 1. Visual redactions — only types the user has opted to redact.
        let groupedRegions = Dictionary(grouping: enabledRedactionRegions, by: \.displayName)
        let visualRedactions: [RedactionReport] = groupedRegions
            .map { RedactionReport(type: $0.key, instanceCount: $0.value.count) }
            .sorted { $0.type < $1.type }

        // 2. Metadata stripped — non-structural fields grouped by category,
        //    respecting the current strip config (disabled categories are excluded).
        let metadataStripped: [MetadataCategoryReport] = {
            guard let source = allSourceMetadata else { return [] }
            var grouped: [String: [String]] = [:]
            for field in source.fields where isRemoved(field) {
                grouped[field.category, default: []].append(field.key)
            }
            return grouped
                .map { MetadataCategoryReport(category: $0.key, strippedFields: $0.value.sorted()) }
                .sorted { $0.category < $1.category }
        }()

        // 3. Encode.
        let report = AuditReport(
            scanDate: Date(),
            formatSelected: selectedExportFormat.title,
            visualRedactions: visualRedactions,
            metadataStripped: metadataStripped,
            scanCoverage: scanCoverage,
            findingsLeftVisible: findingsLeftVisible,
            manualReviewAcknowledged: manualReviewAcknowledged
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting  = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(report) else { return nil }

        // 4. Write to temp file.
        return try? PrivateFileStore.exports.write(data, extension: "json")
    }

    // MARK: - Batch processing

    /// Processes every item in `batchItems` using the supplied config, in order.
    ///
    /// **Memory safety:** Images are cleaned one-at-a-time.  Each photo's decoded
    /// bitmap and intermediate buffers live only inside `processBatchItem`, so ARC
    /// reclaims them before the next image is decoded.  Concurrent `TaskGroup`
    /// execution is intentionally avoided — parallel Vision / CoreGraphics workers
    /// spike RAM and cause OOM crashes on device.  Only loading the next photo's
    /// bytes and saving the previous one's overlap the cleaning (`runBatch`).
    func processBatch(config: BatchConfig) async {
        let config = effectiveBatchConfig(config)

        isBatchProcessing = true
        batchProgress     = (0, batchCount)
        batchReports      = []
        batchFailedCount  = 0
        batchErrorMessage = nil

        // Request photo library authorization once before entering the loop.
        // Replace mode needs readWrite; save-as-new only needs addOnly.
        let requiredLevel: PHAccessLevel = config.saveMode == .replaceOriginal ? .readWrite : .addOnly
        let status = await PHPhotoLibrary.requestAuthorization(for: requiredLevel)
        guard status == .authorized || status == .limited else {
            batchErrorMessage = String(localized: "Photo library access was denied. Please enable it in Settings.")
            isBatchProcessing = false
            return
        }

        // Capture the lists once; the batch must not be mutated during the loop.
        // Photos first — they are quick — then the videos.
        let photos = currentBatchSources()
        let videos = currentVideoBatchSources()
        let total = photos.count + videos.count
        if !photos.isEmpty {
            await runBatch(sources: photos, config: config, save: Self.saveBatchItemToPhotos, total: total, finishes: videos.isEmpty)
        }
        // A batch stopped during its photos is already finished.
        guard !videos.isEmpty, !batchComplete else { return }
        await runVideoBatch(
            sources: videos, config: config, offset: photos.count, total: total,
            save: Self.saveBatchVideoToPhotos
        ) { url, covering, terms, progress in
            try await VideoBatchCleaner.clean(url, covering: covering, alwaysCover: terms, progress: progress)
        }
    }

    /// The videos of the batch, each copied into the protected store when its turn comes.
    func currentVideoBatchSources() -> [VideoBatchSource] {
        batchVideoItems.map { item in
            VideoBatchSource(assetIdentifier: item.itemIdentifier) {
                try? await item.loadTransferable(type: IncomingVideo.self)?.url
            }
        } + fileBatchVideos.map { url in
            VideoBatchSource(assetIdentifier: nil) {
                try? PrivateFileStore.exports.copy(url, extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
            }
        }
    }

    /// Opens files — photos and videos alike — as one batch, for the UI tests,
    /// which cannot drive the system picker (`PICSTRIP_BATCH_FIXTURE`).  Files
    /// have no library original to replace, so, like captured pages, they are
    /// saved as new.
    func openFileBatch(_ urls: [URL]) {
        let isVideo: (URL) -> Bool = { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
        batchItems = []
        batchVideoItems = []
        scannedBatchSources = urls.filter { !isVideo($0) }.map { url in
            BatchSource(assetIdentifier: nil) { try? Data(contentsOf: url) }
        }
        fileBatchVideos = urls.filter(isVideo)
        activeSheet = .batch
    }

    /// The config a batch actually runs with.  Captured pages have no library
    /// original, so replace mode is never honoured for them — whatever the UI sent.
    func effectiveBatchConfig(_ config: BatchConfig) -> BatchConfig {
        guard !batchAllowsReplaceOriginal else { return config }
        var config = config
        config.saveMode = .saveAsNew
        return config
    }

    /// What the batch sheet is about to process: captured pages when there are
    /// any, otherwise the picker selection.
    func currentBatchSources() -> [BatchSource] {
        guard scannedBatchSources.isEmpty else { return scannedBatchSources }
        return batchItems.map { item in
            BatchSource(assetIdentifier: item.itemIdentifier) {
                try? await item.loadTransferable(type: IncomingImage.self)?.data
            }
        }
    }

    /// The batch loop proper, separated from `PhotosPickerItem` and
    /// `PHPhotoLibrary` so unit tests can drive it with in-memory sources.
    ///
    /// **Fail closed:** a photo is only written when every step the user asked
    /// for succeeded.  If stripping or redaction fails, the photo is counted as
    /// failed and nothing is saved — silently saving the untouched original as a
    /// "cleaned" copy would defeat the purpose of the app.
    func cancelBatch() {
        batchCancellationRequested = true
        batchVideoTask?.cancel()
    }

    /// `total` counts the videos to come after these photos; `finishes` is
    /// `false` when they follow, so the batch is not over yet.
    func runBatch(
        sources: [BatchSource], config: BatchConfig, save: BatchSaver,
        total: Int? = nil, finishes: Bool = true
    ) async {
        let total = total ?? sources.count
        batchCancellationRequested = false
        isBatchProcessing = true
        batchProgress     = (0, total)
        batchReports      = []
        batchFailedCount  = 0
        batchErrorMessage = nil
        batchOriginalsNotFound = 0

        let preset = config.outputFormat.exportPreset
        let formatTitle = config.outputFormat.title
        // Always Cover applies to batches as well: the matches join each photo's findings.
        let terms = alwaysCoverList.terms
        let scanWithAlwaysCover: @Sendable (Data, ScanHints, ScanProgressHandler?) async throws -> ScanOutput = { [scan] data, hints, progress in
            let output = try await scan(data, hints, progress)
            let covered = AlwaysCoverMatcher.results(terms: terms, lines: output.lines)
            guard !covered.isEmpty else { return output }
            return ScanOutput(results: PIIScanner.sorted(output.results + covered), lines: output.lines, coverage: output.coverage)
        }

        let plan = ExportPlan(preset: preset, metadata: config.stripMetadata ? .allEnabled : StripConfig(categoryEnabled: [:], fieldOverrides: [:]))
        let redactVisualPII = config.redactVisualPII

        // Loading a photo (perhaps from iCloud) and saving one are mostly
        // waiting, so they overlap the cleaning: photo N+1's bytes load while N
        // is cleaned, and N+1 is cleaned while N saves.  Still only one photo is
        // cleaned — decoded — at a time, and the saves happen one after another,
        // in order.
        func fetch(_ index: Int) -> Task<Data?, Never>? {
            guard sources.indices.contains(index) else { return nil }
            return Task { [loadBytes = sources[index].load] in await loadBytes() }
        }
        func clean(_ index: Int, bytes: Task<Data?, Never>?) -> Task<BatchItemOutput?, Never> {
            Task { [hints = sources[index].hints] in
                // Scan + redact + strip run off the main actor; only the
                // resulting bytes and report rows come back.
                guard let sourceData = await bytes?.value else { return nil }
                return await Self.processBatchItem(
                    sourceData: sourceData, hints: hints, plan: plan,
                    redactVisualPII: redactVisualPII, scan: scanWithAlwaysCover
                )
            }
        }
        var cleaning = sources.isEmpty ? nil : clean(0, bytes: fetch(0))
        var nextBytes = fetch(1)

        for (index, source) in sources.enumerated() {
            if batchCancellationRequested || Task.isCancelled { break }
            batchProgress = (index + 1, total)

            guard let current = cleaning else { break }
            let output = await current.value
            cleaning = nil
            // The next photo is cleaned while this one saves, and the one after
            // it loads.
            if !(batchCancellationRequested || Task.isCancelled), sources.indices.contains(index + 1) {
                cleaning = clean(index + 1, bytes: nextBytes)
                nextBytes = fetch(index + 2)
            }
            guard let output else {
                batchFailedCount += 1
                continue
            }

            if batchCancellationRequested || Task.isCancelled { break }
            switch await save(output.data, source.assetIdentifier, config.saveMode) {
            case .failed:
                batchFailedCount += 1
                continue
            case .savedCopyOriginalMissing:
                batchOriginalsNotFound += 1
            case .saved:
                break
            }

            // Only photos the library accepted appear in the audit log.
            batchReports.append(AuditReport(
                scanDate: Date(),
                formatSelected: formatTitle,
                visualRedactions: output.visualRedactions,
                metadataStripped: output.metadataStripped,
                scanCoverage: output.coverage
            ))
        }

        // Stopped: drop what was fetched ahead, and let the photo being cleaned
        // notice before the batch is over, so its bitmap is gone too.
        nextBytes?.cancel()
        if let cleaning {
            cleaning.cancel()
            _ = await cleaning.value
        }

        if finishes || batchCancellationRequested || Task.isCancelled { finishBatch() }
    }

    /// Cleans the batch's videos one at a time, after its photos (`offset`
    /// of `total`), with no review: faces blurred and text covered when
    /// "Redact Sensitive Visual Data" is on, and the hidden details always gone.
    /// Fails closed like the photos: a video is saved only when it was cleaned.
    func runVideoBatch(
        sources: [VideoBatchSource], config: BatchConfig, offset: Int = 0, total: Int? = nil,
        save: VideoBatchSaver, clean: @escaping VideoBatchCleaning
    ) async {
        let total = total ?? sources.count
        if offset == 0 {
            batchCancellationRequested = false
            batchReports = []
            batchFailedCount = 0
            batchErrorMessage = nil
            batchOriginalsNotFound = 0
        }
        isBatchProcessing = true
        let terms = alwaysCoverList.terms
        let covering = config.redactVisualPII

        for (index, source) in sources.enumerated() {
            if batchCancellationRequested || Task.isCancelled { break }
            batchProgress = (offset + index + 1, total)
            batchVideoFraction = 0

            guard let url = await source.load() else {
                batchFailedCount += 1
                continue
            }
            let task = Task { [weak self] in
                try await clean(url, covering, terms) { fraction in
                    Task { @MainActor in self?.batchVideoFraction = fraction }
                }
            }
            batchVideoTask = task
            let cleaned = try? await task.value
            batchVideoTask = nil
            PrivateFileStore.exports.remove(url)
            guard let cleaned else {
                if !batchCancellationRequested { batchFailedCount += 1 }
                continue
            }
            defer { PrivateFileStore.exports.remove(cleaned.url) }
            if batchCancellationRequested || Task.isCancelled { break }

            switch await save(cleaned.url, source.assetIdentifier, config.saveMode) {
            case .failed:
                batchFailedCount += 1
                continue
            case .savedCopyOriginalMissing:
                batchOriginalsNotFound += 1
            case .saved:
                break
            }
            batchReports.append(cleaned.report)
        }
        batchVideoFraction = nil
        finishBatch(hasVideos: true)
    }

    /// The batch is over: say how it went.
    private func finishBatch(hasVideos: Bool = false) {
        if batchCancellationRequested || Task.isCancelled {
            batchErrorMessage = String(localized: "Batch stopped. Copies already saved remain in Photos.")
        } else if batchFailedCount > 0 {
            batchErrorMessage = hasVideos
                ? String(localized: "Some photos or videos could not be cleaned and were not saved.")
                : String(localized: "Some photos could not be cleaned and were not saved.")
        } else if batchOriginalsNotFound > 0 {
            batchErrorMessage = String(localized: "Some originals could not be identified, so cleaned copies were saved instead.")
        }
        batchVideoFraction = nil
        isBatchProcessing = false
        batchComplete     = true
    }

    /// Scans, redacts, and strips one photo entirely off the main actor.
    ///
    /// Returns `nil` when any requested step fails so the caller can fail closed.
    @concurrent
    nonisolated private static func processBatchItem(
        sourceData: Data,
        hints: ScanHints,
        plan: ExportPlan,
        redactVisualPII: Bool,
        scan: @Sendable (Data, ScanHints, ScanProgressHandler?) async throws -> ScanOutput
    ) async -> BatchItemOutput? {
        guard let result = try? await ExportPipeline.clean(
            sourceData, plan: plan,
            redact: redactVisualPII, hints: hints, scan: scan
        ) else { return nil }
        return BatchItemOutput(
            data: result.export.processed.data,
            visualRedactions: result.redactions,
            metadataStripped: result.export.metadataRemoved,
            coverage: result.coverage
        )
    }

    /// Writes one cleaned photo to the library, deleting the original in replace mode.
    private static func saveBatchItemToPhotos(
        data: Data,
        assetIdentifier: String?,
        mode: BatchSaveMode
    ) async -> BatchSaveResult {
        var originalMissing = false
        var original: PHAsset?
        if mode == .replaceOriginal {
            original = assetIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            // Original not found (e.g. not yet downloaded from iCloud): fall
            // back to saving a cleaned copy and tell the user afterwards.
            originalMissing = original == nil
        }

        do {
            try await PhotoLibraryWriter.save(data, deleting: original)
            return originalMissing ? .savedCopyOriginalMissing : .saved
        } catch {
            return .failed
        }
    }

    /// Writes one cleaned video to the library, deleting the original in replace mode.
    private static func saveBatchVideoToPhotos(
        url: URL,
        assetIdentifier: String?,
        mode: BatchSaveMode
    ) async -> BatchSaveResult {
        var original: PHAsset?
        if mode == .replaceOriginal {
            original = assetIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
        }
        do {
            try await PhotoLibraryWriter.saveVideo(at: url, deleting: original)
            return mode == .replaceOriginal && original == nil ? .savedCopyOriginalMissing : .saved
        } catch {
            return .failed
        }
    }

    /// Wraps all per-photo `AuditReport`s in a `BatchAuditReport`, encodes it as
    /// pretty-printed JSON, writes it to a temp file, and returns the URL.
    func generateBatchAuditJSON() -> URL? {
        let batch = BatchAuditReport(
            batchDate: Date(),
            photoCount: batchReports.count,
            failedCount: batchFailedCount,
            reports: batchReports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting     = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(batch) else { return nil }
        return try? PrivateFileStore.exports.write(data, extension: "json")
    }

    /// Resets all batch-related state and dismisses the batch sheet.
    func clearBatchState() {
        batchItems        = []
        batchVideoItems   = []
        fileBatchVideos   = []
        batchVideoFraction = nil
        scannedBatchSources = []
        isBatchProcessing = false
        batchProgress     = (0, 0)
        batchComplete     = false
        batchReports      = []
        batchFailedCount  = 0
        batchErrorMessage = nil
        activeSheet       = nil
    }

    func clearState() {
        isDemo = false
        discardLargeImage()
        nameScanTask?.cancel()
        nameScanTask = nil
        isFindingNames = false
        scanCoverage = ScanCoverage()
        scanFailureMessage = nil
        manualReviewAcknowledged = false
        loadTask?.cancel()
        loadTask                = nil
        loadToken               = UUID()
        processingToken         = UUID()
        reviewToken             = UUID()
        selectedItem            = nil
        rawImageData            = nil
        rawSourceProps          = nil
        inputImage              = nil
        sourceUIImage           = nil
        processedData           = nil
        processedKey            = nil
        processedPreviewUIImage = nil
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
        redactionRegions        = []
        selectedRedactionRegionID = nil
        redactedUIImage         = nil
        typesToRedact           = []
        stripConfig             = .default
        piiScanTask?.cancel()
        piiScanTask             = nil
        piiFocusTask?.cancel()
        piiFocusTask            = nil
        piiScanToken            = UUID()
        isScanningPII           = false
        clearUndoRedoStacks()
    }
}
