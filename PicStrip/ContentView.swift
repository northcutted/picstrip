import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @State private var viewModel = ScrubberViewModel()
    @State private var isPanelOpen: Bool = false
    @State private var visiblePanelCategory: String = ""
    @State private var showingPrivacyImpact = false
    @State private var isRedactionEditing = false
    @State private var isAddingRedaction = false
    @State private var zoomResetRequest = 0
    @State private var isShowingSensitiveDataReview = false

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
        .sheet(isPresented: $showingPrivacyImpact) {
            PrivacyImpactSummaryView(stats: PrivacyRemovalStats.load())
        }
        .sheet(isPresented: $isShowingSensitiveDataReview) {
            SensitiveDataReviewView(viewModel: viewModel)
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
            seedStatsIfRequested()
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
        Button {
            showingPrivacyImpact = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("^[\(lifetimeFields) field](inflect: true) stripped · ^[\(lifetimePhotos) photo](inflect: true) cleaned")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(statsText)
        .accessibilityElement(children: .ignore)
        .accessibilityHint("Double tap to review what was removed")
        .accessibilityIdentifier("privacyStatsButton")
    }

    private var statsText: String {
        let photos = lifetimePhotos
        let fields = lifetimeFields
        return String(localized: "^[\(fields) field](inflect: true) stripped · ^[\(photos) photo](inflect: true) cleaned")
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

    private func seedStatsIfRequested() {
        guard ProcessInfo.processInfo.environment["PICSTRIP_SEED_STATS"] == "1" else { return }

        lifetimePhotos = 4
        lifetimeFields = 18

        var stats = PrivacyRemovalStats()
        stats.metadataCategoryCounts = ["GPS": 6, "EXIF": 8, "IPTC": 4]
        stats.visualTypeCounts = ["Email Address": 3, "Phone Number": 2, "Custom Redaction": 1]
        stats.visualConfidenceCounts = ["High": 4, "Medium": 1]
        stats.save()
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
                } else if !viewModel.detectedPII.isEmpty {
                    sensitiveBanner
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    editRedactionsRow
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

    // MARK: - Sensitive data found banner → opens SensitiveDataReviewView

    private var sensitiveBanner: some View {
        Button {
            isShowingSensitiveDataReview = true
            closePanel()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.14))
                    Image(systemName: "eye.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sensitive data found")
                        .font(.subheadline.weight(.semibold))
                    // Single Text — split concatenations (Text(...) + Text(...))
                    // each look up their own LocalizedStringKey, so SwiftUI can't
                    // find translations for fragments like "%lld type found • ".
                    // Combining produces one key that already lives in
                    // Localizable.xcstrings with translations for all locales.
                    Text("^[\(viewModel.detectedPII.count) type](inflect: true) found • ^[\(viewModel.enabledRedactionRegions.count) region](inflect: true) will redact")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.red.opacity(0.20), lineWidth: 1)
            )
            // Inner identifier lets XCUITest confirm the PII section is present
            // as a distinct element from the tap target.
            .accessibilityIdentifier("sensitiveDataSection")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text("Sensitive data found: ^[\(viewModel.detectedPII.count) type](inflect: true), ^[\(viewModel.enabledRedactionRegions.count) region](inflect: true) will redact. Tap to review.")
        )
        .accessibilityIdentifier("reviewSensitiveDataButton")
        .accessibilityHint("Opens the Sensitive Data review sheet")
    }

    // MARK: - Edit Redactions row → opens the redaction editor

    private var editRedactionsRow: some View {
        Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                isRedactionEditing = true
                closePanel()
            }
        } label: {
            HStack(spacing: 10) {
                Label("Edit Redactions", systemImage: "square.dashed")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                let regionCount = viewModel.enabledRedactionRegions.count
                if regionCount == 0 {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("^[\(regionCount) region](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            viewModel.enabledRedactionRegions.isEmpty
                ? "Edit redactions. None active."
                : "Edit redactions. \(viewModel.enabledRedactionRegions.count) active."
        ))
        .accessibilityHint("Opens the redaction editor")
        .accessibilityIdentifier("editRedactionsButton")
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

}

// MARK: - Redaction Editor Drawer

/// Bottom-panel UI that replaces `controlPanel` while the user is editing redaction regions.
/// All state is passed in as value types + action callbacks — no `@Binding` — for clean
/// separation from `ContentView`'s state machine.
private struct RedactionEditorDrawer: View {

    let regions: [RedactionRegion]
    let selectedRegionID: String?
    let canUndo: Bool
    let canRedo: Bool
    let isAddingRedaction: Bool

    let onSelect: (String?) -> Void
    let onAdd: () -> Void
    let onToggleRegion: (String) -> Void
    let onDeleteRegion: (String) -> Void
    let onChangeStyle: (String, RedactionStyle) -> Void
    let onChangeColor: (String, RedactionColor) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onFit: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Label("Redaction Regions", systemImage: "square.dashed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Add / Cancel-Add toggle
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
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // ── Draw-mode hint ────────────────────────────────────────────
            if isAddingRedaction {
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
            }

            Divider()

            // ── Style + Color panel (visible when a region is selected) ────
            if let selectedRegion = regions.first(where: { $0.id == selectedRegionID }) {
                styleColorPanel(for: selectedRegion)
                Divider()
            }

            // ── Action bar ────────────────────────────────────────────────
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
        .animation(.spring(duration: 0.22), value: isAddingRedaction)
        .animation(.spring(duration: 0.22), value: regions.count)
    }

    // MARK: - Style + Color Panel

    /// Compact contextual panel shown when a region is selected.
    /// Style choices are always visible; the colour row is hidden for `.pixelate`
    /// (which shows scrambled source pixels — colour is irrelevant).
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

    // MARK: - Region Row

    @ViewBuilder
    private func regionRow(_ region: RedactionRegion) -> some View {
        let isSelected = region.id == selectedRegionID

        Button {
            onSelect(isSelected ? nil : region.id)
        } label: {
            HStack(spacing: 12) {

                // ── Leading icon: confidence-colored for detected, accent for custom ──
                Group {
                    if let level = region.confidence {
                        Image(systemName: confidenceIcon(level))
                            .foregroundStyle(confidenceColor(level))
                    } else {
                        Image(systemName: "square.dashed")
                            .foregroundStyle(.accent)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    (region.confidence.map(confidenceColor) ?? .accentColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .accessibilityHidden(true)

                // ── Middle: name + snippet + confidence score ──────────────
                VStack(alignment: .leading, spacing: 2) {
                    Text(region.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)

                    if let snippet = region.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if let score = region.score, let level = region.confidence {
                        Text("\(score, format: .percent.precision(.fractionLength(0))) match")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(confidenceColor(level))
                    }
                }

                Spacer(minLength: 4)

                // ── Trailing: enable/disable toggle + delete ───────────────
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(region.isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(region.displayName + (isSelected ? ", selected" : ""))
        .accessibilityHint(isSelected ? "Double tap to deselect" : "Double tap to select and highlight on image")
        .accessibilityIdentifier("regionRow-\(region.id)")
        .accessibilityAction(named: region.isEnabled ? "Disable redaction" : "Enable redaction") {
            onToggleRegion(region.id)
        }
        .accessibilityAction(named: "Delete redaction") {
            onDeleteRegion(region.id)
        }
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
}

#Preview {
    ContentView()
}
