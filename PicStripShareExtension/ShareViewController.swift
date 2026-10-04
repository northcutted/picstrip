import Photos
import SwiftUI
import UIKit

// MARK: - ExtensionViewModel

@Observable
@MainActor
final class ExtensionViewModel {
    enum Phase: Equatable { case configuring, processing, ready, finished }
    var phase: Phase = .configuring
    var errorMessage: String?
    var resultMessage = ""
    /// Human-readable description of the active processing operation.
    /// Set just before `phase` transitions to `.processing` so the spinner
    /// always reflects the actual destination (Photos vs. main app editor).
    var processingMessage: String = ""
}

// MARK: - ShareViewController
//
// Entry point for the Share / Action extension.
//
// Lifecycle:
//   1. iOS presents this view controller as a share sheet card.
//   2. We embed ExtensionConfigView — the photo toggles and two action buttons.
//   3. On "Process & Save" the pipeline saves a cleaned copy directly to Photos.
//      A video only has its hidden details removed, its frames copied as they
//      are: finding and covering faces in a video needs more memory and time
//      than an extension gets, so that is what Edit is for.
//   4. On "Edit in PicStrip" the pipeline writes the first original photo or
//      video to the shared app group container, shows a "Prepared" confirmation,
//      then dismisses.
//      iOS Share Extensions cannot programmatically switch apps (NSExtensionContext
//      .open() is not supported from Share Extensions), so the user opens PicStrip
//      manually. The main app's scenePhase observer drains the pending file on the
//      next foreground transition.
//
// Memory discipline: each image's UIImage and Data are released between
// iterations. Admission limits keep large photos out of the decode pipeline.
// Videos are only ever copied as files, never read into memory.

class ShareViewController: UIViewController {

    // MARK: - State

