import SwiftUI
import UIKit

// MARK: - StripMetadataModel

@Observable
final class StripMetadataModel {
    enum Phase: Equatable {
        case working(done: Int, total: Int)
        case saved
        /// Something was not saved; stays on screen until the user closes it.
        case finished(saved: Int, failed: Int, reason: String?)
    }
    var phase: Phase = .working(done: 0, total: 1)
}

// MARK: - ActionViewController
//
// "Strip Metadata" in the share sheet's action list: no options and no review.
// Every shared photo and video is saved to Photos again without its hidden
// details — the metadata-only clean the share extension's Process & Save does
// with redaction off; a video's frames are copied as they are — then the sheet
// closes itself.  The originals are left as they were.
//
// Items are cleaned one at a time, so one decoded image is in memory at once.

final class ActionViewController: UIViewController {

    private let model = StripMetadataModel()
    private var task: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        embed(StripMetadataView(
            model: model,
            onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil) },
            onCancel: { [weak self] in self?.cancel() }
        ))
        let items = SharedItem.items(in: extensionContext)
        task = Task { [weak self] in await self?.save(items) }
    }

    private func save(_ items: [SharedItem]) async {
        guard !items.isEmpty else {
            model.phase = .finished(saved: 0, failed: 0, reason: String(localized: "No photos or videos found."))
            return
        }
        model.phase = .working(done: 0, total: items.count)
        guard await SharedItem.canSaveToPhotos() else {
            model.phase = .finished(saved: 0, failed: items.count, reason: String(localized: "Photos access is needed to save cleaned images. Grant access in Settings > Privacy > Photos."))
            return
        }

        var saved = 0
        var failed = 0
        var firstFailure: String?
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                try await item.saveCleanedCopy()
                saved += 1
            } catch {
                if Task.isCancelled { return }
                firstFailure = firstFailure ?? error.localizedDescription
                failed += 1
            }
            model.phase = .working(done: saved + failed, total: items.count)
        }

        guard failed == 0 else {
            model.phase = .finished(saved: saved, failed: failed, reason: firstFailure)
            return
        }
        model.phase = .saved
        // Long enough to read; the copies are already in Photos.
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled else { return }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        task?.cancel()
        extensionContext?.cancelRequest(withError: NSError(
            domain: "northcutt.PicStrip.StripMetadata",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "Cancelled by user")]
        ))
    }
}

// MARK: - StripMetadataView

private struct StripMetadataView: View {
    let model: StripMetadataModel
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            switch model.phase {
            case let .working(done, total):
                working(fraction: total > 1 ? Double(done) / Double(total) : nil)
            case .saved:
                saved
            case let .finished(saved, failed, reason):
                if saved == 0 {
                    ExtensionFailureView(
                        title: String(localized: "No photos or videos could be processed."),
                        message: reason,
                        onDone: onDone
                    )
                } else {
                    ExtensionFailureView(
                        title: String(localized: "Saved: \(saved). Not saved: \(failed)."),
                        message: reason,
                        onDone: onDone
                    )
                }
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .onChange(of: model.phase) { _, phase in
            if phase == .saved {
                AccessibilityNotification.Announcement(String(localized: "Saved to Photos")).post()
            }
        }
    }

    private func working(fraction: Double?) -> some View {
        VStack(spacing: 0) {
            ExtensionProgressView(message: String(localized: "Cleaning and saving to Photos…"), fraction: fraction)
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    private var saved: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Saved to Photos")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
