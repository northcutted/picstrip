import PhotosUI
import SwiftUI

struct ContentView: View {

    @State private var viewModel = ScrubberViewModel()
    @State private var isPanelOpen: Bool = false
    @State private var visiblePanelCategory: String = ""

    /// Set to true by the scenePhase observer when StripImageIntent fires.
    @State private var isShowingIntentBatchPicker = false

    /// Rotating taglines shown beneath the app title on the home screen.
    private let mottos = [
        "Share the photo. Not the story behind it.",
        "Clean photos. Clear conscience.",
        "Your moment, minus the metadata.",
        "Photos without the fingerprints.",
        "Strip the data. Keep the memory."
    ]

    /// Index of the currently displayed motto.
    @State private var mottoIndex = 0

    /// Drives the top-left accent blob (faster cycle).
    @State private var topBlobPhase = false
    /// Drives the bottom-right indigo blob (slower cycle, offset feel).
    @State private var bottomBlobPhase = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Lifetime stats — written by ScrubberViewModel, read here via @AppStorage.
    @AppStorage("picstrip.lifetimePhotos") private var lifetimePhotos: Int = 0
    @AppStorage("picstrip.lifetimeFields") private var lifetimeFields: Int = 0

    private var hasPhoto: Bool { viewModel.inputImage != nil }

    private var sourceHasPrivacyMetadata: Bool {
        viewModel.allSourceMetadata?.fields.contains {
            ImageProcessor.shouldReportStripped(
                category: $0.category,
                key: $0.key,
                isStructural: $0.isStructural,
                config: viewModel.stripConfig
            )
        } == true
    }

    /// Controls presentation of the About / Trust sheet.
    @State private var showingAbout = false

    private func openPanel(category: String) {
        visiblePanelCategory = category
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { isPanelOpen = true }
    }

