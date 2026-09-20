@preconcurrency import AVFoundation
import SwiftUI
import UIKit

// MARK: - Pure helpers

/// Lets at most one frame be analysed at a time, and no more often than
/// `minimumInterval` — Vision on every frame would cook the phone for boxes
/// nobody can read that fast.
nonisolated struct AnalysisThrottle {
    let minimumInterval: TimeInterval
    private(set) var isBusy = false
    private var lastStart: TimeInterval = -.infinity

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// `true` when a frame arriving at `now` should be analysed; marks it started.
    mutating func begin(at now: TimeInterval) -> Bool {
        guard !isBusy, now - lastStart >= minimumInterval else { return false }
        isBusy = true
        lastStart = now
        return true
    }

    mutating func end() {
        isBusy = false
    }
}

nonisolated enum LiveOverlayGeometry {

    /// Where an aspect-fit video of `videoSize` sits inside `bounds`.
    static func videoRect(videoSize: CGSize, in bounds: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// A normalised, top-left-origin box placed inside `videoRect`.
    static func rect(for box: CGRect, in videoRect: CGRect) -> CGRect {
        CGRect(
            x: videoRect.minX + box.minX * videoRect.width,
            y: videoRect.minY + box.minY * videoRect.height,
            width: box.width * videoRect.width,
            height: box.height * videoRect.height
        )
    }
}

// MARK: - CameraSession

/// The capture session behind the live viewfinder.
///
/// Frames are analysed in memory for the advisory boxes and dropped; nothing
/// but the photo the user takes ever leaves this class, and that goes straight
/// to the editor — never to the photo library.
///
/// Thread confinement instead of an actor, because AVFoundation calls back on
/// queues of its own choosing: session work on `sessionQueue`, frame work on
/// `videoQueue`, and the two never touch each other's state.
nonisolated final class CameraSession: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {

    enum SetupError: Error { case noCamera, cannotConfigure }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.northcutt.PicStrip.camera.session")
    private let videoQueue = DispatchQueue(label: "com.northcutt.PicStrip.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    // sessionQueue
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    private var photoContinuation: CheckedContinuation<Data?, Never>?

    // videoQueue
    private var throttle = AnalysisThrottle(minimumInterval: 0.35)
    private var isAnalysisEnabled = true
    private var onBoxes: (@Sendable (_ boxes: [CGRect], _ videoSize: CGSize) -> Void)?

    /// Configures and starts the session.  `previewLayer` is needed up front: the
    /// rotation coordinator keeps the frames upright relative to what it shows.
    func start(
        previewLayer: AVCaptureVideoPreviewLayer,
        onBoxes: @escaping @Sendable (_ boxes: [CGRect], _ videoSize: CGSize) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configure(previewLayer: previewLayer)
                    videoQueue.sync { self.onBoxes = onBoxes }
                    session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        videoQueue.async { [self] in
            isAnalysisEnabled = false
            onBoxes = nil
        }
        sessionQueue.async { [self] in
            rotationObservations.removeAll()
            if session.isRunning { session.stopRunning() }
            photoContinuation?.resume(returning: nil)
            photoContinuation = nil
        }
    }

    /// Analysis is paused while the phone is hot; the camera itself keeps working.
    func setAnalysisEnabled(_ enabled: Bool) {
        videoQueue.async { [self] in isAnalysisEnabled = enabled }
    }

    /// The photo exactly as the camera encoded it (HEIC or JPEG, EXIF intact).
    func capturePhoto() async -> Data? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard photoContinuation == nil, session.isRunning else {
                    continuation.resume(returning: nil)
                    return
                }
                photoContinuation = continuation
                if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
                   let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    // MARK: Configuration (sessionQueue)

    private func configure(previewLayer: AVCaptureVideoPreviewLayer) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
        else { throw SetupError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput)
        else { throw SetupError.cannotConfigure }
        session.addInput(input)
        session.addOutput(photoOutput)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.addOutput(videoOutput)

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview, previewLayer: previewLayer)
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                sessionQueue.async { self.applyPreviewRotation(angle, previewLayer: previewLayer) }
            }
        ]
    }

    /// Rotates the preview and the analysed frames together, so a box found in a
    /// frame lands on the same thing in the preview.
    private func applyPreviewRotation(_ angle: CGFloat, previewLayer: AVCaptureVideoPreviewLayer) {
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        DispatchQueue.main.async {
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    // MARK: Frames (videoQueue)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isAnalysisEnabled, let onBoxes, let pixelBuffer = sampleBuffer.imageBuffer,
              throttle.begin(at: ProcessInfo.processInfo.systemUptime)
        else { return }

        let videoSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)
        )
        // Held only for the duration of one Vision pass, then released with the task.
        nonisolated(unsafe) let frame = pixelBuffer
        Task { [self] in
            let boxes = await PIIScanner.liveBoxes(in: frame)
            onBoxes(boxes, videoSize)
            videoQueue.async { self.throttle.end() }
        }
    }

    // MARK: Photo (AVFoundation's queue → sessionQueue)

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        sessionQueue.async { [self] in
            photoContinuation?.resume(returning: data)
            photoContinuation = nil
        }
    }
}

