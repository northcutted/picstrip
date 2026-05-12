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
    var outputFormat: ExportFormat = .png
    /// Whether to save cleaned photos as new assets or overwrite the originals.
    var saveMode: BatchSaveMode = .saveAsNew
}

private struct ProcessingSnapshot {
    let processed: ProcessedImage
    let outputFileFields: [MetadataField]
    let processedPreviewUIImage: UIImage?
    let rawSourceProps: [CFString: Any]?
    let allSourceMetadata: StrippedMetadata?
}

private struct ProcessingRequest {
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

    /// The source `UIImage` retained so ContentView can use it in an
    /// `aspectRatio`-constrained overlay without re-decoding raw bytes.
    var sourceUIImage: UIImage?

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
    var outputFileFields: [MetadataField] = []

    /// The active export format chosen by the user.
    /// Changing this updates `selectedPreset` and re-triggers processing.
    var selectedExportFormat: ExportFormat = .png {
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
    /// Setting this property automatically rebuilds `redactionRegions` from
    /// the new results so that `redactionPreviewResults` and derived views
    /// stay in sync without requiring callers to call
    /// `replaceDetectedRedactionRegions` separately.
    var detectedPII: [DetectionResult] = [] {
        didSet { replaceDetectedRedactionRegions(from: detectedPII) }
    }

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

    /// Editable per-photo redaction boxes. Detected boxes are seeded from OCR;
    /// custom boxes are user-created and never persisted across photos.
    var redactionRegions: [RedactionRegion] = []

    /// Currently selected redaction box in the preview editor.
    var selectedRedactionRegionID: String?

    var selectedRedactionRegion: RedactionRegion? {
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

    private let piiScanner = PIIScanner()

    private var isClearing: Bool = false
    private var piiScanTask: Task<Void, Never>?
    private var piiScanToken = UUID()
    private var piiFocusTask: Task<Void, Never>?

    /// The unprocessed image bytes retained so preset / config changes can re-process
    /// without requiring the user to re-pick the image.
    private var rawImageData: Data?

    /// The raw source properties from ImageIO — used to rebuild pendingStrippedMetadata
    /// cheaply when only the config changes (without re-running the full encode pipeline).
    private var rawSourceProps: [CFString: Any]?

    /// Rejects stale processing completions when the user changes photo, preset,
    /// or redaction settings while an off-main encode is still running.
    private var processingToken = UUID()

    // MARK: - Item change handler

    private func handleItemChange() {
        guard !isClearing else { return }
        guard let item = selectedItem else { return }
        Task { await loadAndProcess(item: item) }
    }

    // MARK: - Async load pipeline

    /// Loads image bytes directly — bypasses `PhotosPickerItem`.
    ///
    /// Used by UITest fixture injection: the test writes a known PNG to `/tmp`,
    /// sets `PICSTRIP_FIXTURE` in `launchEnvironment`, and the app calls this on
    /// startup so the review screen is reachable without automating the Photos picker.
    func loadData(_ data: Data) async {
        isProcessing = true
        errorMessage = nil
        processedData = nil
        processedPreviewUIImage = nil
        inputImage = nil
        sourceUIImage = nil
        pendingStrippedMetadata = nil
        sourceUTType = nil
        rawSourceProps = nil
        piiScanTask?.cancel()
        piiScanTask = nil
        piiFocusTask?.cancel()
        piiFocusTask = nil
        piiScanToken = UUID()
        isScanningPII = false
        detectedPII = []
        imageSize = .zero
        activeSheet = nil
        selectedPIIResult = nil
        redactionRegions = []
        selectedRedactionRegionID = nil
        redactedUIImage = nil
        typesToRedact = []
        clearUndoRedoStacks()

        rawImageData = data

        if let uiImage = await Self.makePreviewImage(from: data) {
            inputImage = Image(uiImage: uiImage)
            sourceUIImage = uiImage
            imageSize = uiImage.size
        }

        startPIIScan(data: data)
        await processCurrentImageNow()
    }

    private func loadAndProcess(item: PhotosPickerItem) async {
        isProcessing = true
        errorMessage = nil
        processedData = nil
        processedPreviewUIImage = nil
        inputImage = nil
        sourceUIImage = nil
        pendingStrippedMetadata = nil
        sourceUTType = nil
        rawSourceProps = nil
        piiScanTask?.cancel()
        piiScanTask = nil
        piiFocusTask?.cancel()
        piiFocusTask = nil
        piiScanToken = UUID()
        isScanningPII     = false
        detectedPII       = []
        imageSize         = .zero
        activeSheet       = nil
        selectedPIIResult = nil
        redactionRegions  = []
        selectedRedactionRegionID = nil
        redactedUIImage   = nil
        typesToRedact     = []
        clearUndoRedoStacks()

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = String(localized: "The selected item could not be loaded as image data.")
                isProcessing = false
                return
            }

            rawImageData = data

            if let uiImage = await Self.makePreviewImage(from: data) {
                inputImage    = Image(uiImage: uiImage)
                sourceUIImage = uiImage
                // Store point dimensions (not pixel dimensions).
                // ContentView's .scaledToFit() math operates in SwiftUI points,
                // so we match that coordinate space here.
                imageSize = uiImage.size
            }

            startPIIScan(data: data)

            await processCurrentImageNow()
        } catch {
            errorMessage = error.localizedDescription
            rawImageData = nil
            isProcessing = false
        }
    }

    // MARK: - Processing

