import SwiftUI

/// Full-resolution output inspection. Revealing the original never changes the export.
struct ReviewPreviewView: View {
    let data: Data
    let original: UIImage?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cleaned: UIImage?
    @State private var showOriginal = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image = showOriginal ? original : cleaned {
                    ZoomableImagePreview(image: image, showZoomHint: true, accessibilityIdentifier: "fullReviewImage")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if original != nil {
                    Button {
                        showOriginal.toggle()
                    } label: {
                        Label(showOriginal ? "Show cleaned image" : "Reveal original", systemImage: showOriginal ? "eye.slash" : "eye")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("revealOriginalButton")
                }
                Text(showOriginal ? "Original · for comparison only" : "Cleaned image · pinch to inspect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            .navigationTitle(showOriginal ? "Original" : "Final preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                cleaned = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { showOriginal = false }
            }
        }
    }
}
