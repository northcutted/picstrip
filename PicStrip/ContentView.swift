import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @State var viewModel: ScrubberViewModel
    @State private var isPanelOpen: Bool = false
    @State private var visiblePanelCategory: String = ""
    @State private var isRedactionEditing = false
    @State private var isAddingRedaction = false
    @State private var zoomResetRequest = 0

    /// Set to true by the scenePhase observer when StripImageIntent fires.
    @State private var isShowingIntentBatchPicker = false

    /// Drives the Files app picker sheet.
    @State private var isShowingFilePicker = false

    /// True while a drag is hovering over the drop target.
    @State private var isDropTargeted = false

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

    /// True once the on-device PII scan has found at least one detection.
    private var hasPIIDetections: Bool { !viewModel.detectedPII.isEmpty }

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
        // ── Files app picker ──────────────────────────────────────────────
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                guard let data = try? Data(contentsOf: url) else { return }
                await viewModel.loadData(data)
            }
        }
        // ── Drag-and-drop (image or file URL from Photos / Files / Safari) ──
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            // Subtle border pulse while a drag hovers over the window
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 3)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
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

                Button {
                    haptic(.light)
                    isShowingFilePicker = true
                } label: {
                    pillLabel(
                        icon: "folder",
                        text: "Browse Files",
                        prominent: false
                    )
                }
                .accessibilityIdentifier("browseFilesButton")
                .accessibilityLabel("Browse files to select an image")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.4), value: hasPhoto)
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

    // MARK: - Pill button label

    private func pillLabel(icon: String, text: LocalizedStringKey, prominent: Bool) -> some View {
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

    // MARK: - Drag-and-drop handler

    /// Handles a drop of one or more `NSItemProvider` items onto the app.
    ///
    /// Priority order:
    /// 1. A raw image type (JPEG / PNG / HEIC / GIF / …) from Photos or Safari.
    /// 2. A file URL referencing an image on disk (Files app, document providers).
    ///
    /// - Returns: `true` when a provider was accepted and loading is in flight.
    @discardableResult
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // ── Image data (Photos, Safari image, copy-paste) ──────────────────
        if provider.canLoadObject(ofClass: UIImage.self) {
            _ = provider.loadObject(ofClass: UIImage.self) { reading, _ in
                guard let image = reading as? UIImage,
                      let data  = image.jpegData(compressionQuality: 0.95)
                else { return }
                Task { @MainActor in await viewModel.loadData(data) }
            }
            return true
        }

        // ── File URL (Files app, document providers) ───────────────────────
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    guard let data = try? Data(contentsOf: url) else { return }
                    await viewModel.loadData(data)
                }
            }
            return true
        }

        return false
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

            if isRedactionEditing {
                RedactionEditorDrawer(
                    regions: viewModel.redactionRegions,
                    selectedRegionID: viewModel.selectedRedactionRegionID,
                    canUndo: viewModel.canUndo,
                    canRedo: viewModel.canRedo,
                    isAddingRedaction: isAddingRedaction,
                    onSelect: { id in
                        viewModel.selectRedactionRegion(id: id)
                    },
                    onAdd: {
                        withAnimation(.spring(duration: 0.2)) {
                            isAddingRedaction.toggle()
                        }
                    },
                    onToggleRegion: { id in
                        viewModel.toggleRedactionRegion(id: id)
                    },
                    onDeleteRegion: { id in
                        viewModel.deleteRedactionRegion(id: id)
                    },
                    onChangeStyle: { id, style in
                        viewModel.changeRedactionStyle(id: id, style: style)
                    },
                    onChangeColor: { id, color in
                        viewModel.changeRedactionColor(id: id, color: color)
                    },
                    onBulkChangeStyle: { ids, style in
                        viewModel.bulkChangeRedactionStyle(ids: ids, style: style)
                    },
                    onBulkChangeColor: { ids, color in
                        viewModel.bulkChangeRedactionColor(ids: ids, color: color)
                    },
                    onBulkDelete: { ids in
                        viewModel.bulkDeleteRedactionRegions(ids: ids)
                    },
                    onBulkToggle: { ids in
                        viewModel.bulkToggleRedactionRegions(ids: ids)
                    },
                    onUndo: { viewModel.undoRedaction() },
                    onRedo: { viewModel.redoRedaction() },
                    onFit: { zoomResetRequest += 1 },
                    onDone: {
                        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                            isRedactionEditing = false
                            isAddingRedaction = false
                            viewModel.selectRedactionRegion(id: nil)
                        }
                    }
                )
                .background(Color(.systemBackground))
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
            } else {
                controlPanel
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color(.systemBackground))
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.1), value: isRedactionEditing)
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
                        redactionRegions: viewModel.redactionRegions,
                        selectedRedactionRegionID: Binding(
                            get: { viewModel.selectedRedactionRegionID },
                            set: { viewModel.selectRedactionRegion(id: $0) }
                        ),
                        isRedactionEditing: isRedactionEditing,
                        isAddingRedaction: isAddingRedaction,
                        resetZoomRequest: zoomResetRequest,
                        isScanning: viewModel.isScanningPII,
                        showZoomHint: hasPhoto,
                        onTap: {
                            if isPanelOpen { closePanel() }
                        },
                        onAddRedaction: { rect in
                            viewModel.addCustomRedaction(rect: rect)
                            isAddingRedaction = false
                        },
                        onBeginUpdateRedaction: { id in
                            viewModel.beginRedactionUpdate(id: id)
                        },
                        onUpdateRedaction: { id, rect in
                            viewModel.updateRedactionRegion(id: id, rect: rect)
                        },
                        onSelectRedaction: { id in
                            viewModel.selectRedactionRegion(id: id)
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
                    .accessibilityIdentifier("dismissPhotoButton")
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

            // ── Redaction entry — adapts to PII scan state ─────────────
            // • Scanning  : muted row with spinner (not tappable)
            // • PII found : red banner (opens Sensitive Data review sheet)
            //               + a separate Edit Redactions row below it
            // • No PII    : normal "Edit Redactions" chevron row
            if hasPhoto {
                if viewModel.isScanningPII {
                    scanningRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    editRedactionsRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Metadata row — only when photo loaded
            if let metadata = viewModel.allSourceMetadata, sourceHasPrivacyMetadata, hasPhoto {

                // Label row
                HStack {
                    Label("Metadata found in this photo", systemImage: "tag.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("metadataFoundLabel")
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

    // MARK: - Scanning row (muted, not interactive)

    private var scanningRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.12))
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("Scanning for sensitive data")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Checking visible text before save")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityLabel("Scanning for sensitive data")
    }

    // MARK: - Edit Redactions row
    //
    // Neutral style when no PII is detected.
    // Red tint + eye icon when the on-device scan found sensitive visual data,
    // so the row itself signals the finding without a separate banner card.
    // Tapping always opens the redaction editor.

    private var editRedactionsRow: some View {
        Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                isRedactionEditing = true
                closePanel()
            }
        } label: {
            HStack(spacing: 10) {
                Label(
                    "Edit Redactions",
                    systemImage: hasPIIDetections ? "eye.fill" : "square.dashed"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(hasPIIDetections ? Color.red : Color.primary)

                Spacer()

                let regionCount = viewModel.enabledRedactionRegions.count
                if regionCount == 0 {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(hasPIIDetections ? AnyShapeStyle(Color.red.opacity(0.7)) : AnyShapeStyle(.tertiary))
                } else {
                    Text("^[\(regionCount) region](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(hasPIIDetections ? AnyShapeStyle(Color.red.opacity(0.7)) : AnyShapeStyle(.secondary))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hasPIIDetections ? AnyShapeStyle(Color.red.opacity(0.5)) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                hasPIIDetections
                    ? AnyShapeStyle(Color.red.opacity(0.08))
                    : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        hasPIIDetections ? Color.red.opacity(0.20) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            hasPIIDetections
                ? "Sensitive data found. Edit redactions. ^[\(viewModel.enabledRedactionRegions.count) region](inflect: true) active."
                : (viewModel.enabledRedactionRegions.isEmpty
                    ? "Edit redactions. None active."
                    : "Edit redactions. ^[\(viewModel.enabledRedactionRegions.count) region](inflect: true) active.")
        ))
        .accessibilityHint("Opens the redaction editor")
        .accessibilityIdentifier("editRedactionsButton")
    }

    // MARK: - Risk helpers (used by edit-redactions row and other in-body callouts)

    private func riskIcon(_ level: RiskLevel) -> String {
        switch level {
        case .critical: return "exclamationmark.octagon.fill"
        case .high:     return "exclamationmark.triangle.fill"
        case .medium:   return "info.circle.fill"
        case .low:      return "checkmark.circle.fill"
        }
    }

    private func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .blue
        case .low:      return .green
        }
    }

}

// MARK: - Redaction Editor Drawer

/// Bottom-panel UI that replaces `controlPanel` while the user is editing redaction regions.
///
/// **Single-select mode (default):** tapping a row selects it for image-preview focus and shows
/// the style / colour panel. The toggle and delete buttons appear on each row.
///
/// **Multi-select mode:** activated by the "Select" button in the header.
/// Each row shows a checkbox; tapping toggles it in `multiSelectedIDs`.
/// When at least one region is selected, a bulk style / colour panel appears and the
/// action bar shows Enable/Disable + Delete buttons for the whole selection.
/// Exiting multi-select (via the header "Done" button) clears the selection.
private struct RedactionEditorDrawer: View {

    let regions: [RedactionRegion]
    let selectedRegionID: String?
    let canUndo: Bool
    let canRedo: Bool
    let isAddingRedaction: Bool

    // Single-region callbacks
    let onSelect: (String?) -> Void
    let onAdd: () -> Void
    let onToggleRegion: (String) -> Void
    let onDeleteRegion: (String) -> Void
    let onChangeStyle: (String, RedactionStyle) -> Void
    let onChangeColor: (String, RedactionColor) -> Void

    // Bulk callbacks
    let onBulkChangeStyle: (Set<String>, RedactionStyle) -> Void
    let onBulkChangeColor: (Set<String>, RedactionColor) -> Void
    let onBulkDelete: (Set<String>) -> Void
    let onBulkToggle: (Set<String>) -> Void

    let onUndo: () -> Void
    let onRedo: () -> Void
    let onFit: () -> Void
    let onDone: () -> Void

    // MARK: - Multi-select local state

    @State private var isMultiSelectMode: Bool = false
    @State private var multiSelectedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Label("Redaction Regions", systemImage: "square.dashed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Select / Done — multi-select mode toggle
                if !regions.isEmpty {
                    Button(isMultiSelectMode ? "Done" : "Select") {
                        withAnimation(.spring(duration: 0.22)) {
                            isMultiSelectMode.toggle()
                            if !isMultiSelectMode {
                                multiSelectedIDs.removeAll()
                            } else {
                                // Clear VM single-select when entering multi-select
                                onSelect(nil)
                            }
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(isMultiSelectMode ? "Exit multi-select mode" : "Enter multi-select mode")
                }

                if !isMultiSelectMode {
                    // Add / Cancel-Add toggle (only in normal mode)
                    Button(action: onAdd) {
                        Label(
                            isAddingRedaction ? "Cancel" : "Add Region",
                            systemImage: isAddingRedaction ? "xmark" : "plus"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isAddingRedaction ? .secondary : .accentColor)
                    .controlSize(.small)
                    .accessibilityIdentifier("addRedactionButton")
                    .accessibilityLabel(isAddingRedaction ? "Cancel drawing redaction" : "Draw a new redaction region")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // ── Multi-select sub-header ───────────────────────────────────
            if isMultiSelectMode {
                HStack(spacing: 12) {
                    Button(multiSelectedIDs.count == regions.count ? "Deselect All" : "Select All") {
                        withAnimation(.spring(duration: 0.18)) {
                            if multiSelectedIDs.count == regions.count {
                                multiSelectedIDs.removeAll()
                            } else {
                                multiSelectedIDs = Set(regions.map(\.id))
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    if !multiSelectedIDs.isEmpty {
                        Text("^[\(multiSelectedIDs.count) region](inflect: true) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Draw-mode hint (single-select only) ──────────────────────
            if isAddingRedaction && !isMultiSelectMode {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 13, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Drag on the photo to draw a redaction box")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            // ── Region list ───────────────────────────────────────────────
            if regions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No redaction regions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 18)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(regions) { region in
                            regionRow(region)
                            if region.id != regions.last?.id {
                                Divider()
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
                .onChange(of: regions) { _, newRegions in
                    // Prune stale IDs (e.g. after undo removes regions)
                    let validIDs = Set(newRegions.map(\.id))
                    let stale = multiSelectedIDs.subtracting(validIDs)
                    if !stale.isEmpty {
                        multiSelectedIDs.subtract(stale)
                        if multiSelectedIDs.isEmpty {
                            withAnimation { isMultiSelectMode = false }
                        }
                    }
                }
            }

            Divider()

            // ── Style + Colour panel ──────────────────────────────────────
            // Single-select: show for the VM-selected region.
            // Multi-select: show bulk panel when at least one region is selected.
            if !isMultiSelectMode,
               let selectedRegion = regions.first(where: { $0.id == selectedRegionID }) {
                styleColorPanel(for: selectedRegion)
                Divider()
            } else if isMultiSelectMode && !multiSelectedIDs.isEmpty {
                bulkStyleColorPanel()
                Divider()
            }

            // ── Action bar ────────────────────────────────────────────────
            if isMultiSelectMode {
                bulkActionBar
            } else {
                normalActionBar
            }
        }
        .animation(.spring(duration: 0.22), value: isAddingRedaction)
        .animation(.spring(duration: 0.22), value: regions.count)
        .animation(.spring(duration: 0.22), value: isMultiSelectMode)
        .animation(.spring(duration: 0.18), value: multiSelectedIDs)
    }

    // MARK: - Normal action bar

    private var normalActionBar: some View {
        HStack(spacing: 8) {
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canUndo)
            .accessibilityLabel("Undo")
            .accessibilityIdentifier("undoRedactionButton")

            Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canRedo)
            .accessibilityLabel("Redo")
            .accessibilityIdentifier("redoRedactionButton")

            Button(action: onFit) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Reset zoom to fit image")
            .accessibilityIdentifier("resetZoomButton")

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Done editing redactions")
            .accessibilityIdentifier("doneEditingRedactionsButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Bulk action bar

    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            // Toggle enable / disable for all selected
            Button {
                onBulkToggle(multiSelectedIDs)
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(multiSelectedIDs.isEmpty)
            .accessibilityLabel("Toggle visibility of selected regions")

            // Delete all selected
            Button {
                let ids = multiSelectedIDs
                onBulkDelete(ids)
                withAnimation(.spring(duration: 0.22)) {
                    multiSelectedIDs.removeAll()
                    isMultiSelectMode = false
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(multiSelectedIDs.isEmpty)
            .accessibilityLabel("Delete selected regions")

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Done editing redactions")
            .accessibilityIdentifier("doneEditingRedactionsButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Single-region Style + Colour Panel

    /// Compact contextual panel shown when exactly one region is selected.
    /// Style choices are always visible; the colour row is hidden for `.pixelate`.
    @ViewBuilder
    private func styleColorPanel(for region: RedactionRegion) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Style row ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Style")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(RedactionStyle.allCases, id: \.self) { style in
                        let isActive = region.style == style
                        Button {
                            onChangeStyle(region.id, style)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: style.symbolName)
                                    .font(.system(size: 15, weight: isActive ? .bold : .regular))
                                Text(style.displayName)
                                    .font(.system(size: 9, weight: isActive ? .semibold : .regular))
                            }
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                isActive
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                                    : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        isActive ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(style.displayName) style")
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .accessibilityIdentifier("styleButton-\(style.rawValue)")
                    }
                }
            }

            // ── Colour row (suppressed for pixelate) ──────────────────────
            if region.style.supportsColor {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                        spacing: 8
                    ) {
                        ForEach(RedactionColor.allCases, id: \.self) { color in
                            let isActive = region.color == color
                            Button {
                                onChangeColor(region.id, color)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 28, height: 28)
                                    if color.isLight {
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                                            .frame(width: 28, height: 28)
                                    }
                                    if isActive {
                                        Circle()
                                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                            .frame(width: 34, height: 34)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(color.isLight ? Color.black : Color.white)
                                    }
                                }
                                .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(color.displayName) color")
                            .accessibilityAddTraits(isActive ? .isSelected : [])
                            .accessibilityIdentifier("colorButton-\(color.rawValue)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.18), value: region.style)
        .animation(.easeInOut(duration: 0.18), value: region.color)
    }

    // MARK: - Bulk Style + Colour Panel

    /// Style / colour panel shown in multi-select mode.
    ///
    /// Neither style nor colour shows an "active" selection when the set of selected
    /// regions has mixed values; tapping any option applies it to all selected regions.
    /// When all selected regions share the same style or colour, that option is highlighted.
    @ViewBuilder
    private func bulkStyleColorPanel() -> some View {
        let selectedRegions = regions.filter { multiSelectedIDs.contains($0.id) }

        // Shared style (non-nil only when ALL selected agree)
        let sharedStyle: RedactionStyle? = {
            let styles = Set(selectedRegions.map(\.style))
            return styles.count == 1 ? styles.first : nil
        }()

        // Shared colour (non-nil only when ALL selected agree and support colour)
        let sharedColor: RedactionColor? = {
            let colours = Set(selectedRegions.map(\.color))
            return colours.count == 1 ? colours.first : nil
        }()

        // Show colour row unless ALL selected regions are currently pixelated
        let showColorRow = !selectedRegions.allSatisfy { $0.style == .pixelate }

        VStack(alignment: .leading, spacing: 10) {

            // Context label
            Text("Apply to ^[\(multiSelectedIDs.count) region](inflect: true)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // ── Style row ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Style")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(RedactionStyle.allCases, id: \.self) { style in
                        let isActive = sharedStyle == style
                        Button {
                            onBulkChangeStyle(multiSelectedIDs, style)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: style.symbolName)
                                    .font(.system(size: 15, weight: isActive ? .bold : .regular))
                                Text(style.displayName)
                                    .font(.system(size: 9, weight: isActive ? .semibold : .regular))
                            }
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                isActive
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                                    : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        isActive ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Apply \(style.displayName) style to selected regions")
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
            }

            // ── Colour row ────────────────────────────────────────────────
            if showColorRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                        spacing: 8
                    ) {
                        ForEach(RedactionColor.allCases, id: \.self) { color in
                            let isActive = sharedColor == color
                            Button {
                                onBulkChangeColor(multiSelectedIDs, color)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 28, height: 28)
                                    if color.isLight {
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                                            .frame(width: 28, height: 28)
                                    }
                                    if isActive {
                                        Circle()
                                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                            .frame(width: 34, height: 34)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(color.isLight ? Color.black : Color.white)
                                    }
                                }
                                .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Apply \(color.displayName) color to selected regions")
                            .accessibilityAddTraits(isActive ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Region Row

    @ViewBuilder
    private func regionRow(_ region: RedactionRegion) -> some View {
        let isSingleSelected = !isMultiSelectMode && region.id == selectedRegionID
        let isMultiChecked   = isMultiSelectMode  && multiSelectedIDs.contains(region.id)
        let isHighlighted    = isSingleSelected || isMultiChecked

        Button {
            if isMultiSelectMode {
                if multiSelectedIDs.contains(region.id) {
                    multiSelectedIDs.remove(region.id)
                } else {
                    multiSelectedIDs.insert(region.id)
                }
            } else {
                onSelect(isSingleSelected ? nil : region.id)
            }
        } label: {
            HStack(spacing: 12) {

                // ── Leading icon: risk-level colour for detected, accent for custom ──
                Group {
                    if let type = region.type {
                        Image(systemName: riskIcon(type.riskLevel))
                            .foregroundStyle(riskColor(type.riskLevel))
                    } else {
                        Image(systemName: "square.dashed")
                            .foregroundStyle(.accent)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    (region.type.map { riskColor($0.riskLevel) } ?? Color.accentColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .accessibilityHidden(true)

                // ── Middle: name + snippet + confidence + risk ──────────────
                VStack(alignment: .leading, spacing: 2) {
                    Text(region.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSingleSelected ? Color.accentColor : .primary)

                    if let snippet = region.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    // Confidence score + risk badge on the same line
                    HStack(spacing: 6) {
                        if let score = region.score {
                            Text("\(Int(round(score * 100)))% match confidence")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let type = region.type {
                            Text(type.riskLevel.shortLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(riskColor(type.riskLevel))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    riskColor(type.riskLevel).opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }
                }

                Spacer(minLength: 4)

                // ── Trailing: checkbox in multi-select; toggle+delete in normal ──
                if isMultiSelectMode {
                    Image(systemName: isMultiChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isMultiChecked ? Color.accentColor : .secondary)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                } else {
                    HStack(spacing: 4) {
                        // Enable / disable toggle
                        Button {
                            onToggleRegion(region.id)
                        } label: {
                            Image(systemName: region.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(region.isEnabled ? .red : .secondary)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(region.isEnabled
                            ? "Disable redaction for \(region.displayName)"
                            : "Enable redaction for \(region.displayName)")
                        .accessibilityIdentifier("toggleRegionButton-\(region.id)")

                        // Delete
                        Button {
                            onDeleteRegion(region.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(region.displayName) region")
                        .accessibilityIdentifier("deleteRedactionButton")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHighlighted ? Color.accentColor.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(region.isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(region.displayName + (isSingleSelected ? ", selected" : ""))
        .accessibilityHint(
            isMultiSelectMode
                ? (isMultiChecked ? "Double tap to deselect" : "Double tap to add to selection")
                : (isSingleSelected ? "Double tap to deselect" : "Double tap to select and highlight on image")
        )
        .accessibilityIdentifier("regionRow-\(region.id)")
        .accessibilityAction(named: region.isEnabled ? "Disable redaction" : "Enable redaction") {
            onToggleRegion(region.id)
        }
        .accessibilityAction(named: "Delete redaction") {
            onDeleteRegion(region.id)
        }
    }

    // MARK: - Risk helpers

    private func riskIcon(_ level: RiskLevel) -> String {
        switch level {
        case .critical: return "exclamationmark.octagon.fill"
        case .high:     return "exclamationmark.triangle.fill"
        case .medium:   return "info.circle.fill"
        case .low:      return "checkmark.circle.fill"
        }
    }

    private func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .blue
        case .low:      return .green
        }
    }
}

#Preview {
    ContentView(viewModel: ScrubberViewModel())
}
