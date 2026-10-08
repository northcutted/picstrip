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
    /// Set to true when `CleanScreenshotIntent` asks for the screenshot picker.
    @State private var isShowingScreenshotPicker = false
    /// A video picked on the home screen; its cleaner shows while it is set.
    @State private var selectedVideoItem: PhotosPickerItem?
    /// A video file opened directly by the UI tests (`PICSTRIP_VIDEO_FIXTURE`).
    @State private var fixtureVideo: URL?
    /// A video just recorded with PicStrip's camera, on its way to the cleaner.
    @State private var recordedVideo: URL?
    /// A video chosen in Files, copied into the protected store.
    @State private var importedVideo: URL?
    /// What was just picked from the library: routed to the right flow by `openLibrarySelection`.
    @State private var libraryItems: [PhotosPickerItem] = []

    /// Bumped by `haptic(_:)`; each change plays one impact.
    @State private var lightImpacts = 0
    @State private var mediumImpacts = 0

    /// Drives the Files app picker sheet.
    @State private var isShowingFilePicker = false

    /// True while a drag is hovering over the drop target.
    @State private var isDropTargeted = false

    /// Whether the pasteboard holds an image; shows or hides the Paste button.
    @State private var pasteboard = PasteboardMonitor()

    /// Drives the live-preview camera; handled like the document camera above.
    /// The camera, and the mode it opens in: Take Photo or Record Video.
    @State private var cameraRequest: CameraRequest?
    @State private var liveCameraOutcome: LiveCameraView.Outcome?
    /// The system camera, used when the live-preview camera cannot be set up.
    @State private var isShowingCamera = false
    @State private var cameraOutcome: CameraCaptureView.Outcome?
    /// Shown when the camera permission has been refused.
    @State private var isShowingCameraDenied = false

    /// VoiceOver's place when the editor closes: the row that opened it.
    @AccessibilityFocusState private var isEditRowFocused: Bool

    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    /// Controls presentation of the Always Cover list.
    @State private var showingAlwaysCover = false

    private func openPanel(category: String) {
        visiblePanelCategory = category
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { isPanelOpen = true }
    }

    private func closePanel() {
        withAnimation(.spring(duration: 0.32, bounce: 0.0)) { isPanelOpen = false }
    }

    // MARK: - Body

    // The body's modifiers come in three parts: as one chain they were too
    // long for Xcode 26's type checker.
    var body: some View {
        alertsAndObservers(importsAndCapture(mainContent))
    }

    /// The video on its way to the cleaner, wherever it came from.
    private var openVideo: VideoSource? {
        if let selectedVideoItem { return .picked(selectedVideoItem) }
        if let recordedVideo { return .recorded(recordedVideo) }
        if let importedVideo { return .imported(importedVideo) }
        if let fixtureVideo { return .file(fixtureVideo) }
        return nil
    }

    private func closeVideo() {
        selectedVideoItem = nil
        recordedVideo = nil
        importedVideo = nil
        fixtureVideo = nil
    }

    private var mainContent: some View {
        NavigationStack {
            ZStack {
                // Gradient is only visible on the home screen.
                if !hasPhoto {
                    driftingGradient
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
                                    showingAlwaysCover = true
                                } label: {
                                    Image(systemName: "pin")
                                }
                                .accessibilityIdentifier("alwaysCoverButton")
                                .accessibilityLabel("Always Cover")
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
                        .sheet(isPresented: $showingAlwaysCover, onDismiss: viewModel.refreshAlwaysCover) {
                            AlwaysCoverView(list: viewModel.alwaysCoverList)
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
            viewModel.fileBatchVideos = []
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
        // The library button's picker: whatever is picked is routed the same way.
        .photosPicker(
            isPresented: $isShowingIntentBatchPicker,
            selection: $libraryItems,
            maxSelectionCount: 0,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        )
        .onChange(of: intentRouter.isScreenshotPickerRequested, initial: true) { _, requested in
            guard requested else { return }
            intentRouter.screenshotPickerPresented()
            isShowingScreenshotPicker = true
        }
        .photosPicker(
            isPresented: $isShowingScreenshotPicker,
            selection: $viewModel.selectedItem,
            matching: .screenshots,
            photoLibrary: .shared()
        )
        .sheet(isPresented: Binding(get: { openVideo != nil }, set: { if !$0 { closeVideo() } }), onDismiss: openHandedOffVideo) {
            if let openVideo {
                VideoCleanerView(source: openVideo, reviewPrompt: viewModel.reviewPrompt)
                    // On iPad, room for the preview, the faces and the notes together.
                    .presentationSizing(.page)
            }
        }
    }

    /// Fixtures, the Files and drop importers, the library selection and the camera.
    private func importsAndCapture<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: intentRouter.isCameraRequested, initial: true) { _, requested in
            guard requested else { return }
            intentRouter.cameraPresented()
            if CameraCaptureView.isAvailable { openCamera { showCamera(.photo) } }
        }
        // A video from the Share Extension's Edit; see `openHandedOffVideo`.
        .onChange(of: intentRouter.requestedVideo, initial: true) { _, _ in openHandedOffVideo() }
        .onChange(of: viewModel.batchItems) { _, items in
            // A batch with videos in it is opened by `openLibrarySelection`.
            guard !items.isEmpty, viewModel.batchVideoItems.isEmpty else { return }
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
        // PICSTRIP_LIVE_CAMERA_FIXTURE opens the viewfinder on a still image,
        // which is the only way to run it on the simulator.
        .task {
            if LiveCameraFixture.isConfigured { showCamera(.photo) }
            // PICSTRIP_VIDEO_CAMERA_FIXTURE: the camera in Video mode, recording a movie file.
            if VideoCameraFixture.isConfigured { showCamera(.video) }
        }
        // PICSTRIP_VIDEO_FIXTURE opens the video screen on a file, without the picker.
        .task {
            if let path = ProcessInfo.processInfo.environment["PICSTRIP_VIDEO_FIXTURE"] {
                fixtureVideo = URL(fileURLWithPath: path)
            }
            // PICSTRIP_BATCH_FIXTURE: photos and videos, one path per line, as one batch.
            if let list = ProcessInfo.processInfo.environment["PICSTRIP_BATCH_FIXTURE"] {
                viewModel.openFileBatch(list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) })
            }
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
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
                openVideoFile(url)
                return
            }
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
        // ── Camera: photo, video and document ─────────────────────────────
        .onChange(of: libraryItems) { _, items in openLibrarySelection(items) }
        .fullScreenCover(item: $cameraRequest, onDismiss: handleLiveCameraOutcome) { request in
            CameraView(mode: request.mode) { outcome in
                liveCameraOutcome = outcome
                cameraRequest = nil
            }
        }
        .fullScreenCover(isPresented: $isShowingCamera, onDismiss: handleCameraOutcome) {
            CameraCaptureView { outcome in
                cameraOutcome = outcome
                isShowingCamera = false
            }
            .ignoresSafeArea()
        }
    }

    /// Permission and model alerts, pasteboard watching, load errors and feedback.
    private func alertsAndObservers<Content: View>(_ content: Content) -> some View {
        content
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
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text("PicStrip")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("Share the moment. Not the story behind it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ScannerHeroView()
                        .frame(height: 150)
                        .accessibilityHidden(true)
                    VStack(spacing: 20) {
                        primaryActions
                        importGrid
                    }
                    VStack(spacing: 2) {
                        Button {
                            Task { await viewModel.loadDemo() }
                        } label: {
                            Label("Try a sample", systemImage: "sparkles")
                                .font(.callout.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("tryDemoButton")
                        Text("A fictional photo. No library access needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
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
            // The bar above is transparent; content scrolling under it fades out
            // instead of running into the clock.
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    /// The camera leads — photo, video and document in one — or, without a
    /// camera, the library.
    private var primaryActions: some View {
        VStack(spacing: 6) {
            ForEach(primaryImportActions, id: \.self) { action in
                importButton(action, isRow: true)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
            }
            if primaryImportActions.contains(.camera) {
                Text(DocumentScannerView.isAvailable ? "Photo · Video · Document" : "Photo · Video")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Every other way in, at once: two tiles to a row, or one full-width row
    /// each at accessibility text sizes, where a tile would be too narrow.
    private var importGrid: some View {
        let isCompact = dynamicTypeSize.isAccessibilitySize
        let columns = isCompact ? 1 : 2
        let actions = importActions.filter { !primaryImportActions.contains($0) }
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: actions.count, by: columns)), id: \.self) { start in
                let row = actions[start..<min(start + columns, actions.count)]
                GridRow {
                    ForEach(row, id: \.self) { action in
                        importButton(action, isRow: isCompact)
                            .buttonStyle(.glass)
                            .buttonBorderShape(isCompact ? .capsule : .roundedRectangle(radius: 22))
                            .frame(maxHeight: .infinity)
                            // A last tile on its own takes the whole row.
                            .gridCellColumns(row.count < columns ? columns : 1)
                    }
                }
            }
        }
        // Tiles in a row share its height, but the grid takes only what its
        // tallest tiles need, not the screen's spare height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum ImportAction: Hashable {
        case camera, library, files
    }

    /// The camera (where there is one), the photo library, and Files.  What is
    /// picked decides the flow: see `openLibrarySelection`.
    private var importActions: [ImportAction] {
        (CameraCaptureView.isAvailable ? [.camera] : []) + [.library, .files]
    }

    /// Capturing leads, so it goes straight through PicStrip's camera; without
    /// a camera, the library does.
    private var primaryImportActions: [ImportAction] {
        CameraCaptureView.isAvailable ? [.camera] : [.library]
    }

    /// The button for `action`, unstyled: the caller makes it the prominent
    /// button or a tile.  `isRow` lays the label out as a full-width row.
    @ViewBuilder
    private func importButton(_ action: ImportAction, isRow: Bool) -> some View {
        switch action {
        case .camera:
            Button {
                haptic(.light)
                openCamera { showCamera(.photo) }
            } label: {
                ImportTileLabel(icon: "camera", text: "Camera", isRow: isRow)
            }
            .accessibilityIdentifier("cameraButton")
            .accessibilityLabel(DocumentScannerView.isAvailable
                ? "Camera: take a photo, record a video or scan a document"
                : "Camera: take a photo or record a video")
        case .library:
            // Photos and videos, one or many — Screenshots is one of the
            // picker's own collections.  `.current`: videos as they are stored;
            // the default may convert HEVC to H.264 first, most of the wait when
            // opening a long one.
            PhotosPicker(
                selection: $libraryItems,
                maxSelectionCount: 0,
                selectionBehavior: .ordered,
                matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            ) {
                ImportTileLabel(icon: "photo.on.rectangle.angled", text: "Photos & Videos", isRow: isRow)
            }
            .accessibilityIdentifier("libraryButton")
            .accessibilityLabel("Choose photos or videos from your library")
            .simultaneousGesture(TapGesture().onEnded { haptic(.light) })
        case .files:
            Button {
                haptic(.light)
                isShowingFilePicker = true
            } label: {
                ImportTileLabel(icon: "folder", text: "Browse Files", isRow: isRow)
            }
            .accessibilityIdentifier("browseFilesButton")
            .accessibilityLabel("Browse files for an image or a video")
        }
    }

    /// What was picked in the library, to its flow: one photo to the editor,
    /// one video to the video cleaner, several photos to the batch, and
    /// several videos — or photos and videos together — to one batch for all.
    private func openLibrarySelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        defer { libraryItems = [] }
        let selection = LibrarySelection(items.map { (item: $0, isVideo: Self.isVideo($0)) })
        switch selection.route {
        case .photo(let item):
            viewModel.selectedItem = item
        case .video(let item):
            selectedVideoItem = item
        case .photoBatch(let photos):
            viewModel.batchVideoItems = []
            viewModel.batchItems = photos
        case .mixedBatch(let photos, let videos):
            viewModel.batchVideoItems = videos
            viewModel.batchItems = photos
            viewModel.activeSheet = .batch
        }
    }

    /// A movie, not a photo — a Live Photo carries a movie too, but is a photo.
    private static func isVideo(_ item: PhotosPickerItem) -> Bool {
        let types = item.supportedContentTypes
        return types.contains { $0.conforms(to: .movie) }
            && !types.contains { $0.conforms(to: .image) || $0 == .livePhoto }
    }

    /// A video chosen in Files, copied into the protected store while access lasts.
    private func openVideoFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            importedVideo = try PrivateFileStore.exports.copy(url, extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        } catch {
            viewModel.errorMessage = String(localized: "The selected video could not be opened.")
        }
    }

    /// A video handed over by the Share Extension, already in the protected
    /// store, so it is opened like a video from Files.  If another video is
    /// open, it waits until that sheet has gone (`onDismiss`).
    private func openHandedOffVideo() {
        guard openVideo == nil, let url = intentRouter.requestedVideo else { return }
        intentRouter.videoPresented()
        importedVideo = url
    }

    // MARK: - Drifting gradient

    private var driftingGradient: some View {
        DriftingGradient()
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

    // MARK: - Camera

    /// Runs `present` once the camera may be used, asking for or explaining the
    /// permission first.
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

    private struct CameraRequest: Identifiable {
        let mode: CameraView.Mode
        let id = UUID()
    }

    private func showCamera(_ mode: CameraView.Mode) {
        cameraRequest = CameraRequest(mode: mode)
    }

    private func handleLiveCameraOutcome() {
        defer { liveCameraOutcome = nil }
        switch liveCameraOutcome {
        case .captured(let data):
            // The camera's own bytes: metadata intact, exactly like a library photo.
            Task { await viewModel.loadCaptured(CapturedPages(count: 1) { _ in data }) }
        case .recorded(let url):
            recordedVideo = url
        case .scanned(let document):
            Task { await viewModel.loadCaptured(document.pages) }
        case .scanFailed:
            viewModel.errorMessage = String(localized: "The document could not be scanned.")
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

    /// The photo screen's frame and its window's, in the window's coordinates:
    /// they decide whether the controls go below the photo or beside it.
    @State private var photoFrame: CGRect = .zero
    @State private var photoWindowFrame: CGRect = .zero
    @Environment(\.layoutDirection) private var layoutDirection

    private var photoCanvasLayout: CanvasLayout {
        CanvasLayout.resolve(for: photoFrame.size, isEligible: CanvasLayout.isEligibleDevice)
    }

    /// The photo with its controls below it — or, on a wide display such as
    /// iPhone Duo's inner one, beside it.  One `AnyLayout` for both, so
    /// unfolding or folding the phone keeps the editor as it was: the same
    /// views, rearranged.
    private var photoLayout: some View {
        let isSideBySide = photoCanvasLayout == .sideBySide
        let arrangement = isSideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let columnWidth = CanvasLayout.sideColumnWidth(content: photoFrame, window: photoWindowFrame, layoutDirection: layoutDirection)
        // At accessibility sizes the controls below take what they need, and
        // the photo keeps at least a usable strip of the screen.
        let isLargeText = dynamicTypeSize.isAccessibilitySize
        return arrangement {
            imageDisplay
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: isLargeText ? 220 : nil)
                .background(Color(.secondarySystemBackground))
                .overlay(alignment: .top) {
                    if let confirmation = viewModel.savedConfirmation {
                        SavedConfirmationBanner(confirmation: confirmation) {
                            viewModel.savedConfirmation = nil
                        }
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(confirmation.id)
                    }
                }
                .animation(.spring(duration: 0.35), value: viewModel.savedConfirmation)
                .onChange(of: viewModel.allSourceMetadata?.fields.count) { _, newCount in
                    if newCount == nil {
                        isPanelOpen = false
                        visiblePanelCategory = ""
                    }
                }

            Divider()

            photoControls(isSideBySide: isSideBySide)
                .frame(width: isSideBySide ? columnWidth : nil)
                .frame(maxHeight: isSideBySide ? .infinity : nil, alignment: .top)
                .background(isSideBySide ? Color(.systemBackground) : .clear)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { photoFrame = $0 }
        .background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { photoWindowFrame = $0 }
        }
        .animation(.spring(duration: 0.35, bounce: 0.1), value: isRedactionEditing)
    }

    /// The redaction drawer while editing, the control panel otherwise: below
    /// the photo, or in the column beside it.
    private func photoControls(isSideBySide: Bool) -> some View {
        let edge: Edge = isSideBySide ? .trailing : .bottom
        return VStack(spacing: 0) {
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
                        AccessibilityNotification.Announcement(
                            String(localized: "Region added in the middle of the photo and selected. Use Position & size to move it.")
                        ).post()
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
                        // VoiceOver goes back to where the editor was opened from.
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            isEditRowFocused = true
                        }
                    },
                    onSetPartial: { id, isPartial in viewModel.setPartialCover(id: id, isPartial) },
                    onChangeEmoji: { id, emoji in viewModel.changeRedactionEmoji(id: id, emoji: emoji) },
                    onBulkChangeEmoji: { ids, emoji in viewModel.bulkChangeRedactionEmoji(ids: ids, emoji: emoji) },
                    onApplyToAllFaces: { id in viewModel.applyStyleToAllFaces(from: id) },
                    onAlwaysCover: { term in viewModel.alwaysCover(term) },
                    // Beside the photo, the list of regions takes the column's height.
                    regionListMaxHeight: isSideBySide ? .infinity : 160
                )
                .background(Color(.systemBackground))
                .layoutPriority(isLargeText ? 1 : 0)
                .transition(.asymmetric(
                    insertion: .move(edge: edge).combined(with: .opacity),
                    removal: .move(edge: edge).combined(with: .opacity)
                ))
            } else {
                controlPanel
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .scrollsAtAccessibilitySizes()
                    .background(Color(.systemBackground))
                    .layoutPriority(isLargeText ? 1 : 0)
                    .transition(.asymmetric(
                        insertion: .move(edge: edge).combined(with: .opacity),
                        removal: .move(edge: edge).combined(with: .opacity)
                    ))
            }
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

                // Category detail panel — there only while open, so a closed
                // panel leaves nothing behind for VoiceOver to land on.
                if let metadata = viewModel.allSourceMetadata,
                   !metadata.isEmpty,
                   hasPhoto, isPanelOpen {
                    let fields = metadata.fields.filter { $0.category == visiblePanelCategory }

                    CategoryDetailPanel(
                        category: visiblePanelCategory,
                        fields: fields,
                        stripConfig: $viewModel.stripConfig,
                        onDismiss: closePanel
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.offset(y: geo.size.height).combined(with: .opacity))
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
                AccessibilityStack {
                    Menu {
                        Picker("Sharing as", selection: Binding(
                            get: { viewModel.sharingPurpose },
                            set: { viewModel.applySharingPurpose($0) }
                        )) {
                            ForEach(SharingPurpose.allCases) { purpose in
                                Label {
                                    Text(purpose.title)
                                    Text(purpose.summary)
                                } icon: {
                                    Image(systemName: purpose.symbolName)
                                }
                                .tag(purpose)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Label(viewModel.sharingPurpose.title, systemImage: viewModel.sharingPurpose.symbolName)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                        // A full-height target over a caption-sized row: the
                        // padding is taken back outside, so the row keeps its height.
                        .padding(.vertical, 15)
                        .contentShape(Rectangle())
                    }
                    .padding(.vertical, -15)
                    .accessibilityLabel("Sharing preset")
                    .accessibilityValue(viewModel.sharingPurpose.title)
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
                AccessibilityStack {
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
        .onChange(of: viewModel.isScanningPII) { wasScanning, isScanning in
            if wasScanning, !isScanning, hasPhoto { announceScanResult() }
        }
    }

    /// VoiceOver hears that the scan is over and what it found: the screen
    /// changes under the user's finger without moving focus.
    private func announceScanResult() {
        let covered = viewModel.enabledRedactionRegions.count
        let message: String
        if viewModel.scanCoverage.requiresManualReview {
            message = String(localized: "Some checks could not finish")
        } else if covered > 0 {
            // Through `AttributedString`, which applies the English inflection.
            message = String(AttributedString(localized: "Scan finished. ^[\(covered) region](inflect: true) covered.").characters)
        } else {
            message = String(localized: "Scan finished. Nothing found to cover.")
        }
        AccessibilityNotification.Announcement(message).post()
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
            AccessibilityStack(spacing: 10) {
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
        .accessibilityFocused($isEditRowFocused)
    }

}

// MARK: - Drifting gradient

/// Decorative home-screen background: a faint mesh of the brand's green and
/// indigo over the system background.  Its points drift on slow, unrelated
/// periods, so the light seems to move and never visibly repeats; the middle
/// stays clear, so the text over it stays crisp.
///
/// The points are worked out from the clock, fifteen times a second: they move
/// a point or two a frame at most, far too slowly to need the display's full
/// rate, at which a repeating animation would redraw the whole home screen for
/// as long as it is open.  It also keeps the animation out of every other
/// transaction — a global `withAnimation(….repeatForever())` here once made the
/// home-screen buttons' glass backgrounds grow and shrink forever.  The clock
/// stops while the scene is not active, and under Reduce Motion, which shows
/// the mesh at rest.
private struct DriftingGradient: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotionSetting
    @Environment(\.scenePhase) private var scenePhase

    private var reduceMotion: Bool { reduceMotionSetting || DecorativeMotion.isHostingTests }

    /// Row by row from the top-left: green at the top-left, indigo toward the
    /// bottom-right, nothing in the middle.
    private static let colors: [Color] = [
        Color.accentColor.opacity(0.24), Color.accentColor.opacity(0.10), Color.indigo.opacity(0.10),
        Color.teal.opacity(0.08), Color.accentColor.opacity(0), Color.indigo.opacity(0.06),
        Color.accentColor.opacity(0.06), Color.indigo.opacity(0.08), Color.indigo.opacity(0.18)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || scenePhase != .active)) { context in
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.points(at: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate),
                colors: Self.colors,
                colorSpace: .perceptual
            )
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea()
        .accessibilityHidden(true) // decorative background
    }

    /// The mesh's points at `time`: the corners stay put, the edge midpoints
    /// slide along their edges and the centre wanders.  Periods of 23–43 s.
    private static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        func drift(_ amplitude: Float, _ period: Double, _ phase: Double) -> Float {
            amplitude * Float(sin(time * 2 * .pi / period + phase))
        }
        let top = SIMD2<Float>(0.5 + drift(0.15, 29, 0), 0)
        let left = SIMD2<Float>(0, 0.45 + drift(0.12, 37, 1))
        let center = SIMD2<Float>(0.5 + drift(0.2, 23, 2), 0.5 + drift(0.15, 31, 3))
        let right = SIMD2<Float>(1, 0.55 + drift(0.12, 41, 4))
        let bottom = SIMD2<Float>(0.5 + drift(0.15, 43, 5), 1)
        return [
            SIMD2(0, 0), top, SIMD2(1, 0),
            left, center, right,
            SIMD2(0, 1), bottom, SIMD2(1, 1)
        ]
    }
}

// MARK: - Import tile label

/// An import action's icon and name: stacked in a tile of the home screen's
/// grid, or side by side in a full-width row at accessibility text sizes.
///
/// `nonisolated` for the same reason as `PillLabel`: `PhotosPicker` builds its
/// label in a nonisolated closure.
nonisolated private struct ImportTileLabel: View {
    let icon: String
    let text: LocalizedStringKey
    let isRow: Bool

    var body: some View {
        if isRow {
            PillLabel(icon: icon, text: text)
        } else {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Saved confirmation

/// Shown over the editor once a cleaned copy is in Photos: what went, in a few
/// lines, then gone by itself.
private struct SavedConfirmationBanner: View {
    let confirmation: ScrubberViewModel.SavedConfirmation
    let onDismiss: () -> Void

    var body: some View {
        let summary = confirmation.summary
        VStack(alignment: .leading, spacing: 6) {
            Label(confirmation.replacedOriginal ? "Original replaced in Photos" : "Saved to Photos", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                if summary.locationRemoved {
                    Label("Location removed", systemImage: "location.slash")
                }
                if summary.metadataFieldsRemoved > 0 {
                    Label("^[\(summary.metadataFieldsRemoved) privacy field](inflect: true) stripped", systemImage: "tag.slash")
                }
                if summary.detailsCovered > 0 {
                    Label("Details covered: \(summary.detailsCovered)", systemImage: "eye.slash")
                }
                Label("Processed on your device", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("savedConfirmation")
        .accessibilityAction(named: "Dismiss", onDismiss)
        .onTapGesture(perform: onDismiss)
        .sensoryFeedback(.success, trigger: confirmation.id)
        .task(id: confirmation.id) {
            AccessibilityNotification.Announcement(
                confirmation.replacedOriginal
                    ? String(localized: "Original replaced in Photos")
                    : String(localized: "Saved to Photos")
            ).post()
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            onDismiss()
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
            // Wraps, rather than truncating, when large text outgrows the capsule.
            Text(text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
