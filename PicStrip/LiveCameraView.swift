import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - LiveCameraView

/// A viewfinder that shows, live, what PicStrip reads and what it would redact —
/// then hands the photo straight to the editor, where the real scan runs at full
/// accuracy.
struct LiveCameraView: View {

    enum Outcome {
        case captured(Data)
        /// A video recorded in Video mode, in PicStrip's protected temporary store.
        case recorded(URL)
        /// Pages from Document mode, Apple's document scanner.
        case scanned(ScannedDocument)
        /// The document scanner could not finish.
        case scanFailed
        case cancelled
        /// The capture session could not be set up; the caller falls back to the system camera.
        case unavailable
    }

    /// Photo or Video, when this is the camera's Photo mode.
    var mode: Binding<CameraView.Mode>?
    let onFinish: (Outcome) -> Void

    @State private var model = LiveCameraModel()
    /// Black bars where the redactions would go, instead of labelled outlines.
    /// Not remembered: PicStrip keeps no preferences (see PrivacyInfo.xcprivacy).
    @State private var showsRedactionPreview = false
    @State private var isShowingGuide = true
    @State private var isFlashing = false
    @State private var shutterCount = 0
    @State private var announcedTypes: [PIIType] = []
    /// Where the glass controls are, in global coordinates, so labels stay clear of them.
    @State private var controlFrames: [Int: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraFrameLayout(aspect: pictureAspect, controlsHidden: model.areControlsHidden) {
                topBar
            } viewfinder: {
                viewfinder
            } inPicture: {
                inPicture
            } bottom: {
                bottomBar
            }
        }
        .statusBarHidden()
        // The volume buttons and Camera Control take the photo, as in the Camera app.
        .onCameraCaptureEvent(isEnabled: canCapture) { event in
            if event.phase == .ended { takePhoto() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shutterCount)
        // VoiceOver's two-finger double tap takes the photo, as in the Camera app.
        .accessibilityAction(.magicTap) { takePhoto() }
        .task {
            await model.start()
            if model.state == .unavailable { onFinish(.unavailable) }
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            isShowingGuide = false
        }
        .onChange(of: model.summary.types) { _, types in announce(types) }
        .onDisappear { model.stop() }
    }

    private var canCapture: Bool {
        model.state == .running && !model.isCapturing
    }

    // MARK: Viewfinder

    /// Focus, zoom and exposure, for the gestures and for VoiceOver alike.
    private var adjustments: ViewfinderAdjustments {
        ViewfinderAdjustments(
            focus: { model.focus(at: $0) },
            pinch: { model.pinch($0) },
            endPinch: { model.endPinch() },
            exposure: { model.adjustExposure(by: $0) },
            endExposure: { model.endExposureAdjustment() }
        )
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            let videoRect = LiveOverlayGeometry.videoRect(videoSize: model.videoSize, in: geo.size)
            let safeBounds = CGRect(origin: .zero, size: geo.size)
            let origin = geo.frame(in: .global).origin
            let textLines = model.textLines.map(model.displayBox)
            ZStack(alignment: .topLeading) {
                if let fixture = model.fixture {
                    Image(decorative: fixture.image, scale: 1)
                        .resizable()
                        .frame(width: videoRect.width, height: videoRect.height)
                        .offset(x: videoRect.minX, y: videoRect.minY)
                } else {
                    CameraPreview(layer: model.previewLayer)
                }

                if !showsRedactionPreview {
                    LiveReadingLayer(lines: textLines, videoRect: videoRect)
                }

                LiveDetectionLayer(
                    tracks: model.tracks,
                    motionOffset: model.motionOffset,
                    videoRect: videoRect,
                    labelBounds: safeBounds.intersection(videoRect),
                    obstacles: controlFrames.values.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) },
                    textLines: textLines.map { LiveOverlayGeometry.rect(for: $0, in: videoRect) },
                    showsRedactionPreview: showsRedactionPreview,
                    reduceMotion: reduceMotion
                )

                if let point = model.focusPoint {
                    FocusReticle(reduceMotion: reduceMotion)
                        .position(point)
                        .id("\(point.x),\(point.y)")
                    ExposureIndicator(bias: model.exposureBias)
                        .position(x: min(point.x + 52, geo.size.width - 20), y: point.y)
                }