    private let viewModel = ExtensionViewModel()
    private var pendingHandoffURL: URL?
    private var processingTask: Task<Void, Never>?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        view.layer.cornerRadius = 20
        view.clipsToBounds = true
        PrivateFileStore.handoffs?.removeExpired()
        embedConfigView()
    }

    // MARK: - Embed SwiftUI config view

    private func embedConfigView() {
        let items = sharedItems()
        let configView = ExtensionConfigView(
            photoCount: items.count { !$0.kind.isVideo },
            videoCount: items.count { $0.kind.isVideo },
            firstIsVideo: items.first?.kind.isVideo == true,
            viewModel: viewModel,
            onProcess: { [weak self] stripMetadata, redactPII, reduceLargeImages in
                self?.runProcessingPipeline(stripMetadata: stripMetadata, redactPII: redactPII, reduceLargeImages: reduceLargeImages, destination: .photos)
            },
            onEdit: { [weak self] stripMetadata, redactPII in
                self?.runProcessingPipeline(stripMetadata: stripMetadata, redactPII: redactPII, destination: .mainApp)
            },
            onComplete: { [weak self] in
                // "Done" from the ready state: job succeeded, complete normally.
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            },
            onCancel: { [weak self] in
                self?.processingTask?.cancel()
                PrivateFileStore.handoffs?.remove(self?.pendingHandoffURL)
                self?.pendingHandoffURL = nil
                self?.extensionContext?.cancelRequest(withError: NSError(
                    domain: "northcutt.PicStrip.ShareExtension",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Cancelled by user")]
                ))
            }
        )

        let host = UIHostingController(rootView: configView)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    // MARK: - Input helpers

    /// The photos and videos shared, in order; anything else is left out.
    private func sharedItems() -> [(provider: NSItemProvider, kind: SharedItemKind)] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return [] }
        return items.flatMap { $0.attachments ?? [] }.compactMap { provider in
            SharedItemKind(registeredTypeIdentifiers: provider.registeredTypeIdentifiers).map { (provider, $0) }
        }
    }

    // MARK: - Destination

    private enum ProcessingDestination {
        /// Save cleaned copies to the Photos library.
        case photos
        /// Write the first photo or video to the app group container for the main app.
        case mainApp
    }

    // MARK: - Processing pipeline

    private func runProcessingPipeline(
        stripMetadata: Bool,
        redactPII: Bool,
        reduceLargeImages: Bool = false,
        destination: ProcessingDestination
    ) {
        guard extensionContext?.inputItems is [NSExtensionItem] else {
            showError(String(localized: "No input items found."))
            return
        }

        let items = sharedItems()
        guard !items.isEmpty else {
            showError(String(localized: "No photos or videos found."))
            return
        }

        // "Edit in PicStrip" only hands over the first item — the editor and the
        // video cleaner each open one at a time.
        let targetItems = destination == .mainApp ? Array(items.prefix(1)) : items

        viewModel.processingMessage = destination == .mainApp
            ? String(localized: "Preparing to open in PicStrip…")
            : String(localized: "Cleaning and saving to Photos…")
        viewModel.phase = .processing

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.process(
                targetItems,
                stripMetadata: stripMetadata,
                redactPII: redactPII,
                reduceLargeImages: reduceLargeImages,
                destination: destination
            )
        }
    }

    /// Runs on the main actor so the (non-Sendable) item providers never leave
    /// it; only each image's `Data` crosses to the background in `clean`, and
    /// each video's file URL.
    private func process(
        _ items: [(provider: NSItemProvider, kind: SharedItemKind)],
        stripMetadata: Bool,
        redactPII: Bool,
        reduceLargeImages: Bool,
        destination: ProcessingDestination
    ) async {
        // ── Request Photos authorization (save path only) ──────────────────
        if destination == .photos {
            let authStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authStatus == .authorized || authStatus == .limited else {
                showError(String(localized: "Photos access is needed to save cleaned images. Grant access in Settings > Privacy > Photos."))
                return
            }
        }

        var savedCount = 0
        var failedCount = 0
        var firstFailure: String?

        // Sequential on purpose: one decoded image at a time keeps the extension
        // within the conservative extension budget. Large images must open in the app.
        for (provider, kind) in items {

            // ── Videos: hidden details only, or handed over as a file ─────
            if case .video(let typeID) = kind {
                guard !Task.isCancelled else { return }
                do {
                    switch destination {
                    case .photos:
                        try await saveCleanedVideo(from: provider, typeIdentifier: typeID)
                    case .mainApp:
                        let handoff = try await handOffVideo(from: provider, typeIdentifier: typeID)
                        // Cancelled while the copy was made: leave nothing behind.
                        guard !Task.isCancelled else {
                            PrivateFileStore.handoffs?.remove(handoff)
                            return
                        }
                        pendingHandoffURL = handoff
                    }
                    savedCount += 1
                } catch {
                    if Task.isCancelled { return }
                    firstFailure = firstFailure ?? error.localizedDescription
                    failedCount += 1
                }
                continue
            }

            // ── Load the photo's raw Data in its best concrete type ───────
            // ── Scan, redact, strip — off the main actor ──────────────────
            // Fail closed: if a step the user asked for cannot run, skip the
            // image instead of saving the untouched original as "cleaned".
            guard case .photo(let typeID) = kind,
                  let rawData = await loadData(from: provider, typeIdentifier: typeID)
            else {
                failedCount += 1
                continue
            }

            guard !Task.isCancelled else { return }
            switch destination {
            case .photos:
                do {
                    let finalData = try await Self.clean(rawData, stripMetadata: stripMetadata,
                                                         redactPII: redactPII, reduceLargeImages: reduceLargeImages)
                    try Task.checkCancellation()
                    try await PhotoLibraryWriter.save(finalData)
                    savedCount += 1
                } catch {
                    if Task.isCancelled { return }
                    firstFailure = firstFailure ?? error.localizedDescription
                    failedCount += 1
                }

            case .mainApp:
                // ── Write to app group container ───────────────────────────
                guard let store = PrivateFileStore.handoffs else {
                    failedCount += 1
                    continue
                }
                do {
                    // Preserve original pixels for an editable review. This protected
                    // handoff expires after 15 minutes and is consumed on import.
                    pendingHandoffURL = try store.write(rawData, extension: "data")
                    savedCount += 1
                } catch {
                    failedCount += 1
                }
            }
        }

        if savedCount == 0 {
            showError(firstFailure ?? String(localized: "No photos or videos could be processed."))
        } else if failedCount > 0, destination == .photos {
            viewModel.resultMessage = String(localized: "Saved: \(savedCount). Not saved: \(failedCount).")
            viewModel.errorMessage = firstFailure
            viewModel.phase = .finished
        } else if destination == .mainApp {
            // Transition to the "ready" state so the user sees confirmation
            // that their item has been prepared before they dismiss and open
            // PicStrip manually.  iOS Share Extensions cannot programmatically
            // switch to another app — NSExtensionContext.open() is not supported
            // from Share Extensions — so we can only guide the user.
            viewModel.phase = .ready
        } else {
            // Completing with an empty array dismisses the extension
            // normally — Photos / the host app needs no return value
            // since we saved directly to the library.
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Cleaning (off the main actor)

    /// Scans, redacts, and strips one image.  Returns `nil` when a requested step
    /// fails or the result is not a decodable image.
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

    // MARK: - Videos

    /// "Process & Save" for a video: a copy without its hidden details — the
    /// frames copied as they are, checked before it is kept — saved to Photos.
    /// Both temporary files are deleted whatever happens.
    private func saveCleanedVideo(from provider: NSItemProvider, typeIdentifier: String) async throws {
        let store = PrivateFileStore.exports
        let original = try await copyVideo(from: provider, typeIdentifier: typeIdentifier, into: store)
        defer { store.remove(original) }
        let cleaned = try store.reserve(extension: "mov")
        defer { store.remove(cleaned) }
        try await VideoMetadataCleaner.clean(original, to: cleaned)
        try Task.checkCancellation()
        try await PhotoLibraryWriter.saveVideo(at: cleaned)
    }

    /// "Edit in PicStrip" for a video: the original, metadata and all, in the
    /// protected, expiring App Group handoff the app opens in its video cleaner.
    private func handOffVideo(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        guard let store = PrivateFileStore.handoffs else { throw CocoaError(.fileWriteUnknown) }
        return try await copyVideo(from: provider, typeIdentifier: typeIdentifier, into: store)
    }

    /// Copies the shared video into `store` as a file — never into memory —
    /// while the provider's temporary file exists: it is deleted when the
    /// callback returns.
    private func copyVideo(from provider: NSItemProvider, typeIdentifier: String, into store: PrivateFileStore) async throws -> URL {
        let fileExtension = SharedItemKind.videoFileExtension(for: typeIdentifier)
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? VideoMetadataCleaner.Failure.cannotExport)
                    return
                }
                continuation.resume(with: Result { try store.copy(url, extension: fileExtension) })
            }
        }
    }

    // MARK: - Load helper (continuation bridge)

    private func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        let fileData: Data? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                continuation.resume(returning: url.flatMap { try? ImageResourceBudget.shareExtension.read($0) })
            }
        }
        if let fileData { return fileData }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data.flatMap { $0.count <= ImageResourceBudget.shareExtension.maximumBytes ? $0 : nil })
            }
        }
    }

    /// Keep the failure visible so the user can choose manual editing or cancel.
    @MainActor
    private func showError(_ message: String) {
        viewModel.phase = .configuring
        viewModel.errorMessage = message
    }

}

