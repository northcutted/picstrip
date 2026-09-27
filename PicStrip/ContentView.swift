import AVFoundation
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

    /// Set to true when `StripImageIntent` asks for the multi-photo picker.
    @State private var isShowingIntentBatchPicker = false

    /// Bumped by `haptic(_:)`; each change plays one impact.
    @State private var lightImpacts = 0
    @State private var mediumImpacts = 0

    /// Drives the Files app picker sheet.
    @State private var isShowingFilePicker = false

    /// True while a drag is hovering over the drop target.
    @State private var isDropTargeted = false

    /// Whether the pasteboard holds an image; shows or hides the Paste button.
    @State private var pasteboard = PasteboardMonitor()

    /// Drives the document camera.
    @State private var isShowingScanner = false
    /// What the document camera returned; acted on once its cover has gone,
    /// because presenting the batch sheet mid-dismissal can drop the sheet.
    @State private var scanOutcome: DocumentScannerView.Outcome?
    /// Drives the live-preview camera; handled like the document camera above.
    @State private var isShowingLiveCamera = false
    @State private var liveCameraOutcome: LiveCameraView.Outcome?
    /// The system camera, used when the live-preview camera cannot be set up.
    @State private var isShowingCamera = false
    @State private var cameraOutcome: CameraCaptureView.Outcome?
    /// Shown when the camera permission has been refused.
    @State private var isShowingCameraDenied = false

    /// Rotating taglines shown beneath the app title on the home screen.
    private let mottos: [LocalizedStringKey] = [
        "Share the photo. Not the story behind it.",
        "Clean photos. Clear conscience.",
        "Your moment, minus the metadata.",
        "Photos without the fingerprints.",
        "Strip the data. Keep the memory."
    ]

    /// Index of the currently displayed motto.
    @State private var mottoIndex = 0
    @State private var moreImportsExpanded = false

    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var hasPhoto: Bool { viewModel.inputImage != nil }

    private var sourceHasPrivacyMetadata: Bool {
        viewModel.allSourceMetadata?.fields.contains {
            ImageProcessor.shouldReportStripped(
                category: $0.category,
                key: $0.key,
                isStructural: $0.isStructural,
                config: .default
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

                // Opening a large file takes a moment before there is a photo to
                // show.  Say so — after a beat, so a quick load does not flash.
                if !hasPhoto, viewModel.isProcessing {
                    processingOverlay
                        .ignoresSafeArea()
                        .zIndex(1)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeIn(duration: 0.2).delay(0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        ))
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
                            // System paste control: reads the pasteboard without the
                            // "Allow Paste" prompt.  It cannot take the glass pill style,
                            // so it lives in the bar, where a compact system control
                            // belongs, and only while the pasteboard holds an image.
                            if pasteboard.hasImage {
                                ToolbarItem(placement: .topBarLeading) {
                                    PasteButton(payloadType: IncomingImage.self) { images in
                                        haptic(.light)
                                        load(images)
                                    }
                                    .labelStyle(.titleAndIcon)
                                    .buttonBorderShape(.capsule)
                                    // Opaque on purpose: the system disables a paste
                                    // control whose tint is translucent or low-contrast.
                                    .tint(Color("PasteControlTint"))
                                    .accessibilityIdentifier("pasteImageButton")
                                }
                                // The control draws its own capsule; the bar's glass
                                // around it would make two outlines.
                                .sharedBackgroundVisibility(.hidden)
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showingAbout = true
                                } label: {
                                    Image(systemName: "questionmark.circle")
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
            // A scan lives only as long as its batch sheet; swiping the sheet
            // away must release the un-redacted pages too.
            viewModel.scannedBatchSources = []
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
        // `initial: true` covers a cold launch, where the intent has already run
        // by the time this view first appears.
        .onChange(of: intentRouter.isBatchPickerRequested, initial: true) { _, requested in
            guard requested else { return }
            intentRouter.batchPickerPresented()
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
        .confirmationDialog("Use a smaller copy?", isPresented: $viewModel.showResizeOffer, titleVisibility: .visible) {
            Button("Use smaller copy") { Task { await viewModel.useSmallerCopy() } }
            Button("Cancel", role: .cancel) { viewModel.discardLargeImage() }
        } message: {
            Text("This image exceeds the editor's 25 megapixel limit. Make a copy up to 12 megapixels to review and share. Your original stays unchanged.")
        }
        // ── Files app picker ──────────────────────────────────────────────
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                guard let data = await IncomingImage.read(securityScoped: url) else {
                    viewModel.errorMessage = String(localized: "The selected item could not be loaded as image data.")
                    return
                }
                await viewModel.loadData(data)
            }
        }
        // ── Drag-and-drop + paste (Photos / Files / Safari / pasteboard) ───
        // Both arrive as `IncomingImage`, i.e. the original bytes — metadata intact.
        .dropDestination(for: IncomingImage.self) { images, _ in
            load(images)
        } isTargeted: { isDropTargeted = $0 }
        .imagePasteDestination { images in
            load(images)
        }
        .photosPickerKeepsMetadata()
        // ── Document camera ───────────────────────────────────────────────
        .fullScreenCover(isPresented: $isShowingScanner, onDismiss: handleScanOutcome) {
            DocumentScannerView { outcome in
                scanOutcome = outcome
                isShowingScanner = false
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isShowingLiveCamera, onDismiss: handleLiveCameraOutcome) {
            LiveCameraView { outcome in
                liveCameraOutcome = outcome
                isShowingLiveCamera = false
            }
        }
        .fullScreenCover(isPresented: $isShowingCamera, onDismiss: handleCameraOutcome) {
            CameraCaptureView { outcome in
                cameraOutcome = outcome
                isShowingCamera = false
            }
            .ignoresSafeArea()
        }
        .alert("Camera Access Needed", isPresented: $isShowingCameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Camera access was denied. Please enable it in Settings.")
        }
        // ── Tap an object to redact it ────────────────────────────────────
        // The model behind it is downloaded by iOS from Apple, once.  PicStrip
        // makes no other network request, so it never starts this one unasked.
        .task { await viewModel.refreshObjectSelectionSupport() }
        // Load the on-device language model while the user is still choosing a
        // photo, so the name pass of the first scan does not pay the cold start.
        .task { SemanticPII.live.prewarm() }
        .alert("Download Object Selection?", isPresented: $viewModel.isAskingToDownloadObjectModel) {
            Button("Download") {
                Task {
                    let before = viewModel.redactionRegions.count
                    await viewModel.downloadObjectModelAndContinue()
                    if viewModel.redactionRegions.count > before { isAddingRedaction = false }
                }
            }
            Button("Not Now", role: .cancel) { viewModel.declineObjectModelDownload() }
        } message: {
            Text("Tap-to-select uses an Apple model downloaded with your permission. The model analyzes your photo on this device.")
        }
        .alert(
            "Object Selection",
            isPresented: Binding(
                get: { viewModel.objectSelectionMessage != nil },
                set: { if !$0 { viewModel.objectSelectionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.objectSelectionMessage ?? "")
        }
        // ── Paste button visibility ───────────────────────────────────────
        // Copying usually happens in another app, so re-check on every return
        // to the foreground; the notifications cover copies made while PicStrip
        // is frontmost and iPad multitasking, where the scene phase never changes.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            Task { await pasteboard.refresh() }
        }
        .onChange(of: hasPhoto) { _, hasPhoto in
            guard !hasPhoto else { return }
            Task { await pasteboard.refresh() }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIPasteboard.changedNotification) {
                await pasteboard.refresh()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIWindow.didBecomeKeyNotification) {
                await pasteboard.refresh()
            }
        }
        // Load failures happen while no photo is on screen, where the control
        // panel's error banner does not exist — surface them as an alert.
        .alert(
            "Couldn’t Open Image",
            isPresented: Binding(
                get: { !hasPhoto && !viewModel.isProcessing && viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
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
        .sensoryFeedback(.impact(weight: .light), trigger: lightImpacts)
        .sensoryFeedback(.impact(weight: .medium), trigger: mediumImpacts)
    }

    // MARK: - Home screen

    private var homeScreen: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("PicStrip")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("Share the photo. Not the story behind it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    ScannerHeroView()
                        .frame(height: 170)
                        .accessibilityHidden(true)
                    VStack(spacing: 12) {
                        PhotosPicker(selection: $viewModel.selectedItem, matching: .images, photoLibrary: .shared()) {
                            PillLabel(icon: "photo.badge.plus", text: "Select a Photo")
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("selectPhotoButton")
                        .accessibilityLabel("Select a photo from your library")

                        Button {
                            Task { await viewModel.loadDemo() }
                        } label: {
                            PillLabel(icon: "sparkles", text: "Try a sample")
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("tryDemoButton")
                        Text("A fictional photo. No library access needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { moreImportsExpanded.toggle() }
                        } label: {
                            HStack {
                                Text("More ways to import")
                                Spacer()
                                Image(systemName: moreImportsExpanded ? "chevron.down" : "chevron.right")
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("moreImportsButton")
                        .accessibilityValue(moreImportsExpanded ? "Expanded" : "Collapsed")
                        if moreImportsExpanded {
                            VStack(spacing: 12) {
                                PhotosPicker(
                                    selection: $viewModel.batchItems,
                                    maxSelectionCount: 0,
                                    matching: .images,
                                    photoLibrary: .shared()
                                ) {
                                    PillLabel(icon: "photo.stack", text: "Select Multiple Photos")
                                }
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("selectMultiplePhotosButton")
                                .simultaneousGesture(TapGesture().onEnded { haptic(.light) })

                                if CameraCaptureView.isAvailable {
                                    Button {
                                        haptic(.light)
                                        openCamera { isShowingLiveCamera = true }
                                    } label: {
                                        PillLabel(icon: "camera", text: "Take Photo")
                                    }
                                    .buttonStyle(.glass)
                                    .accessibilityIdentifier("takePhotoButton")
                                    .accessibilityLabel("Take a photo with the camera")
                                }

                                if DocumentScannerView.isAvailable {
                                    Button {
                                        haptic(.light)
                                        openCamera { isShowingScanner = true }
                                    } label: {
                                        PillLabel(icon: "doc.viewfinder", text: "Scan Document")
                                    }
                                    .buttonStyle(.glass)
                                    .accessibilityIdentifier("scanDocumentButton")
                                    .accessibilityLabel("Scan a document with the camera")
                                }

                                Button {
                                    haptic(.light)
                                    isShowingFilePicker = true
                                } label: {
                                    PillLabel(icon: "folder", text: "Browse Files")
                                }
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("browseFilesButton")
                                .accessibilityLabel("Browse files to select an image")

                            }
                            .padding(.top, 12)
                        }
                    }
                    .buttonBorderShape(.capsule)
                    if let error = viewModel.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Label("Processed on your device", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    // MARK: - Breathing gradient

    private var breathingGradient: some View {
        BreathingGradient()
    }

    // MARK: - Haptics

    /// Requests an impact; played by the `.sensoryFeedback` modifiers on `body`.
    private func haptic(_ weight: HapticWeight) {
        switch weight {
        case .light:  lightImpacts += 1
        case .medium: mediumImpacts += 1
        }
    }

    private enum HapticWeight { case light, medium }

    // MARK: - Document camera

    /// Runs `present` once the camera may be used, asking for or explaining the
    /// permission first.  Shared by the photo camera and the document camera.
    private func openCamera(_ present: @escaping () -> Void) {
        switch DocumentScanFlow.step(for: AVCaptureDevice.authorizationStatus(for: .video)) {
        case .present:
            present()
        case .requestAccess:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    present()
                } else {
                    isShowingCameraDenied = true
                }
            }
        case .explainDenied:
            isShowingCameraDenied = true
        }
    }

    private func handleLiveCameraOutcome() {
        defer { liveCameraOutcome = nil }
        switch liveCameraOutcome {
        case .captured(let data):
            // The camera's own bytes: metadata intact, exactly like a library photo.
            Task { await viewModel.loadCaptured(CapturedPages(count: 1) { _ in data }) }
        case .unavailable:
            isShowingCamera = true
        case .cancelled, nil:
            break
        }
    }

    private func handleCameraOutcome() {
        defer { cameraOutcome = nil }
        guard case .captured(let photo) = cameraOutcome else { return }
        Task { await viewModel.loadCaptured(CapturedPages(photo: photo)) }
    }

    private func handleScanOutcome() {
        defer { scanOutcome = nil }
        switch scanOutcome {
        case .scanned(let document):
            Task { await viewModel.loadCaptured(document.pages) }
        case .failed:
            viewModel.errorMessage = String(localized: "The document could not be scanned.")
        case .cancelled, nil:
            break
        }
    }

    // MARK: - Drag-and-drop / paste

    /// Loads the first image of a drop or paste.  PicStrip's editor is
    /// single-image, so any further items are ignored.
    @discardableResult
    private func load(_ images: [IncomingImage]) -> Bool {
        guard let image = images.first else { return false }
        Task { await viewModel.loadData(image.data) }
        return true
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
                    canSelectObjects: viewModel.isObjectSelectionSupported,
                    onSelect: { id in
                        viewModel.selectRedactionRegion(id: id)
                    },
                    onAdd: {
                        withAnimation(.spring(duration: 0.2)) {
                            isAddingRedaction.toggle()
                        }
                    },
                    onAddCentered: {
                        viewModel.addCustomRedaction(rect: CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.2))
                        isAddingRedaction = false
                    },
                    onAdjust: { id, rect in viewModel.adjustRedactionRegion(id: id, rect: rect) },
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
                    onChangeStrength: { id, strength in
                        viewModel.changeRedactionStrength(id: id, strength: strength)
                    },
                    onBulkChangeStyle: { ids, style in
                        viewModel.bulkChangeRedactionStyle(ids: ids, style: style)
                    },
                    onBulkChangeColor: { ids, color in
                        viewModel.bulkChangeRedactionColor(ids: ids, color: color)
                    },
                    onBulkChangeStrength: { ids, strength in
                        viewModel.bulkChangeRedactionStrength(ids: ids, strength: strength)
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
                        exportScale: viewModel.exportScale,
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
                        onSelectObject: viewModel.isObjectSelectionSupported ? { point in
                            haptic(.light)
                            Task {
                                let before = viewModel.redactionRegions.count
                                await viewModel.selectObject(at: point)
                                if viewModel.redactionRegions.count > before { isAddingRedaction = false }
                            }
                        } : nil,
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

                if viewModel.isSelectingObject {
                    ProgressView()
                        .controlSize(.large)
                        .padding(18)
                        .glassEffect(in: .rect(cornerRadius: 16))
                        .accessibilityLabel("Finding the object")
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
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
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
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
            // A material, not a translucent colour: it turns opaque under Reduce
            // Transparency, which a raw `.opacity(0.7)` never does.
            Rectangle().fill(.regularMaterial)
            ProgressView("Processing…")
                .padding()
                .glassEffect(in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        VStack(spacing: 14) {

            // Error banner
            if let error = viewModel.errorMessage {
                Label {
                    Text(error).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.footnote)
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

                    // The scan is already published; the language model may
                    // still add names to it.  Nothing waits on this.
                    if viewModel.isFindingNames {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                            Text("Looking for names…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("findingNamesLabel")
                        .transition(.opacity)
                    }
                }
            }

            if hasPhoto {
                HStack {
                    Menu {
                        ForEach(SharingPurpose.allCases) { purpose in
                            Button(purpose.title) { viewModel.applySharingPurpose(purpose) }
                        }
                    } label: {
                        Label("Sharing preset", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("sharingPresetButton")
                    Spacer()
                    if viewModel.isDemo {
                        Text("Fictional sample").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
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
                    selectedCategory: Binding(
                        get: { isPanelOpen ? visiblePanelCategory : nil },
                        set: { newValue in
                            if let newValue { openPanel(category: newValue) } else { closePanel() }
                        }
                    )
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
                    PillLabel(
                        icon: viewModel.isScanningPII ? "hourglass" : "square.and.arrow.up",
                        text: viewModel.isScanningPII ? "Scanning…" : "Review & Share"
                    )
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 4)
                .disabled(viewModel.isScanningPII || viewModel.isProcessing)
                .opacity(viewModel.isScanningPII ? 0.75 : 1)
                .accessibilityIdentifier("saveButton")
                .accessibilityHint(viewModel.isScanningPII ? "Save is available after the visual privacy scan completes." : "")
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(duration: 0.3), value: hasPhoto)
        .animation(.easeInOut(duration: 0.35), value: viewModel.detectedPII)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isScanningPII)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isFindingNames)
    }

    // MARK: - Scanning row (not interactive)

    /// What the scan is doing and how far it has got.  The bar is driven by the
    /// scanner's own milestones (`ScanProgress`), not by a timer.
    private var scanningRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "text.viewfinder")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityHidden(true)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Scanning for sensitive data")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(scanStageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
            }

            ScanProgressBar(progress: viewModel.scanProgress)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separator), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: viewModel.scanProgress.stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scanning for sensitive data")
        .accessibilityValue(
            Text(viewModel.scanProgress.fraction, format: .percent.precision(.fractionLength(0)))
        )
        .accessibilityIdentifier("scanningRow")
    }

    private var scanStageText: LocalizedStringKey {
        switch viewModel.scanProgress.stage {
        case .analysing: return "Reading text, faces and codes"
        case .matching:  return "Checking for sensitive details"
        }
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
                        .foregroundStyle(hasPIIDetections ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                } else {
                    Text("^[\(regionCount) region](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(hasPIIDetections ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                hasPIIDetections
                    ? AnyShapeStyle(Color.red.opacity(0.08))
                    : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        hasPIIDetections ? Color.red.opacity(0.35) : Color(.separator),
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

// MARK: - Breathing gradient

/// Decorative home-screen background: two radial blobs whose opacity breathes
/// on different periods, so the background never looks like it resets.
///
/// The phases are local state and the repeating animation is scoped to each
/// blob's opacity alone.  A global `withAnimation(….repeatForever())` here leaks
/// into whatever else lays out in the same transaction — on device it made the
/// home-screen buttons' glass backgrounds grow and shrink forever.
private struct BreathingGradient: View {
    @State private var topBright = false
    @State private var bottomBright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One breathing blob.  The gradient is drawn at `peak` and dimmed by an
    /// opacity factor, so the animated value is a single number: `floor`…`peak`,
    /// or `still` under Reduce Motion.
    private struct Blob {
        let color: Color
        let peak: Double
        let floor: Double
        let still: Double
        let center: UnitPoint
        let radius: CGFloat
        let period: Double
    }

    /// Top-left accent blob — cycles every 4 s.
    private static let top = Blob(
        color: .accentColor, peak: 0.20, floor: 0.05, still: 0.12,
        center: .topLeading, radius: 420, period: 4.0
    )
    /// Bottom-right indigo blob — cycles every 5.5 s, out of sync with the first.
    private static let bottom = Blob(
        color: .indigo, peak: 0.14, floor: 0.03, still: 0.08,
        center: .bottomTrailing, radius: 380, period: 5.5
    )

    var body: some View {
        ZStack {
            Color(.systemBackground)
            view(for: Self.top, bright: topBright)
            view(for: Self.bottom, bright: bottomBright)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true) // decorative background
        .onAppear {
            guard !reduceMotion else { return }
            topBright = true
            bottomBright = true
        }
    }

    private func view(for blob: Blob, bright: Bool) -> some View {
        RadialGradient(
            colors: [blob.color.opacity(blob.peak), .clear],
            center: blob.center,
            startRadius: 0,
            endRadius: blob.radius
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: blob.period).repeatForever(autoreverses: true)) {
            $0.opacity(reduceMotion ? blob.still / blob.peak : (bright ? 1 : blob.floor / blob.peak))
        }
    }
}

// MARK: - Pill button label

/// Full-width icon + title content for the large capsule buttons.  The surface
/// itself comes from the button style (`.glass` / `.glassProminent`), so the
/// system supplies Liquid Glass, press states, and the Reduce Transparency /
/// Increase Contrast fallbacks.
///
/// A `nonisolated` type rather than a `ContentView` method because
/// `PhotosPicker` builds its label in a nonisolated closure.
nonisolated private struct PillLabel: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(text)
        }
        .font(.callout.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// MARK: - Scan progress bar

/// A determinate bar for the privacy scan.
///
/// `progress.fraction` only moves when the scanner reports a finished step, and
/// reading text — most of the work — is a single step.  So between steps the bar
/// drifts a little way toward the next one, to show the scan is alive; it never
/// drifts far, and it never reaches the end on its own.  VoiceOver is given the
/// real fraction, not the drift.
private struct ScanProgressBar: View {
    let progress: ScanProgress

    @State private var displayed = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ProgressView(value: min(1, displayed))
            .progressViewStyle(.linear)
            .tint(Color.accentColor)
            .animation(.easeOut(duration: 0.4), value: displayed)
            .accessibilityHidden(true)
            .task(id: progress.fraction) {
                displayed = max(displayed, progress.fraction)
                guard !reduceMotion else { return }
                let ceiling = min(0.96, progress.fraction + 0.22)
                while !Task.isCancelled, displayed < ceiling - 0.004 {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    displayed += (ceiling - displayed) * 0.07
                }
            }
    }
}

#Preview {
    ContentView(viewModel: ScrubberViewModel())
        .environment(IntentRouter())
}
