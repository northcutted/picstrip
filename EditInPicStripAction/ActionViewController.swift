import SwiftUI
import UIKit

// MARK: - EditInPicStripModel

@Observable
final class EditInPicStripModel {
    enum Phase: Equatable {
        case preparing
        /// Ready, but no notification could be posted to open PicStrip.
        case prepared
        case failed(String)
    }
    var phase: Phase = .preparing
    var isVideo = false
}

// MARK: - ActionViewController
//
// "Edit in PicStrip" in the share sheet's action list, offered for exactly one
// photo or video.  It writes the original to the protected, 15-minute App Group
// handoff — the same one the share extension's Edit uses — posts a notification
// and closes.  Tapping the notification opens PicStrip, which drains the
// handoff on activation: an extension has no supported way to open its app.
// When notifications are off, the sheet stays and asks the user to open
// PicStrip themselves.

final class ActionViewController: UIViewController {

    private let model = EditInPicStripModel()
    private var task: Task<Void, Never>?
    private var handoffURL: URL?
    private var isDiscarding = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        PrivateFileStore.handoffs?.removeExpired()
        let item = SharedItem.items(in: extensionContext).first
        model.isVideo = item?.isVideo == true
        embed(EditInPicStripView(
            model: model,
            onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil) },
            onDiscard: { [weak self] in self?.discard() }
        ))
        task = Task { [weak self] in await self?.handOff(item) }
    }

    private func handOff(_ item: SharedItem?) async {
        guard let item else {
            model.phase = .failed(String(localized: "No photos or videos found."))
            return
        }
        do {
            let handoff = try await item.handOff()
            handoffURL = handoff.url
            // Cancelled meanwhile: `discard` removes the file and ends the request.
            guard !Task.isCancelled else { return }
            if handoff.isAnnounced {
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                model.phase = .prepared
            }
        } catch {
            if Task.isCancelled { return }
            model.phase = .failed(error.localizedDescription)
        }
    }

    /// Cancel while preparing, or Discard once prepared: nothing is left behind.
    /// A copy in flight is waited for — it deletes itself once it sees the
    /// cancellation — so the extension is not ended with a file the app would
    /// still open.
    private func discard() {
        guard !isDiscarding else { return }
        isDiscarding = true
        task?.cancel()
        let running = task
        Task { [weak self] in
            await running?.value
            guard let self else { return }
            PrivateFileStore.handoffs?.remove(handoffURL)
            handoffURL = nil
            extensionContext?.cancelRequest(withError: NSError(
                domain: "northcutt.PicStrip.EditInPicStrip",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Cancelled by user")]
            ))
        }
    }
}

// MARK: - EditInPicStripView

private struct EditInPicStripView: View {
    let model: EditInPicStripModel
    let onDone: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .preparing:
                VStack(spacing: 0) {
                    ExtensionProgressView(message: String(localized: "Preparing to open in PicStrip…"))
                    Button(role: .cancel, action: onDiscard) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            case .prepared:
                HandoffPreparedView(isVideo: model.isVideo, onDone: onDone, onDiscard: onDiscard)
            case .failed(let message):
                ExtensionFailureView(title: message, message: nil, onDone: onDone)
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }
}