// MARK: - ExtensionConfigView

private struct ExtensionConfigView: View {

    let photoCount: Int
    let videoCount: Int
    /// Edit hands over the first item, so its wording follows that one.
    let firstIsVideo: Bool
    let viewModel: ExtensionViewModel
    let onProcess: (Bool, Bool, Bool) -> Void
    let onEdit: (Bool, Bool) -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var stripMetadata: Bool = true
    @State private var redactPII: Bool = true
    @State private var reduceLargeImages = false

    private var isProcessing: Bool { viewModel.phase == .processing }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .accessibilityHidden(true)

            switch viewModel.phase {
            case .processing: processingBody
            case .ready:      readyBody
            case .configuring: ScrollView { configBody }
            case .finished:
                VStack(spacing: 16) {
                    Text(viewModel.resultMessage).font(.headline)
                    if let error = viewModel.errorMessage { Text(error).font(.footnote) }
                    Button("Done", action: onComplete).buttonStyle(.borderedProminent)
                }.padding(20)
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: viewModel.phase)
    }

    // MARK: - Config form

    private var configBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo.badge.shield.checkmark")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean with PicStrip")
                        .font(.headline)
                    selectionSummary
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            Divider()

            if photoCount > 0 {
                photoOptions
            }
            if videoCount > 0 {
                if photoCount > 0 { Divider().padding(.leading, 20) }
                videoNote
            }

            Divider()
                .padding(.bottom, 20)

            if let error = viewModel.errorMessage {
                Label {
                    Text(error).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }

            actionButtons
        }
    }

    /// "3 photos selected", or the photos and videos counted apart.
    private var selectionSummary: Text {
        if videoCount == 0 { return Text("^[\(photoCount) photo](inflect: true) selected") }
        if photoCount == 0 { return Text("Videos: \(videoCount)") }
        return Text("Photos: \(photoCount) · Videos: \(videoCount)")
    }

    /// The photo pipeline's switches; videos only ever have their metadata removed here.
    private var photoOptions: some View {
        VStack(spacing: 0) {
            Toggle("Strip Privacy Metadata", isOn: $stripMetadata)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityHint("Removes location, camera, editing, and other private image metadata.")

            Divider()
                .padding(.leading, 20)

            Toggle("Auto-Redact Sensitive Data", isOn: $redactPII)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityHint("Scans visible text and faces on device and burns redaction boxes over likely sensitive data.")
            Divider().padding(.leading, 20)
            Toggle("Allow smaller copies", isOn: $reduceLargeImages)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Text("Large photos need smaller copies in the extension: up to 6 megapixels for redaction, or 12 for metadata only. Edit in PicStrip for full review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
    }

    /// Covering faces in a video takes more memory and time than an extension
    /// gets, so say what happens here and where the rest is done.
    private var videoNote: some View {
        Label {
            Text("Videos have their metadata removed here. To cover faces and text, choose Edit in PicStrip.")
        } icon: {
            Image(systemName: "video")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                onProcess(stripMetadata, redactPII, reduceLargeImages)
            } label: {
                Label("Process & Save to Photos", systemImage: "checkmark.shield.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Cleans selected images on this device and saves new copies to Photos.")
            // The switches are for photos; a video always has its metadata removed.
            .disabled(photoCount > 0 && !stripMetadata && !redactPII)

            // "Edit in PicStrip" — the editor and the video cleaner each
            // open one item, so when several were shared only the first
            // is handed over.
            Button {
                onEdit(stripMetadata, redactPII)
            } label: {
                Label("Edit in PicStrip", systemImage: "pencil.and.scribble")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint(firstIsVideo
                ? Text("Opens the first selected video in PicStrip to cover faces and text.")
                : Text("Opens the first selected image in the PicStrip editor for manual redaction."))

            Group {
                if firstIsVideo {
                    Text("Edit opens the first video in PicStrip, where you can cover faces and text. A protected local copy expires after 15 minutes.")
                } else {
                    Text("Edit opens the first original image for review. A protected local copy expires after 15 minutes.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(role: .cancel) {
                onCancel()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Closes the PicStrip share extension without saving.")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
    }

    // MARK: - Ready state (mainApp destination)

    private var readyBody: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                (firstIsVideo ? Text("Video Prepared") : Text("Image Prepared"))
                    .font(.title2.weight(.semibold))
                Text("Open PicStrip within 15 minutes to review the original and choose what to cover.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .accessibilityHint(firstIsVideo
                ? Text("Closes the extension. Open PicStrip to edit your prepared video.")
                : Text("Closes the extension. Open PicStrip to edit your prepared image."))

            Button(role: .destructive, action: onCancel) {
                firstIsVideo ? Text("Discard prepared video") : Text("Discard prepared image")
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - Processing state

    private var processingBody: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            Text(viewModel.processingMessage)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.processingMessage)
    }
}
