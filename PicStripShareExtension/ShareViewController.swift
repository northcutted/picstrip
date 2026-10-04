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
// Entry point for the Share extension, "Clean with PicStrip".  The two Action
// extensions, Strip Metadata and Edit in PicStrip, each do one of its jobs in a
// tap; this one keeps the options.
//
// Lifecycle:
//   1. iOS presents this view controller as a share sheet card.
//   2. We embed ExtensionConfigView — the photo toggles and two action buttons.
//   3. On "Process & Save" the pipeline saves a cleaned copy directly to Photos.
//      A video only has its hidden details removed, its frames copied as they
//      are: finding and covering faces in a video needs more memory and time
//      than an extension gets, so that is what Edit is for.
//   4. On "Edit in PicStrip" the first original photo or video is written to
//      the shared app group container and a notification is posted; tapping it
//      opens PicStrip, whose scenePhase observer drains the pending file.  An
//      extension has no supported way to open its app.  When notifications are
//      off, a "Prepared" screen asks the user to open PicStrip themselves.
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
        let items = SharedItem.items(in: extensionContext)
        embed(ExtensionConfigView(
            photoCount: items.count { !$0.isVideo },
            videoCount: items.count { $0.isVideo },
            firstIsVideo: items.first?.isVideo == true,
            viewModel: viewModel,
            onProcess: { [weak self] stripMetadata, redactPII, reduceLargeImages in
                self?.saveCleanedCopies(stripMetadata: stripMetadata, redactPII: redactPII, reduceLargeImages: reduceLargeImages)
            },
            onEdit: { [weak self] in
                self?.handOffFirstItem()
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
        ))
    }

    // MARK: - Process & Save

    private func saveCleanedCopies(stripMetadata: Bool, redactPII: Bool, reduceLargeImages: Bool) {
        let items = SharedItem.items(in: extensionContext)
        guard !items.isEmpty else {
            showError(String(localized: "No photos or videos found."))
            return
        }
        viewModel.processingMessage = String(localized: "Cleaning and saving to Photos…")
        viewModel.phase = .processing

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard await SharedItem.canSaveToPhotos() else {
                self?.showError(String(localized: "Photos access is needed to save cleaned images. Grant access in Settings > Privacy > Photos."))
                return
            }
            var savedCount = 0
            var failedCount = 0
            var firstFailure: String?
            // Sequential on purpose: one decoded image at a time keeps the extension
            // within the conservative extension budget. Large images must open in the app.
            for item in items {
                guard !Task.isCancelled else { return }
                do {
                    try await item.saveCleanedCopy(stripMetadata: stripMetadata, redactPII: redactPII, reduceLargeImages: reduceLargeImages)
                    savedCount += 1
                } catch {
                    if Task.isCancelled { return }
                    firstFailure = firstFailure ?? error.localizedDescription
                    failedCount += 1
                }
            }
            self?.finishSaving(saved: savedCount, failed: failedCount, firstFailure: firstFailure)
        }
    }

    private func finishSaving(saved: Int, failed: Int, firstFailure: String?) {
        if saved == 0 {
            showError(firstFailure ?? String(localized: "No photos or videos could be processed."))
        } else if failed > 0 {
            viewModel.resultMessage = String(localized: "Saved: \(saved). Not saved: \(failed).")
            viewModel.errorMessage = firstFailure
            viewModel.phase = .finished
        } else {
            // Completing with an empty array dismisses the extension
            // normally — Photos / the host app needs no return value
            // since we saved directly to the library.
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Edit in PicStrip

    /// Hands over the first item only — the editor and the video cleaner each
    /// open one at a time — then closes once the notification that opens
    /// PicStrip is posted.
    private func handOffFirstItem() {
        guard let item = SharedItem.items(in: extensionContext).first else {
            showError(String(localized: "No photos or videos found."))
            return
        }
        viewModel.processingMessage = String(localized: "Preparing to open in PicStrip…")
        viewModel.phase = .processing

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            do {
                let handoff = try await item.handOff()
                guard let self else { return }
                pendingHandoffURL = handoff.url
                if handoff.isAnnounced {
                    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                } else {
                    viewModel.phase = .ready
                }
            } catch {
                if Task.isCancelled { return }
                self?.showError(error.localizedDescription)
            }
        }
    }

    /// Keep the failure visible so the user can choose manual editing or cancel.
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
    let onEdit: () -> Void
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
            case .processing: ExtensionProgressView(message: viewModel.processingMessage)
            case .ready:      HandoffPreparedView(isVideo: firstIsVideo, onDone: onComplete, onDiscard: onCancel)
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
                onEdit()
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
}