    func processCurrentImage() {
        guard rawImageData != nil else { return }
        Task { await processCurrentImageNow() }
    }

    private func processCurrentImageNow() async {
        guard let raw = rawImageData else {
            isProcessing = false
            return
        }
        await processImage(
            raw: raw,
            sourceData: raw,
            imageOverride: nil,
            updateSourceMetadata: true
        )
    }

    private static func makePreviewImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            ImageProcessor.downsampledUIImage(from: data)
        }.value
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
                // `detectedPII.didSet` already called replaceDetectedRedactionRegions;
                // syncDetectedRegionEnablement (via typesToRedact.didSet) then enables
                // each region whose type is in typesToRedact.
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

    func addCustomRedaction(rect: CGRect) {
        pushUndoSnapshot()
        let region = RedactionRegion.custom(rect: rect)
        redactionRegions.append(region)
        selectedRedactionRegionID = region.id
        redactedUIImage = nil
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
    /// Ignored if the region's current style does not support colour (e.g. `.pixelate`).
    /// The mutation is undoable and clears any cached redacted image.
    func changeRedactionColor(id: String, color: RedactionColor) {
        guard let index = redactionRegions.firstIndex(where: { $0.id == id }) else { return }
        guard redactionRegions[index].color != color else { return }
        pushUndoSnapshot()
        redactionRegions[index].color = color
        redactedUIImage = nil
    }

    // MARK: - Bulk Redaction Operations

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
    /// Regions using `.pixelate` are silently skipped.
    /// A single undo snapshot is pushed for the batch.
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

        await waitForCurrentPIIScan()

        // Redaction path: burn only the instances whose type is in typesToRedact.
        let regionsToRedact = enabledRedactionRegions

        if !regionsToRedact.isEmpty, let raw = rawImageData {
            let uiImage = await Task.detached(priority: .userInitiated) {
                UIImage(data: raw)
            }.value

            guard let uiImage,
                  let burned = await ImageRedactor().redact(
                    image: uiImage,
                    specs: regionsToRedact.map(\.spec)
                  ) else {
                errorMessage = String(localized: "Could not render redactions for this image.")
                processedData = nil
                processedPreviewUIImage = nil
                isProcessing = false
                return
            }

            await processImage(
                raw: raw,
                sourceData: raw,
                imageOverride: burned,
                updateSourceMetadata: false
            )
            // The processed bytes now include redactions; keep only the
            // downsampled processed preview to avoid retaining a full-size bitmap.
            redactedUIImage = nil
        } else {
            redactedUIImage = nil
            await processCurrentImageNow()
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
    private func processImage(
        raw: Data,
        sourceData: Data,
        imageOverride: UIImage?,
        updateSourceMetadata: Bool
    ) async {
        let token = UUID()
        processingToken = token
        errorMessage = nil
        isProcessing = true

        let preset = selectedPreset
        let config = stripConfig

        do {
            let snapshot = try await Self.makeProcessingSnapshot(ProcessingRequest(
                raw: raw,
                sourceData: sourceData,
                imageOverride: imageOverride,
                preset: preset,
                config: config,
                updateSourceMetadata: updateSourceMetadata
            ))
            guard processingToken == token else { return }

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
        } catch {
            guard processingToken == token else { return }
            processedData           = nil
            processedPreviewUIImage = nil
            pendingStrippedMetadata = nil
            errorMessage            = error.localizedDescription
            isProcessing            = false
        }
    }

    private static func makeProcessingSnapshot(_ request: ProcessingRequest) async throws -> ProcessingSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let result: ProcessedImage
            if let imageOverride = request.imageOverride {
                result = try ImageProcessor.process(
                    image: imageOverride,
                    sourceData: request.sourceData,
                    preset: request.preset,
                    config: request.config
                )
            } else {
                result = try ImageProcessor.process(
                    data: request.raw,
                    preset: request.preset,
                    config: request.config
                )
            }

            let outputFileFields = ImageProcessor.readAllFields(from: result.data)
            let processedPreview = ImageProcessor.downsampledUIImage(
                from: result.data,
                maxPixelDimension: 1_600
            )

            let rawSourceProps: [CFString: Any]?
            let allSourceMetadata: StrippedMetadata?
            if request.updateSourceMetadata {
                if let source = CGImageSourceCreateWithData(request.sourceData as CFData, nil) {
                    rawSourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                } else {
                    rawSourceProps = nil
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
        }.value
    }

    /// Saves the processed image to the photo library.
    ///
    /// - Parameter replacing: When `true`, also deletes the original asset.
    func saveToPhotos(replacing: Bool) async {
        guard let data = processedData else { return }

        let requiredLevel: PHAccessLevel = replacing ? .readWrite : .addOnly
        let status = await PHPhotoLibrary.requestAuthorization(for: requiredLevel)
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

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            activeSheet = nil
        } catch {
            errorMessage = String(localized: "Could not save to Photos: \(error.localizedDescription)")
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
            activeSheet = nil
        } catch {
            errorMessage = String(localized: "Could not replace photo: \(error.localizedDescription)")
        }
    }

    /// Number of non-structural metadata fields that will be stripped given the current config.
    private var pendingFieldCount: Int {
        pendingMetadataFields.count
    }

    private var pendingMetadataFields: [MetadataField] {
        guard let source = allSourceMetadata else { return [] }
        return source.fields.filter {
            ImageProcessor.shouldReportStripped(
                category: $0.category,
                key: $0.key,
                isStructural: $0.isStructural,
                config: stripConfig
            )
        }
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