    private func closePanel() {
        withAnimation(.spring(duration: 0.32, bounce: 0.0)) { isPanelOpen = false }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Gradient is only visible on the home screen.
                if !hasPhoto {
                    breathingGradient
                }

                if hasPhoto {
                    photoLayout
                        .navigationTitle("PicStrip")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    homeScreen
                        // Keep the bar in the hierarchy so toolbar items render,
                        // but make it fully transparent so the gradient shows through.
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    showingAbout = true
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.7))
                                }
                                .accessibilityIdentifier("infoButton")
                                .accessibilityLabel("About PicStrip")
                            }
                        }
                        .sheet(isPresented: $showingAbout) {
                            AboutView()
                        }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: hasPhoto)
        }
        .sheet(item: $viewModel.activeSheet, onDismiss: {
            viewModel.selectedPIIResult = nil
        }, content: { sheet in
            switch sheet {
            case .pii:    PIIDetailsView(viewModel: viewModel)
            case .preSave: PreSaveReviewView(viewModel: viewModel)
            case .batch:  BatchConfigView(viewModel: viewModel)
            }
        })
        .onChange(of: viewModel.activeSheet) { _, newSheet in
            if newSheet != nil { closePanel() }
        }
        // ── Intent trigger ────────────────────────────────────────────────
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            let defaults = UserDefaults(suiteName: "group.com.northcutt.PicStrip")
            guard defaults?.bool(forKey: "picstrip.openBatchPicker") == true else { return }
            defaults?.set(false, forKey: "picstrip.openBatchPicker")
            isShowingIntentBatchPicker = true
        }
        // ── Programmatic PhotosPicker for intent ──────────────────────────
        .photosPicker(
            isPresented: $isShowingIntentBatchPicker,
            selection: $viewModel.batchItems,
            maxSelectionCount: 0,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: viewModel.batchItems) { _, items in
            guard !items.isEmpty else { return }
            if items.count == 1 {
                viewModel.selectedItem = items[0]
                viewModel.batchItems   = []
            } else {
                viewModel.activeSheet = .batch
            }
        }
        // ── UITest fixture injection ───────────────────────────────────────
        // When PICSTRIP_FIXTURE is set in launchEnvironment (by the snapshot
        // test), load the image bytes directly so the full photo UI is visible
        // without needing to automate the system Photos picker.
        .task {
            guard let path = ProcessInfo.processInfo.environment["PICSTRIP_FIXTURE"],
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { return }
            await viewModel.loadData(data)
        }
    }

    // MARK: - Home screen

    private var homeScreen: some View {
        VStack(spacing: 0) {

            Spacer()

            // App title + rotating motto
            VStack(spacing: 8) {
                Text("PicStrip")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)

                // Fixed-height clip zone keeps layout stable as motto length varies.
                ZStack {
                    Text(mottos[mottoIndex])
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .id(mottoIndex)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }
                .frame(height: 44)
                .clipped()
            }
            .padding(.top, 20)
                .task {
                // Cycle mottos every 3.5 s; task cancels automatically when view disappears.
                // Skip cycling when Reduce Motion is on — show first motto statically.
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5.5))
                    withAnimation(.easeInOut(duration: 0.45)) {
                        mottoIndex = (mottoIndex + 1) % mottos.count
                    }
                }
            }

            Spacer()

            // Hero animation
            ScannerHeroView()
                .padding(.vertical, 8)
                .accessibilityHidden(true)

            Spacer()

            // Lifetime stats capsule — only shown after first save
            if lifetimePhotos > 0 {
                statsCapsule
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Action buttons
            VStack(spacing: 12) {
                PhotosPicker(
                    selection: $viewModel.selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    pillLabel(
                        icon: "photo.badge.plus",
                        text: "Select a Photo",
                        prominent: true
                    )
                }
                .accessibilityIdentifier("selectPhotoButton")
                .accessibilityLabel("Select a photo from your library")
                .simultaneousGesture(TapGesture().onEnded { haptic(.medium) })

                PhotosPicker(
                    selection: $viewModel.batchItems,
                    maxSelectionCount: 0,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    pillLabel(
                        icon: "photo.stack",
                        text: "Select Multiple Photos",
                        prominent: false
                    )
                }
                .simultaneousGesture(TapGesture().onEnded { haptic(.light) })
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.4), value: lifetimePhotos)
    }

    // MARK: - Breathing gradient

    private var breathingGradient: some View {
        ZStack {
            Color(.systemBackground)

            // Top-left accent blob — cycles every 4 s.
            RadialGradient(
                colors: [Color.accentColor.opacity(reduceMotion ? 0.12 : (topBlobPhase ? 0.20 : 0.05)), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )

            // Bottom-right indigo blob — cycles every 5.5 s, so the two blobs
            // are never in sync and the background never looks like it resets.
            RadialGradient(
                colors: [Color.indigo.opacity(reduceMotion ? 0.08 : (bottomBlobPhase ? 0.14 : 0.03)), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true) // decorative background
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true)) {
                topBlobPhase = true
            }
            withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) {
                bottomBlobPhase = true
            }
        }
    }

    // MARK: - Stats capsule

    private var statsCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("^[\(lifetimeFields) field](inflect: true) stripped · ^[\(lifetimePhotos) photo](inflect: true) cleaned")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .accessibilityLabel(statsText)
        .accessibilityElement(children: .ignore)
    }

    private var statsText: String {
        let photos = lifetimePhotos
        let fields = lifetimeFields
        let photoStr = photos == 1 ? "1 photo" : "\(photos.formatted()) photos"
        let fieldStr = "\(fields.formatted()) fields"
        return "\(fieldStr) stripped · \(photoStr) cleaned"
    }

    // MARK: - Pill button label

    private func pillLabel(icon: String, text: String, prominent: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(prominent ? .white : .primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial),
            in: Capsule()
        )
        .overlay(
            prominent ? nil : AnyView(
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        )
    }

    // MARK: - Haptics

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - Photo layout (existing layout when a photo is loaded)

    private var photoLayout: some View {
        VStack(spacing: 0) {
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

            controlPanel
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(.systemBackground))
        }
    }

    // MARK: - Image display region

    @ViewBuilder
    private var imageDisplay: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Photo or placeholder — never moves
                if let uiImage = viewModel.sourceUIImage {
                    ZoomableImagePreview(
                        image: uiImage,
                        highlightedResults: viewModel.redactionPreviewResults,
                        focusedResult: viewModel.selectedPIIResult,
                        isScanning: viewModel.isScanningPII,
                        showZoomHint: hasPhoto,
                        onTap: {
                            if isPanelOpen { closePanel() }
                        }
                    )
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                } else {
                    placeholder
                }

                // Processing overlay
                if viewModel.isProcessing {
                    processingOverlay
                }

                // × dismiss button
                if hasPhoto {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPanelOpen = false
                            visiblePanelCategory = ""
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
                    .accessibilityLabel("Dismiss photo")
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                // Category detail panel
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

            if hasPhoto, viewModel.isScanningPII || !viewModel.detectedPII.isEmpty {
                sensitiveDataSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Metadata row — only when photo loaded
            if let metadata = viewModel.allSourceMetadata, sourceHasPrivacyMetadata, hasPhoto {

                // Label row
                HStack {
                    Label("Metadata found in this photo", systemImage: "tag.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Tap to review")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))

                MetadataBadgeRow(
                    metadata: metadata,
                    onPhoto: false,
                    selectedCategory: Binding(
                        get: { isPanelOpen ? visiblePanelCategory : nil },
                        set: { newValue in
                            if let newValue { openPanel(category: newValue) } else { closePanel() }
                        }
                    ),
                    trailingPill: nil
                )
                .padding(.horizontal, -4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if hasPhoto, viewModel.allSourceMetadata != nil {
                HStack(spacing: 8) {
                    Label("No hidden metadata found", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 4)
                .accessibilityIdentifier("noMetadataBanner")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Save button — always at bottom when photo is loaded
            if hasPhoto {
                Button {
                    haptic(.medium)
                    viewModel.requestSave()
                } label: {
                    pillLabel(
                        icon: viewModel.isScanningPII ? "hourglass" : "square.and.arrow.down",
                        text: viewModel.isScanningPII ? "Scanning…" : "Save to Photos",
                        prominent: true
                    )
                }
                .padding(.horizontal, 4)
                .disabled(viewModel.isScanningPII)
                .opacity(viewModel.isScanningPII ? 0.75 : 1)
                .accessibilityIdentifier("saveButton")
                .accessibilityHint(viewModel.isScanningPII ? "Save is available after the visual privacy scan completes." : "")
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(duration: 0.3), value: hasPhoto)
        .animation(.easeInOut(duration: 0.35), value: viewModel.detectedPII)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isScanningPII)
    }

    // MARK: - Sensitive data section

    private var sensitiveDataSection: some View {
        let typeCount = viewModel.detectedPII.count
        let redactionCount = viewModel.redactionPreviewResults.reduce(0) { $0 + $1.matchCount }

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.14))
                Image(systemName: viewModel.isScanningPII ? "hourglass" : "eye.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.isScanningPII ? "Scanning for sensitive data" : "Sensitive data found")
                    .font(.subheadline.weight(.semibold))

                Text(viewModel.isScanningPII
                    ? "Checking visible text before save"
                    : "\(typeCount) type\(typeCount == 1 ? "" : "s") found • \(redactionCount) region\(redactionCount == 1 ? "" : "s") will redact")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if viewModel.isScanningPII {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Button {
                    viewModel.activeSheet = .pii
                } label: {
                    Label("Review", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .accessibilityIdentifier("reviewSensitiveDataButton")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.red.opacity(0.20), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sensitiveDataSection")
        .accessibilityLabel(viewModel.isScanningPII
            ? "Scanning for sensitive data"
            : "Sensitive data found: \(typeCount) type\(typeCount == 1 ? "" : "s"), \(redactionCount) region\(redactionCount == 1 ? "" : "s") will redact")
    }

    // MARK: - Confidence helpers

    private func confidenceIcon(_ level: ConfidenceLevel) -> String {
        switch level {
        case .high:   return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low:    return "info.circle.fill"
        }
    }

    private func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        }
    }

    // MARK: - Action button helper (icon + label, used in photo-loaded control panel)

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
