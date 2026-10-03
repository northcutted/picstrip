import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - CameraView

/// PicStrip's camera: Photo mode is the live viewfinder that shows what would
/// be redacted, Video mode records at the Camera app's quality.  Either hands
/// what it captured straight to its editor.
struct CameraView: View {

    enum Mode: String, CaseIterable, Identifiable {
        case video, photo

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .video: "Video"
            case .photo: "Photo"
            }
        }
    }

    let onFinish: (LiveCameraView.Outcome) -> Void
    @State private var mode: Mode

    init(mode: Mode, onFinish: @escaping (LiveCameraView.Outcome) -> Void) {
        _mode = State(initialValue: mode)
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch mode {
            case .photo:
                LiveCameraView(mode: $mode, onFinish: onFinish)
                    .transition(.opacity)
            case .video:
                VideoCameraView(mode: $mode, onFinish: onFinish)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
    }
}

// MARK: - CameraModePicker

/// Video or Photo, as in the Camera app, just above the shutter.
struct CameraModePicker: View {
    @Binding var mode: CameraView.Mode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CameraView.Mode.allCases) { option in
                let isSelected = option == mode
                Button {
                    mode = option
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? .yellow : .primary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("cameraMode-\(option.rawValue)")
            }
        }
        .padding(3)
        .glassEffect(in: .capsule)
        .sensoryFeedback(.selection, trigger: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera mode")
    }
}

// MARK: - VideoCameraView

/// Records video at the quality the Camera app would — 4K or HD, 24 to 120
/// fps, HDR, enhanced stabilisation — with its controls: lens buttons and
/// pinch to zoom, tap to focus and drag for exposure, the torch, the front
/// camera, and the volume buttons or Camera Control to start and stop.  The
/// recording opens in the video editor; it is never saved as it is.
struct VideoCameraView: View {
    @Binding var mode: CameraView.Mode
    let onFinish: (LiveCameraView.Outcome) -> Void

    @State private var model = VideoCameraModel()
    @State private var isShowingMicrophoneInfo = false
    @State private var recordToggles = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            preview
            if !model.areControlsHidden {
                controls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.areControlsHidden)
        .statusBarHidden()
        // The volume buttons and Camera Control start and stop recording, as in the Camera app.
        .onCameraCaptureEvent(isEnabled: model.state == .running && !model.isFinishing) { event in
            if event.phase == .ended { toggleRecording() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: recordToggles)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.recording) { _, recording in
            if let recording { onFinish(.recorded(recording)) }
        }
        .alert("Couldn’t Record", isPresented: Binding(
            get: { model.recordingFailed },
            set: { if !$0 { model.dismissFailure() } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The video could not be recorded. Check that there is enough storage, then try again.")
        }
        .alert("Recording Without Sound", isPresented: $isShowingMicrophoneInfo) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("PicStrip isn’t allowed to use the microphone, so videos are recorded without sound. You can allow it in Settings.")
        }
    }