                Color.white
                    .opacity(isFlashing ? 0.6 : 0)
                    .animation(.easeOut(duration: 0.25), value: isFlashing)
                    .allowsHitTesting(false)
            }
            // Vision/video rectangles use pixel coordinates, not reading order.
            .environment(\.layoutDirection, .leftToRight)
            .cameraGestures(adjustments)
            .viewfinderAccessibility(
                adjustments,
                zoom: model.zoomLevel,
                center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2),
                isFocused: model.focusPoint != nil
            )
        }
    }

    /// The frames' shape once they arrive; a phone camera's 4:3 until then.
    private func pictureAspect(for size: CGSize) -> CGFloat? {
        if model.videoSize.width > 0, model.videoSize.height > 0 {
            return model.videoSize.width / model.videoSize.height
        }
        return size.height > size.width ? 3 / 4 : 4 / 3
    }

    // MARK: Controls

    /// Above the picture: close, the flashlight and the redaction preview.
    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                closeButton
                Spacer()
                if model.capabilities.hasTorch { torchToggle }
                previewToggle
            }
            .frame(height: 44)
        }
        .cameraChrome()
    }

    /// On the picture, inside its edges: the guide at the top; what is in
    /// view and the lens buttons at the bottom.
    private var inPicture: some View {
        VStack(spacing: 12) {
            if isShowingGuide {
                Text("Live preview is a guide. After capture, review the full scan and choose what to cover.")
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(in: .rect(cornerRadius: 16))
                    .cameraNote()
                    .transition(.opacity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlFrames[0] = $0 }
            }

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 12) {
                    LiveStatusView(
                        state: model.state,
                        isAnalysisPaused: model.isAnalysisPaused,
                        hasScanned: model.hasScanned,
                        summary: model.summary
                    )
                    if model.capabilities.zoomLevels.count > 1 {
                        CameraZoomButtons(levels: model.capabilities.zoomLevels, zoom: model.zoomLevel) { model.setZoom($0) }
                            .disabled(model.state != .running)
                    }
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: model.summary)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlFrames[1] = $0 }
        }
        .animation(.easeInOut(duration: 0.3), value: isShowingGuide)
        .onChange(of: isShowingGuide) { _, isShowing in
            if !isShowing { controlFrames[0] = nil }
        }
    }

    /// Below the picture: the mode, and the shutter with the camera switch.
    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let mode {
                CameraModePicker(mode: mode) { model.stop() }
                    .opacity(model.isCapturing ? 0 : 1)
                    .allowsHitTesting(!model.isCapturing)
            }
            HStack {
                Color.clear.frame(width: 60, height: 44)
                Spacer()
                shutterButton
                Spacer()
                Group {
                    if model.capabilities.canFlip {
                        CameraFlipButton(position: model.capabilities.position) { model.flip() }
                            .disabled(model.state != .running || model.isCapturing)
                            .accessibilityIdentifier("liveCameraFlipButton")
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
                .frame(width: 60)
            }
        }
    }

    private var closeButton: some View {
        Button {
            onFinish(.cancelled)
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Close camera")
        .accessibilityIdentifier("liveCameraCloseButton")
        .largeContent()
    }

    private var torchToggle: some View {
        Toggle(isOn: Binding(get: { model.isTorchOn }, set: { model.setTorch($0) })) {
            Label("Flashlight", systemImage: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                .font(.subheadline.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .foregroundStyle(model.isTorchOn ? .yellow : .primary)
        .disabled(model.state != .running)
        .accessibilityIdentifier("liveCameraTorchToggle")
        .largeContent()
    }

    private var previewToggle: some View {
        Toggle(isOn: $showsRedactionPreview) {
            Label("Preview redactions", systemImage: showsRedactionPreview ? "rectangle.inset.filled" : "rectangle.dashed")
                .font(.subheadline.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityIdentifier("liveCameraPreviewToggle")
        .largeContent()
    }

    private var shutterButton: some View {
        Button {
            takePhoto()
        } label: {
            ZStack {
                Circle().fill(.white).frame(width: 66, height: 66)
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 80, height: 80)
            }
            .scaleEffect(model.isCapturing ? 0.9 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: model.isCapturing)
        }
        .buttonStyle(.plain)
        .disabled(!canCapture)
        .opacity(model.state == .running ? 1 : 0.4)
        .accessibilityLabel("Take Photo")
        .accessibilityIdentifier("liveCameraShutterButton")
    }

    // MARK: Actions

    private func takePhoto() {
        guard canCapture else { return }
        shutterCount += 1
        isFlashing = true
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            isFlashing = false
        }
        Task {
            if let data = await model.capture() { onFinish(.captured(data)) }
        }
    }

    /// VoiceOver hears about a kind of finding when it comes into view, not on
    /// every pass that sees it again.
    private func announce(_ types: [PIIType]) {
        defer { announcedTypes = types }
        guard voiceOverEnabled, !types.isEmpty,
              types.contains(where: { !announcedTypes.contains($0) })
        else { return }
        AccessibilityNotification.Announcement(LiveStatusView.foundDescription(of: types)).post()
    }
}

// MARK: - LiveStatusView

/// The line above the shutter: what the viewfinder is doing, or what is in view.
private struct LiveStatusView: View {
    let state: LiveCameraModel.State
    let isAnalysisPaused: Bool
    let hasScanned: Bool
    let summary: LiveScanSummary

    /// Kinds of finding shown as symbols before the rest are counted.
    private static let maximumSymbols = 5

    var body: some View {
        content
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(in: .capsule)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Live preview is a guide. After capture, review the full scan and choose what to cover.")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("liveCameraStatus")
            .opacity(state == .starting ? 0 : 1)
            .cameraNote()
    }

    @ViewBuilder
    private var content: some View {
        if state == .interrupted {
            Label("Camera paused", systemImage: "pause.circle.fill")
        } else if isAnalysisPaused {
            Label("Live scan paused while the device cools", systemImage: "thermometer.high")
        } else if summary.isEmpty {
            Label {
                Text("Looking for sensitive details…")
            } icon: {
                Image(systemName: "text.viewfinder")
                    .symbolEffect(.pulse, isActive: state == .running)
            }
            .foregroundStyle(hasScanned ? .primary : .secondary)
        } else {
            HStack(spacing: 8) {
                if let risk = summary.highestRisk {
                    Image(systemName: risk.symbolName)
                        .foregroundStyle(risk.color)
                }
                Text("Sensitive details in view")
                HStack(spacing: 6) {
                    ForEach(summary.entries.prefix(Self.maximumSymbols), id: \.type) { entry in
                        HStack(spacing: 2) {
                            Image(systemName: entry.type.symbolName)
                                .foregroundStyle(entry.type.riskLevel.color)
                            if entry.count > 1 {
                                Text(entry.count, format: .number)
                                    .font(.caption2.weight(.bold))
                                    .monospacedDigit()
                            }
                        }
                    }
                    if summary.entries.count > Self.maximumSymbols {
                        Text(verbatim: "+" + (summary.entries.count - Self.maximumSymbols).formatted())
                            .font(.caption2.weight(.bold))
                    }
                }
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.foundDescription(of: summary.types))
        }
    }

    static func foundDescription(of types: [PIIType]) -> String {
        let names = types.map(\.description).formatted(.list(type: .and))
        return String(localized: "Sensitive details in view: \(names)")
    }
}

// MARK: - LiveReadingLayer

/// A hairline around every line of text the viewfinder can read — what it sees,
/// sensitive or not.
private struct LiveReadingLayer: View {
    let lines: [CGRect]
    let videoRect: CGRect

    var body: some View {
        ReadingLines(lines: lines.map { LiveOverlayGeometry.rect(for: $0, in: videoRect) })
    }
}

// MARK: - LiveDetectionLayer

/// The findings: outlined in their risk colour and labelled, or — as a preview
/// of the result — blacked out.
private struct LiveDetectionLayer: View {
    let tracks: [LiveTrack]
    let motionOffset: CGVector
    let videoRect: CGRect
    /// Where labels may go: on the video, clear of the screen's edges.
    let labelBounds: CGRect
    /// The controls over the video, in view points.
    let obstacles: [CGRect]
    /// The lines of text read, in view points; labels avoid them where they can.
    let textLines: [CGRect]
    let showsRedactionPreview: Bool
    let reduceMotion: Bool

    var body: some View {
        let placed = placedTracks
        let placements = showsRedactionPreview ? [:] : LiveLabelLayout.place(
            placed.map { LiveLabelLayout.Item(id: $0.track.id, box: $0.rect, labelSize: LiveDetectionLabel.size(for: $0.track.type, confidence: $0.track.confidence)) },
            in: labelBounds,
            avoiding: obstacles,
            textLines: textLines
        )
        ZStack(alignment: .topLeading) {
            ForEach(placed, id: \.track.id) { item in
                box(for: item.track, in: item.rect)
            }
            if !showsRedactionPreview {
                ForEach(placed, id: \.track.id) { item in
                    label(for: item.track, in: item.rect, placement: placements[item.track.id] ?? .badge)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: tracks)
        .animation(reduceMotion ? nil : .linear(duration: 1.0 / 15), value: motionOffset)
    }

    /// Tracks with their rect in view points, most important first, so they get
    /// the labels when there is not room for all.
    private var placedTracks: [(track: LiveTrack, rect: CGRect)] {
        tracks
            .sorted {
                if $0.type.riskLevel != $1.type.riskLevel { return $0.type.riskLevel > $1.type.riskLevel }
                return $0.id < $1.id
            }
            .map { track in
                let box = track.box.offsetBy(dx: motionOffset.dx, dy: motionOffset.dy)
                return (track, LiveOverlayGeometry.rect(for: box, in: videoRect).insetBy(dx: -3, dy: -3))
            }
    }

    @ViewBuilder
    private func box(for track: LiveTrack, in rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Group {
            if showsRedactionPreview {
                shape.fill(.black.opacity(0.9))
            } else {
                DetectionBox(type: track.type, confidence: track.confidence)
            }
        }
        // A finding that dropped out of the last pass fades until it comes back or goes.
        .opacity(track.missedPasses == 0 ? 1 : 0.45)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .transition(reduceMotion ? .opacity : .scale(scale: 1.15).combined(with: .opacity))
    }

    @ViewBuilder
    private func label(for track: LiveTrack, in rect: CGRect, placement: LiveLabelLayout.Placement) -> some View {
        Group {
            switch placement {
            case .label(let frame):
                LiveDetectionLabel(type: track.type, confidence: track.confidence)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            case .badge:
                DetectionBadge(type: track.type)
                    .position(x: rect.minX, y: rect.minY)
            }
        }
        .opacity(track.missedPasses == 0 ? 1 : 0.45)
        .transition(.opacity)
    }
}

// MARK: - LiveDetectionLabel

/// A finding's kind and match strength, in its risk colour.  Sized ahead of
/// layout so labels can be kept from covering each other.
///
/// Match strength, not a percentage: like the editor, the viewfinder never
/// presents the heuristic score as a probability (see "Match strength" in About).
private struct LiveDetectionLabel: View {
    let type: PIIType
    let confidence: ConfidenceLevel

    /// Long names ("Physical Credential / Password") are cut short rather than
    /// covering the picture; the match strength never is.
    private static let maximumWidth: CGFloat = 240
    private static let horizontalPadding: CGFloat = 7
    private static let verticalPadding: CGFloat = 3
    private static let spacing: CGFloat = 4
    private static let dividerWidth: CGFloat = 1

    /// Follows Dynamic Type, up to a size that still leaves the picture visible.
    private static var font: UIFont { scaledFont(weight: .semibold) }
    private static var strengthFont: UIFont { scaledFont(weight: .regular) }

    private static func scaledFont(weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: weight), maximumPointSize: 18)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: type.symbolName)
            Text(type.description)
                .lineLimit(1)
                .truncationMode(.tail)
            Rectangle()
                .fill(.white.opacity(0.5))
                .frame(width: Self.dividerWidth)
                .padding(.vertical, Self.verticalPadding + 1)
            Text(confidence.matchLabel)
                .font(Font(Self.strengthFont))
                .opacity(0.9)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .font(Font(Self.font))
        .foregroundStyle(.white)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(type.riskLevel.color.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    static func size(for type: PIIType, confidence: ConfidenceLevel) -> CGSize {
        let font = Self.font
        let name = (type.description as NSString).size(withAttributes: [.font: font])
        let strength = (confidence.matchLabel as NSString).size(withAttributes: [.font: strengthFont])
        let symbol = UIImage(systemName: type.symbolName, withConfiguration: UIImage.SymbolConfiguration(font: font))
        // A point of slack each side: SwiftUI rounds text and symbol widths up.
        let width = ceil(symbol?.size.width ?? font.lineHeight) + ceil(name.width) + dividerWidth + ceil(strength.width)
            + spacing * 3 + horizontalPadding * 2 + 2
        return CGSize(width: min(width, maximumWidth), height: ceil(font.lineHeight) + verticalPadding * 2)
    }
}

// MARK: - FocusReticle

/// The Camera app's yellow square where the user tapped to focus.
struct FocusReticle: View {
    let reduceMotion: Bool
    @State private var isSettled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .animation(.snappy(duration: 0.25)) {
                $0.scaleEffect(isSettled || reduceMotion ? 1 : 1.35)
                    .opacity(isSettled ? 0.7 : 1)
            }
            .onAppear { isSettled = true }
            .allowsHitTesting(false)
    }
}

// MARK: - CameraPreview

struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewHostView {
        PreviewHostView(previewLayer: layer)
    }

    func updateUIView(_ view: PreviewHostView, context: Context) { }

    final class PreviewHostView: UIView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}
