@preconcurrency import AVFoundation
import os
import SwiftUI
import UIKit
import Vision

// MARK: - Pure helpers

/// Lets at most one frame be analysed at a time, and no more often than
/// `minimumInterval` — Vision on every frame would cook the phone for boxes
/// nobody can read that fast.
nonisolated struct AnalysisThrottle {
    var minimumInterval: TimeInterval
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

// MARK: - FrameRegistration

/// How far the picture moved between two camera frames, from Vision's
/// translational image registration — cheap next to OCR, so it can run several
/// times between passes and keep the boxes on their content while the phone moves.
///
/// Stateful: each call compares a frame with the one before it.  One call at a
/// time; `CameraSession` gates it with a throttle of its own.
nonisolated final class FrameRegistration: @unchecked Sendable {
    private var request = PIIScanner.onSimulatorCPU(TrackTranslationalImageRegistrationRequest())
    private var frameSize: CGSize = .zero

    /// The displacement of the content since the previous frame, normalised
    /// with a top-left origin — `nil` for the first frame after `restart` or a
    /// change of frame size, or when Vision fails.
    func shift(to pixelBuffer: CVPixelBuffer, restart: Bool = false) async -> CGVector? {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let isFirst = restart || size != frameSize
        if isFirst {
            request = PIIScanner.onSimulatorCPU(TrackTranslationalImageRegistrationRequest())
            frameSize = size
        }
        guard let observation = try? await ImageRequestHandler(pixelBuffer).perform(request), !isFirst else { return nil }
        return Self.shift(from: observation.alignmentTransform, frameSize: size)
    }

    /// Vision reports the transform that maps the new frame back onto the old
    /// one, in pixels with a bottom-left origin; the content itself moved the
    /// other way.
    static func shift(from transform: CGAffineTransform, frameSize: CGSize) -> CGVector {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        return CGVector(dx: -transform.tx / frameSize.width, dy: transform.ty / frameSize.height)
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
/// queues of its own choosing: session and device work on `sessionQueue`, frame
/// work on `videoQueue`, and the two never touch each other's state.
nonisolated final class CameraSession: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {

    enum SetupError: Error { case noCamera, cannotConfigure }

    /// Where the frame queue reports; both are called off the main actor.
    struct Handlers: Sendable {
        /// A finished pass, the size of the frame it looked at, and the motion
        /// offset (`LiveMotion.offset`) at that frame.
        let scan: @Sendable (_ scan: LiveFrameScan, _ videoSize: CGSize, _ origin: CGVector) -> Void
        /// The motion offset now.
        let motion: @Sendable (_ offset: CGVector) -> Void
    }

    /// What the camera can do, known once it is configured.
    struct Capabilities: Sendable, Equatable {
        var hasTorch = false
        /// Zoom levels as the Camera app labels them (1×, 2×) that this camera reaches.
        var zoomLevels: [CGFloat] = []
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.northcutt.PicStrip.camera.session")
    private let videoQueue = DispatchQueue(label: "com.northcutt.PicStrip.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private static let signposter = OSSignposter(subsystem: "com.northcutt.PicStrip", category: "LiveCamera")
    private static let logger = Logger(subsystem: "com.northcutt.PicStrip", category: "LiveCamera")

    // Preview layers and their rotation coordinator stay on the main actor.
    @MainActor private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @MainActor private var rotationObservations: [NSKeyValueObservation] = []
    @MainActor private weak var previewLayer: AVCaptureVideoPreviewLayer?

    // sessionQueue
    private var device: AVCaptureDevice?
    private var captureRotationAngle: CGFloat = 0
    private var photoContinuation: CheckedContinuation<Data?, Never>?

    // videoQueue
    private var analysisThrottle = AnalysisThrottle(minimumInterval: LiveAnalysisPacing.baseInterval)
    private var motionThrottle = AnalysisThrottle(minimumInterval: 1.0 / 15)
    private var isAnalysisEnabled = true
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private var motion = LiveMotion()
    private var motionNeedsRestart = false
    /// Bumped whenever the picture changes in a way that makes passes already
    /// under way describe something that is no longer there.
    private var generation = 0
    private var hasLoggedFrameSize = false
    private var handlers: Handlers?
    /// The user's Always Cover words, looked for in every pass.
    private var alwaysCover: [String] = []
    private let registration = FrameRegistration()

    /// Configures and starts the session.  `previewLayer` is needed up front: the
    /// rotation coordinator keeps the frames upright relative to what it shows.
    @MainActor
    func start(previewLayer: AVCaptureVideoPreviewLayer, handlers: Handlers) async throws -> Capabilities {
        typealias Configured = (device: AVCaptureDevice, capabilities: Capabilities)
        let (device, capabilities) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Configured, Error>) in
            sessionQueue.async { [self] in
                do {
                    let device = try configure()
                    let capabilities = prepare(device)
                    videoQueue.sync { self.handlers = handlers }
                    session.startRunning()
                    continuation.resume(returning: (device, capabilities))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        self.previewLayer = previewLayer
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        updateRotation()
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateRotation() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateRotation() }
            }
        ]
        return capabilities
    }

    @MainActor
    func stop() {
        rotationObservations.removeAll()
        rotationCoordinator = nil
        previewLayer = nil
        videoQueue.async { [self] in
            isAnalysisEnabled = false
            handlers = nil
        }
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            photoContinuation?.resume(returning: nil)
            photoContinuation = nil
        }
    }

    /// Restarts a session the system stopped (a media-services reset).
    func resume() {
        sessionQueue.async { [self] in
            if device != nil, !session.isRunning { session.startRunning() }
        }
    }

    func setAlwaysCover(_ terms: [String]) {
        videoQueue.async { [self] in alwaysCover = terms }
    }

    /// A hot phone keeps its camera but loses the analysis; a warm one analyses less often.
    func setThermalState(_ state: ProcessInfo.ThermalState) {
        videoQueue.async { [self] in
            thermalState = state
            let enabled = !LiveAnalysisPacing.isTooHot(state)
            if enabled, !isAnalysisEnabled { restartAnalysisOnVideoQueue() }
            isAnalysisEnabled = enabled
        }
    }

    /// Drops passes under way and measures motion afresh — after a zoom, a pause,
    /// or an interruption, the last frame seen is no guide to the next.
    func restartAnalysis() {
        videoQueue.async { [self] in restartAnalysisOnVideoQueue() }
    }

    /// Freezes the viewfinder on its last frame while the photo is taken.
    @MainActor
    func freezePreview(_ isFrozen: Bool) {
        previewLayer?.connection?.isEnabled = !isFrozen
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
                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(captureRotationAngle) {
                    connection.videoRotationAngle = captureRotationAngle
                }
                photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    // MARK: Device controls (sessionQueue)

    /// Focuses and exposes once on `devicePoint` (the capture device's normalised
    /// space), until the scene changes.
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [self] in
            guard let device else { return }
            Self.setFocus(of: device, to: devicePoint, continuous: false)
        }
    }

    /// Back to continuous focus and exposure on the centre of the frame.
    func resetFocus() {
        sessionQueue.async { [self] in
            guard let device else { return }
            Self.setFocus(of: device, to: CGPoint(x: 0.5, y: 0.5), continuous: true)
        }
    }

    /// `level` as the Camera app labels it: 1 is the main camera's field of view.
    func setZoom(_ level: CGFloat) {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
            } catch {
                return
            }
            device.ramp(toVideoZoomFactor: Self.videoZoomFactor(forDisplayLevel: level, of: device), withRate: 4)
            device.unlockForConfiguration()
        }
    }

    func setTorch(_ isOn: Bool) {
        sessionQueue.async { [self] in
            let mode: AVCaptureDevice.TorchMode = isOn ? .on : .off
            guard let device, device.hasTorch, device.isTorchModeSupported(mode) else { return }
            do {
                try device.lockForConfiguration()
            } catch {
                return
            }
            device.torchMode = mode
            device.unlockForConfiguration()
        }
    }

    // MARK: Configuration (sessionQueue)

    /// The back camera that best reads small print: a virtual device where there
    /// is one, because it switches to the ultra-wide lens for close-ups on its
    /// own — the main lens cannot focus that near.
    private static func preferredDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        return types.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
            ?? AVCaptureDevice.default(for: .video)
    }

    private func configure() throws -> AVCaptureDevice {
        guard let device = Self.preferredDevice() else { throw SetupError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput)
        else { throw SetupError.cannotConfigure }
        session.addInput(input)
        session.addOutput(photoOutput)

        // With the photo preset the video output delivers preview-sized frames
        // (about the screen's size), not the sensor's: OCR reads what the
        // viewfinder shows.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.addOutput(videoOutput)

        self.device = device
        return device
    }

    /// Settings that need the configured format: the Camera app's 1× (on a
    /// virtual device a zoom factor of 1 is the ultra-wide lens), and continuous
    /// autofocus.
    private func prepare(_ device: AVCaptureDevice) -> Capabilities {
        var capabilities = Capabilities()
        capabilities.hasTorch = device.hasTorch && device.isTorchModeSupported(.on)
        capabilities.zoomLevels = [1, 2].filter { level in
            let factor = level / device.displayVideoZoomFactorMultiplier
            return factor >= device.minAvailableVideoZoomFactor && factor <= device.maxAvailableVideoZoomFactor
        }
        do {
            try device.lockForConfiguration()
        } catch {
            return capabilities
        }
        device.videoZoomFactor = Self.videoZoomFactor(forDisplayLevel: 1, of: device)
        device.unlockForConfiguration()
        Self.setFocus(of: device, to: CGPoint(x: 0.5, y: 0.5), continuous: true)
        return capabilities
    }

    private static func videoZoomFactor(forDisplayLevel level: CGFloat, of device: AVCaptureDevice) -> CGFloat {
        let factor = level / device.displayVideoZoomFactorMultiplier
        return min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private static func setFocus(of device: AVCaptureDevice, to point: CGPoint, continuous: Bool) {
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }
        let focusMode: AVCaptureDevice.FocusMode = continuous ? .continuousAutoFocus : .autoFocus
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
            device.focusPointOfInterest = point
            device.focusMode = focusMode
        }
        let exposureMode: AVCaptureDevice.ExposureMode = continuous ? .continuousAutoExposure : .autoExpose
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(exposureMode) {
            device.exposurePointOfInterest = point
            device.exposureMode = exposureMode
        }
        // A tapped focus holds until the scene changes; then it goes back to continuous.
        device.isSubjectAreaChangeMonitoringEnabled = !continuous
    }

    @MainActor
    private func updateRotation() {
        guard let coordinator = rotationCoordinator else { return }
        let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(previewAngle) {
            connection.videoRotationAngle = previewAngle
        }
        sessionQueue.async { [self] in
            captureRotationAngle = captureAngle
            if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(previewAngle) {
                connection.videoRotationAngle = previewAngle
            }
        }
    }

    // MARK: Frames (videoQueue)

    private func restartAnalysisOnVideoQueue() {
        generation += 1
        motionNeedsRestart = true
        motion.restart()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isAnalysisEnabled, let handlers, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Held only for the duration of one Vision request, then released with the task.
        nonisolated(unsafe) let frame = pixelBuffer
        let videoSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if !hasLoggedFrameSize {
            hasLoggedFrameSize = true
            Self.logger.debug("Live frames are \(Int(videoSize.width))×\(Int(videoSize.height))")
        }

        if motionThrottle.begin(at: now) {
            let restart = motionNeedsRestart
            motionNeedsRestart = false
            Task { [self] in
                let signpost = Self.signposter.beginInterval("Frame registration")
                let shift = await registration.shift(to: frame, restart: restart)
                Self.signposter.endInterval("Frame registration", signpost)
                videoQueue.async { [self] in
                    motionThrottle.end()
                    guard let shift else {
                        motion.restart()
                        return
                    }
                    motion.add(shift, at: now)
                    handlers.motion(motion.offset)
                }
            }
        }

        // A blurred frame reads as nothing, and a pass over it only makes the boxes flicker.
        guard motion.speed <= LiveAnalysisPacing.maximumAnalysisSpeed, analysisThrottle.begin(at: now) else { return }
        let origin = motion.offset
        let passGeneration = generation
        let terms = alwaysCover
        Task { [self] in
            let signpost = Self.signposter.beginInterval("Live scan")
            let started = ProcessInfo.processInfo.systemUptime
            let scan = await PIIScanner.liveScan(in: frame, alwaysCover: terms)
            let duration = ProcessInfo.processInfo.systemUptime - started
            Self.signposter.endInterval("Live scan", signpost)
            videoQueue.async { [self] in
                analysisThrottle.minimumInterval = LiveAnalysisPacing.interval(
                    thermalState: thermalState, lastPassDuration: duration
                )
                analysisThrottle.end()
                if passGeneration == generation { handlers.scan(scan, videoSize, origin) }
            }
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

// MARK: - LiveCameraFixture

/// A still image that stands in for the camera, so the viewfinder can be run on
/// the simulator, which has none: set `PICSTRIP_LIVE_CAMERA_FIXTURE` to the
/// image's path and the app opens the viewfinder on it at launch.
struct LiveCameraFixture {
    let data: Data
    let image: CGImage

    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment["PICSTRIP_LIVE_CAMERA_FIXTURE"] != nil
    }

    static func fromEnvironment() -> LiveCameraFixture? {
        guard let path = ProcessInfo.processInfo.environment["PICSTRIP_LIVE_CAMERA_FIXTURE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = UIImage(data: data)?.cgImage
        else { return nil }
        return LiveCameraFixture(data: data, image: image)
    }

    /// An IOSurface-backed BGRA buffer holding `image`, like a camera frame.
    nonisolated static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            // Camera frames are IOSurface-backed; Vision's pixel-buffer path expects that.
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

// MARK: - LiveCameraModel

@Observable
@MainActor
final class LiveCameraModel {

    enum State: Equatable { case starting, running, interrupted, unavailable }

    private(set) var state: State = .starting
    /// Findings on screen, in the stabilised space of `LiveMotion`; draw them
    /// through `displayBox(_:)`.
    private(set) var tracks: [LiveTrack] = []
    /// The lines of text the last pass read, in the same space.
    private(set) var textLines: [CGRect] = []
    private(set) var motionOffset: CGVector = .zero
    private(set) var videoSize: CGSize = .zero
    /// A pass has finished since the camera started, zoomed or resumed.
    private(set) var hasScanned = false
    /// The phone is too hot to analyse; the camera itself keeps working.
    private(set) var isAnalysisPaused = false
    private(set) var isCapturing = false
    private(set) var capabilities = CameraSession.Capabilities()
    private(set) var zoomLevel: CGFloat = 1
    private(set) var isTorchOn = false
    /// Where the user tapped to focus, in view points, until the camera refocuses by itself.
    private(set) var focusPoint: CGPoint?
    /// Set when a still image stands in for the camera.
    let fixture: LiveCameraFixture?

    let previewLayer = AVCaptureVideoPreviewLayer()
    @ObservationIgnored private let camera = CameraSession()
    @ObservationIgnored private var tracker = LiveDetectionTracker()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(fixture: LiveCameraFixture? = LiveCameraFixture.fromEnvironment()) {
        self.fixture = fixture
    }

    var summary: LiveScanSummary { LiveScanSummary(tracks: tracks) }

    /// Where a stabilised box is in the current frame.
    func displayBox(_ box: CGRect) -> CGRect {
        box.offsetBy(dx: motionOffset.dx, dy: motionOffset.dy)
    }

    func start() async {
        if let fixture {
            startFixture(fixture)
            return
        }
        previewLayer.session = camera.session
        previewLayer.videoGravity = .resizeAspect
        camera.setAlwaysCover(AlwaysCoverList.shared.terms)
        do {
            capabilities = try await camera.start(previewLayer: previewLayer, handlers: .init(
                scan: { [weak self] scan, videoSize, origin in
                    Task { @MainActor in self?.apply(scan, videoSize: videoSize, origin: origin) }
                },
                motion: { [weak self] offset in
                    Task { @MainActor in self?.applyMotion(offset) }
                }
            ))
            state = .running
            watchThermalState()
            watchSession()
        } catch {
            state = .unavailable
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        camera.stop()
        clearDetections()
    }

    /// The photo, or `nil` if it could not be taken.  After a photo the viewfinder
    /// stays frozen, boxes and all, while it is dismissed.
    func capture() async -> Data? {
        guard state == .running, !isCapturing else { return nil }
        isCapturing = true
        if let fixture { return fixture.data }
        camera.freezePreview(true)
        guard let data = await camera.capturePhoto() else {
            camera.freezePreview(false)
            isCapturing = false
            return nil
        }
        return data
    }

    /// `point` is in the viewfinder's coordinates, which are the preview layer's.
    func focus(at point: CGPoint) {
        guard fixture == nil, state == .running, !isCapturing else { return }
        camera.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        focusPoint = point
    }

    func setZoom(_ level: CGFloat) {
        guard level != zoomLevel, state == .running else { return }
        zoomLevel = level
        camera.setZoom(level)
        // The boxes describe the old field of view.
        clearDetections()
    }

    func setTorch(_ isOn: Bool) {
        guard state == .running else { return }
        isTorchOn = isOn
        camera.setTorch(isOn)
    }

    // MARK: Results

    private func apply(_ scan: LiveFrameScan, videoSize: CGSize, origin: CGVector) {
        // A pass that finishes after the camera paused describes a picture that is gone.
        guard state == .running, !isAnalysisPaused, !isCapturing else { return }
        if videoSize != self.videoSize {
            // Rotated: the old boxes are in the old orientation.
            tracker.removeAll()
            self.videoSize = videoSize
        }
        let stabilised = { (box: CGRect) in box.offsetBy(dx: -origin.dx, dy: -origin.dy) }
        tracker.update(with: scan.detections.map {
            LiveDetection(type: $0.type, boundingBox: stabilised($0.boundingBox), score: $0.score)
        })
        tracks = tracker.tracks
        textLines = scan.textLines.map(stabilised)
        hasScanned = true
    }

    private func applyMotion(_ offset: CGVector) {
        // The viewfinder is frozen while the photo is taken; the boxes stay with it.
        guard !isCapturing else { return }
        motionOffset = offset
    }

    private func clearDetections() {
        tracker.removeAll()
        tracks = []
        textLines = []
        hasScanned = false
        camera.restartAnalysis()
    }

    // MARK: Observation

    /// A hot phone gets its camera back without the analysis; the boxes return
    /// when it has cooled down.
    private func watchThermalState() {
        applyThermalState()
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                self?.applyThermalState()
            }
        })
    }

    private func applyThermalState() {
        let thermalState = ProcessInfo.processInfo.thermalState
        camera.setThermalState(thermalState)
        let isPaused = LiveAnalysisPacing.isTooHot(thermalState)
        if isPaused != isAnalysisPaused {
            isAnalysisPaused = isPaused
            clearDetections()
        }
    }

    /// Calls, Split View and the app going to the background take the camera
    /// away; the viewfinder says so instead of showing stale boxes on a frozen frame.
    private func watchSession() {
        let session = camera.session
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification, object: session) {
                self?.setInterrupted(true)
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification, object: session) {
                self?.setInterrupted(false)
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification, object: session) {
                self?.camera.resume()
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification) {
                self?.focusPoint = nil
                self?.camera.resetFocus()
            }
        })
    }

    private func setInterrupted(_ isInterrupted: Bool) {
        if isInterrupted {
            guard state == .running else { return }
            state = .interrupted
            // The system turns the torch off with the camera.
            isTorchOn = false
            focusPoint = nil
            clearDetections()
        } else if state == .interrupted {
            state = .running
            camera.restartAnalysis()
        }
    }

    // MARK: Fixture

    private func startFixture(_ fixture: LiveCameraFixture) {
        guard let buffer = LiveCameraFixture.pixelBuffer(from: fixture.image) else {
            state = .unavailable
            return
        }
        videoSize = CGSize(width: fixture.image.width, height: fixture.image.height)
        state = .running
        nonisolated(unsafe) let frame = buffer
        let terms = AlwaysCoverList.shared.terms
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let scan = await PIIScanner.liveScan(in: frame, alwaysCover: terms)
                guard let self, !Task.isCancelled else { return }
                apply(scan, videoSize: videoSize, origin: .zero)
                try? await Task.sleep(for: .seconds(LiveAnalysisPacing.baseInterval))
            }
        })
    }
}
