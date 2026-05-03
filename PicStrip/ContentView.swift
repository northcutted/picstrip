import SwiftUI
import PhotosUI

struct ContentView: View {

    @State private var viewModel = ScrubberViewModel()
    @State private var showAdvanced: Bool = false
    @State private var isPanelOpen: Bool = false
    @State private var visiblePanelCategory: String = ""

    private var hasPhoto: Bool { viewModel.inputImage != nil }

    /// Called by the badge row when a category is tapped.
    private func openPanel(category: String) {
        visiblePanelCategory = category          // content set first, synchronously
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
            isPanelOpen = true
        }
    }

    private func closePanel() {
        withAnimation(.spring(duration: 0.32, bounce: 0.0)) {
            isPanelOpen = false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Image display
                imageDisplay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .onChange(of: viewModel.allSourceMetadata?.fields.count) { _, newCount in
                        if newCount == nil {
                            isPanelOpen = false
                            visiblePanelCategory = ""
                        }
                    }

                Divider()

                // MARK: - Controls
                controlPanel
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color(.systemBackground))
            }
            .navigationTitle("PicStrip")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $viewModel.showPreSaveReview) {
            PreSaveReviewView(viewModel: viewModel)
        }
    }

    // MARK: - Image display region

    @ViewBuilder
    private var imageDisplay: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Photo or placeholder — never moves
                if let image = viewModel.inputImage {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                        .onTapGesture {
                            if isPanelOpen { closePanel() }
                        }
                } else {
                    placeholder
                }

                // Processing overlay
                if viewModel.isProcessing {
                    processingOverlay
                }

                // × dismiss button — top-right, always above panel
                if hasPhoto {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPanelOpen = false
                            visiblePanelCategory = ""
                            showAdvanced = false
                            viewModel.clearState()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                // Category detail panel — floats over image via offset, never disturbs layout
                if let metadata = viewModel.allSourceMetadata,
                   !metadata.isEmpty,
                   hasPhoto {
                    let fields = metadata.fields.filter { $0.category == visiblePanelCategory }

                    CategoryDetailPanel(
                        category: visiblePanelCategory,
                        fields: fields,
                        stripConfig: $viewModel.stripConfig,
                        onDismiss: closePanel
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .offset(y: isPanelOpen ? 0 : geo.size.height)
                    .opacity(isPanelOpen ? 1 : 0)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasPhoto)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Select a Photo")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Privacy metadata is stripped automatically before saving.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Processing overlay

    private var processingOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.7)
            ProgressView("Processing…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        VStack(spacing: 14) {

            // Error banner
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Badge row — only when photo loaded
            if let metadata = viewModel.allSourceMetadata, !metadata.isEmpty, hasPhoto {
                MetadataBadgeRow(
                    metadata: metadata,
                    onPhoto: false,
                    selectedCategory: Binding(
                        get: { isPanelOpen ? visiblePanelCategory : nil },
                        set: { newValue in
                            if let newValue {
                                openPanel(category: newValue)
                            } else {
                                closePanel()
                            }
                        }
                    )
                )
                .padding(.horizontal, -4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Export Options — only when photo loaded
            if hasPhoto {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    AdvancedOptionsView(viewModel: viewModel)
                        .padding(.top, 10)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.subheadline)
                        Text("Export Options")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .tint(.secondary)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Buttons — always at the bottom
            if hasPhoto {
                HStack(spacing: 32) {
                    Spacer()

                    Button { viewModel.requestSave() } label: {
                        actionButton("square.and.arrow.down", label: "Save to Photos", prominent: true)
                    }

                    if let processed = viewModel.processedData {
                        ShareLink(
                            item: processed,
                            preview: SharePreview(
                                "Scrubbed Image",
                                image: viewModel.inputImage ?? Image(systemName: "photo")
                            )
                        ) {
                            actionButton("square.and.arrow.up", label: "Share", prominent: false)
                        }
                    }

                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                // Select photo — single centred button
                HStack {
                    Spacer()
                    PhotosPicker(
                        selection: $viewModel.selectedItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        actionButton("photo.badge.plus", label: "Select Photo", prominent: false)
                    }
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(duration: 0.3), value: hasPhoto)
        .animation(.spring(duration: 0.3), value: viewModel.processedData != nil)
    }

    // MARK: - Action button helper (icon + label)

    private func actionButton(_ systemName: String, label: String, prominent: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(prominent ? .white : .primary)
                .frame(width: 56, height: 56)
                .background(
                    prominent ? Color.accentColor : Color(.tertiarySystemFill),
                    in: Circle()
                )
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