// MARK: - LiveCameraModel

@Observable
@MainActor
final class LiveCameraModel {

    enum State: Equatable { case starting, running, unavailable }

    private(set) var state: State = .starting
    /// Normalised, top-left-origin boxes of what would be redacted right now.
    private(set) var boxes: [CGRect] = []
    private(set) var videoSize: CGSize = .zero
    private(set) var isCapturing = false

    let previewLayer = AVCaptureVideoPreviewLayer()
    @ObservationIgnored private let camera = CameraSession()
    @ObservationIgnored private var thermalTask: Task<Void, Never>?

    func start() async {
        previewLayer.session = camera.session
        previewLayer.videoGravity = .resizeAspect
        do {
            try await camera.start(previewLayer: previewLayer) { [weak self] boxes, videoSize in
                Task { @MainActor in
                    self?.boxes = boxes
                    self?.videoSize = videoSize
                }
            }
            state = .running
            watchThermalState()
        } catch {
            state = .unavailable
        }
    }

    func stop() {
        thermalTask?.cancel()
        camera.stop()
        boxes = []
    }

    func capture() async -> Data? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        return await camera.capturePhoto()
    }

    /// A hot phone gets its camera back without the analysis; the boxes return
    /// when it has cooled down.
    private func watchThermalState() {
        applyThermalState()
        thermalTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                self?.applyThermalState()
            }
        }
    }

    private func applyThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        let isHot = state == .serious || state == .critical
        camera.setAnalysisEnabled(!isHot)
        if isHot { boxes = [] }
    }
}

// MARK: - LiveCameraView

/// A viewfinder that shows, live, what PicStrip would redact — then hands the
/// photo straight to the editor, where the real scan runs at full accuracy.
struct LiveCameraView: View {

    enum Outcome {
        case captured(Data)
        case cancelled
        /// The capture session could not be set up; the caller falls back to the system camera.
        case unavailable
    }

    let onFinish: (Outcome) -> Void

    @State private var model = LiveCameraModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let videoRect = LiveOverlayGeometry.videoRect(videoSize: model.videoSize, in: geo.size)
                ZStack(alignment: .topLeading) {
                    CameraPreview(layer: model.previewLayer)
                    ForEach(Array(model.boxes.enumerated()), id: \.offset) { _, box in
                        let rect = LiveOverlayGeometry.rect(for: box, in: videoRect)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.black.opacity(0.88))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .animation(reduceMotion ? nil : .linear(duration: 0.12), value: model.boxes)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack {
                HStack {
                    Button {
                        onFinish(.cancelled)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close camera")
                    .accessibilityIdentifier("liveCameraCloseButton")
                    Spacer()
                }

                Text("Covered areas will be redacted. You can change them after the photo is taken.")
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(in: .capsule)
                    .padding(.top, 4)

                Spacer()

                Button {
                    Task {
                        if let data = await model.capture() { onFinish(.captured(data)) }
                    }
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 66, height: 66)
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 80, height: 80)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.state != .running || model.isCapturing)
                .opacity(model.state == .running ? 1 : 0.4)
                .accessibilityLabel("Take Photo")
                .accessibilityIdentifier("liveCameraShutterButton")
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .statusBarHidden()
        .task {
            await model.start()
            if model.state == .unavailable { onFinish(.unavailable) }
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - CameraPreview

private struct CameraPreview: UIViewRepresentable {
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
