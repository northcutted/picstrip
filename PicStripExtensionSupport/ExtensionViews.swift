import SwiftUI
import UIKit

// MARK: - Hosting

extension UIViewController {
    /// Fills the extension's view with a SwiftUI view.
    func embed(_ rootView: some View) {
        let host = UIHostingController(rootView: rootView)
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
}

// MARK: - ExtensionProgressView

/// A spinner, or a bar once there is more than one item, over what is being done.
struct ExtensionProgressView: View {
    let message: String
    /// Items done out of the total; `nil` for a single item.
    var fraction: Double?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if let fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
                    .scaleEffect(1.4)
            }
            Text(message)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

// MARK: - HandoffPreparedView

/// Shown when the notification that opens PicStrip cannot be posted — they are
/// turned off, or the request failed: the item is ready, and the user opens
/// PicStrip themselves within the handoff's 15 minutes.
struct HandoffPreparedView: View {
    let isVideo: Bool
    let onDone: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                (isVideo ? Text("Video Prepared") : Text("Image Prepared"))
                    .font(.title2.weight(.semibold))
                Text("Open PicStrip within 15 minutes to review the original and choose what to cover.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("With notifications on, one tap opens PicStrip next time. You can turn them on in Settings.",
                     comment: "Share sheet, after an item was prepared for editing while PicStrip notifications are off")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.center)

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .accessibilityHint(isVideo
                ? Text("Closes the extension. Open PicStrip to edit your prepared video.")
                : Text("Closes the extension. Open PicStrip to edit your prepared image."))

            Button(role: .destructive, action: onDiscard) {
                isVideo ? Text("Discard prepared video") : Text("Discard prepared image")
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

// MARK: - ExtensionFailureView

/// A failure that stays on screen until the user closes the sheet.
struct ExtensionFailureView: View {
    let title: String
    let message: String?
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button(action: onDone) {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}