    private func toggleRecording() {
        guard model.state == .running, !model.isFinishing else { return }
        recordToggles += 1
        model.toggleRecording()
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let fixture = model.fixture {
                    Image(decorative: fixture.still, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    CameraPreview(layer: model.previewLayer)
                }
                if let point = model.focusPoint {
                    FocusReticle(reduceMotion: reduceMotion)
                        .position(point)
                        .id("\(point.x),\(point.y)")
                    exposureIndicator
                        .position(x: min(point.x + 52, geometry.size.width - 20), y: point.y)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in model.focus(at: location) }
            .gesture(
                MagnifyGesture()
                    .onChanged { model.pinch($0.magnification) }
                    .onEnded { _ in model.endPinch() }
            )
            .simultaneousGesture(
                // Up or down after focusing, as in the Camera app: brighter or darker.
                DragGesture(minimumDistance: 12)
                    .onChanged { drag in
                        guard abs(drag.translation.height) > abs(drag.translation.width) else { return }
                        model.adjustExposure(by: Float(-drag.translation.height / 120))
                    }
                    .onEnded { _ in model.endExposureAdjustment() }
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var exposureIndicator: some View {
        VStack(spacing: 2) {
            Image(systemName: "sun.max.fill")
                .font(.body.weight(.semibold))
            if model.exposureBias != 0 {
                Text(model.exposureBias, format: .number.precision(.fractionLength(1)).sign(strategy: .always()))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.yellow)
        .shadow(radius: 2)
        .allowsHitTesting(false)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 10) {
                if model.isRecording {
                    // The time in the middle, as in the Camera app; the torch stays at hand.
                    RecordingTimer(started: model.recordingStarted ?? .now)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            if model.setup.hasTorch { torchToggle }
                        }
                } else {
                    HStack(spacing: 10) {
                        closeButton
                        Spacer()
                        if model.setup.hasTorch { torchToggle }
                        stabilizationToggle
                        hdrToggle
                        qualityButtons
                    }
                }
            }

            statusNote

            Spacer()

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 12) {
                    if model.setup.zoomLevels.count > 1 { zoomButtons }
                    if !model.isRecording { CameraModePicker(mode: $mode) }
                }
            }

            HStack {
                microphoneButton
                    .frame(width: 60)
                Spacer()
                recordButton
                Spacer()
                flipButton
                    .frame(width: 60)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .disabled(model.state == .starting)
    }

    @ViewBuilder
    private var statusNote: some View {
        let note: LocalizedStringKey? = switch model.state {
        case .unavailable: "The camera isn’t available right now."
        case .interrupted: "The camera is in use by another app."
        case .starting, .running: model.isHot ? "The camera is running warm. Recording may drop to 30 fps while it cools." : nil
        }
        if let note {
            Text(note)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(in: .rect(cornerRadius: 16))
                .accessibilityIdentifier("videoCameraStatus")
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
        .accessibilityIdentifier("videoTorchToggle")
    }

    private var stabilizationToggle: some View {
        let isOn = model.setup.quality.isEnhancedStabilization
        return Button {
            model.toggleStabilization()
        } label: {
            Image(systemName: "figure.run")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? .yellow : .primary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!model.canChangeSettings || !(isOn || model.canUseEnhancedStabilization))
        .accessibilityLabel("Enhanced stabilization")
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityHint("Steadier video when you walk or run, with a slightly narrower view.")
        .accessibilityIdentifier("videoStabilizationToggle")
    }

    private var hdrToggle: some View {
        let isOn = model.setup.quality.isHDR
        return Button {
            model.toggleHDR()
        } label: {
            Text(verbatim: "HDR")
                .font(.caption.weight(.heavy))
                .strikethrough(!isOn)
                .foregroundStyle(isOn ? .yellow : .primary)
                .frame(width: 30, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .disabled(!model.canChangeSettings || !(isOn || model.canUseHDR))
        .accessibilityLabel("HDR video")
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityIdentifier("videoHDRToggle")
    }

    /// "4K · 30": tap the resolution or the frame rate to change it, as in the Camera app.
    private var qualityButtons: some View {
        HStack(spacing: 0) {
            Button {
                model.toggleResolution()
            } label: {
                Text(verbatim: model.setup.quality.resolution.label)
                    .frame(minWidth: 26)
            }
            .disabled(!model.canChangeSettings || !model.canChangeResolution)
            .accessibilityLabel("Resolution")
            .accessibilityValue(Text(verbatim: model.setup.quality.resolution.label))
            .accessibilityIdentifier("videoResolutionButton")
            Text(verbatim: "·")
                .accessibilityHidden(true)
            Button {
                model.cycleFrameRate()
            } label: {
                Text(verbatim: "\(model.setup.quality.frameRate)")
                    .monospacedDigit()
                    .frame(minWidth: 26)
            }
            .disabled(!model.canChangeSettings || !model.canChangeFrameRate)
            .accessibilityLabel("Frame rate")
            .accessibilityValue(Text("\(model.setup.quality.frameRate) frames per second"))
            .accessibilityIdentifier("videoFrameRateButton")
        }
        .font(.caption.weight(.heavy))
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var zoomButtons: some View {
        let levels = model.setup.zoomLevels
        // The lens in use: the last one at or below the zoom.
        let current = levels.last { $0 <= model.zoomLevel + 0.01 } ?? levels.first
        return HStack(spacing: 6) {
            ForEach(levels, id: \.self) { level in
                let isCurrent = level == current
                Button {
                    model.setZoom(level)
                } label: {
                    Text(verbatim: isCurrent ? Self.zoomLabel(model.zoomLevel, suffix: true) : Self.zoomLabel(level, suffix: false))
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? .yellow : .primary)
                        .frame(width: 34, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Zoom")
                .accessibilityValue(Text(verbatim: Self.zoomLabel(level, suffix: true)))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .disabled(model.state != .running)
    }

    /// "1×", "1.6×"; ".5" and "2" on the lenses not in use, as in the Camera app.
    static func zoomLabel(_ level: CGFloat, suffix: Bool) -> String {
        let text = Double(level).formatted(.number.precision(.fractionLength(0...1)))
        let short = level < 1 && text.hasPrefix("0") ? String(text.dropFirst()) : text
        return suffix ? text + "×" : short
    }

    private var recordButton: some View {
        Button {
            toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 80, height: 80)
                RoundedRectangle(cornerRadius: model.isRecording ? 8 : 33)
                    .fill(.red)
                    .frame(width: model.isRecording ? 32 : 66, height: model.isRecording ? 32 : 66)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.isRecording)
            }
            // The whole button stops a recording, not just the small square in it.
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.state != .running || model.isFinishing)
        .opacity(model.state == .running ? 1 : 0.4)
        .accessibilityLabel(model.isRecording ? Text("Stop Recording") : Text("Record Video"))
        .accessibilityIdentifier("videoRecordButton")
    }

    @ViewBuilder
    private var flipButton: some View {
        if model.setup.canFlip, !model.isRecording {
            Button {
                model.flip()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!model.canChangeSettings)
            .accessibilityLabel(model.setup.position == .back ? Text("Switch to the front camera") : Text("Switch to the back camera"))
            .accessibilityIdentifier("videoFlipButton")
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var microphoneButton: some View {
        if model.isMicrophoneDenied {
            Button {
                isShowingMicrophoneInfo = true
            } label: {
                Image(systemName: "mic.slash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Recording without sound")
            .accessibilityIdentifier("videoMicrophoneOffButton")
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }
}

// MARK: - RecordingTimer

/// The red time of the recording under way, as in the Camera app.
private struct RecordingTimer: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(started))
            HStack(spacing: 6) {
                Circle().fill(.white).frame(width: 7, height: 7)
                Text(Duration.seconds(elapsed.rounded(.down)).formatted(.time(pattern: elapsed >= 3_600 ? .hourMinuteSecond : .minuteSecond)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.red, in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording")
        .accessibilityIdentifier("videoRecordingTimer")
    }
}
