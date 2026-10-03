import AVFoundation
import CoreGraphics
import Observation
import OSLog
import UIKit

// MARK: - VideoQuality

/// How a recording is made, in the Camera app's terms: resolution, frame rate,
/// HDR, and how strongly it is stabilised.
nonisolated struct VideoQuality: Hashable, Sendable {
    enum Resolution: Int, CaseIterable, Comparable, Sendable {
        case hd = 1080
        case uhd = 2160

        static func < (lhs: Resolution, rhs: Resolution) -> Bool { lhs.rawValue < rhs.rawValue }

        /// As the Camera app labels it.
        var label: String {
            switch self {
            case .hd: "HD"
            case .uhd: "4K"
            }
        }

        var width: Int { self == .hd ? 1920 : 3840 }
        var height: Int { rawValue }
    }

    var resolution: Resolution
    var frameRate: Int
    /// 10-bit HLG — Dolby Vision on iPhone — where the camera records it.
    var isHDR: Bool
    /// The strongest stabilisation (extended cinematic, enhanced), for walking
    /// and running; it crops the picture a little more.
    var isEnhancedStabilization: Bool

    /// What the camera starts with: all the detail at a natural frame rate, in
    /// HDR, as the Camera app records by default on recent iPhones.
    static let preferred = VideoQuality(resolution: .uhd, frameRate: 30, isHDR: true, isEnhancedStabilization: false)
}

// MARK: - VideoFormatTraits

/// What one of a camera's formats can record, apart from AVFoundation so that
/// choosing among them can be tested.
nonisolated struct VideoFormatTraits: Hashable, Sendable {
    var width: Int
    var height: Int
    var maxFrameRate: Double
    /// Takes the HLG BT.2020 colour space: HDR.
    var supportsHDR: Bool
    var supportsEnhancedStabilization: Bool
    /// Pixels summed in pairs: less detail.
    var isBinned = false
    /// Full-range pixels are for photos; video is recorded in video range.
    var isFullRange = false

    var resolution: VideoQuality.Resolution? {
        VideoQuality.Resolution.allCases.first { $0.width == width && $0.height == height }
    }
}

// MARK: - VideoFormatCatalog

/// The choices a camera offers, worked out from its formats, and the format to
/// record each with.
nonisolated enum VideoFormatCatalog {

    /// The frame rates offered, as in the Camera app (25 is left to it).
    static let frameRates = [24, 30, 60, 120]

    static func resolutions(in formats: [VideoFormatTraits]) -> [VideoQuality.Resolution] {
        VideoQuality.Resolution.allCases.filter { !frameRates(for: $0, in: formats).isEmpty }
    }

    static func frameRates(for resolution: VideoQuality.Resolution, in formats: [VideoFormatTraits]) -> [Int] {
        frameRates.filter { rate in
            formats.contains { $0.resolution == resolution && $0.maxFrameRate + 0.5 >= Double(rate) }
        }
    }

    static func supportsHDR(_ resolution: VideoQuality.Resolution, frameRate: Int, in formats: [VideoFormatTraits]) -> Bool {
        bestFormat(for: VideoQuality(resolution: resolution, frameRate: frameRate, isHDR: true, isEnhancedStabilization: false), in: formats) != nil
    }

    static func supportsEnhancedStabilization(
        _ resolution: VideoQuality.Resolution, frameRate: Int, isHDR: Bool, in formats: [VideoFormatTraits]
    ) -> Bool {
        let quality = VideoQuality(resolution: resolution, frameRate: frameRate, isHDR: isHDR, isEnhancedStabilization: true)
        return bestFormat(for: quality, in: formats) != nil
    }

    /// `wanted`, changed as little as possible to something the camera can
    /// record: its resolution kept if it can be, then the nearest frame rate,
    /// then HDR and stabilisation as asked where they go with those.
    static func nearest(to wanted: VideoQuality, in formats: [VideoFormatTraits]) -> VideoQuality? {
        let resolutions = resolutions(in: formats)
        guard let resolution = resolutions.contains(wanted.resolution) ? wanted.resolution : resolutions.max() else {
            return nil
        }
        let rates = frameRates(for: resolution, in: formats)
        guard let frameRate = rates.min(by: { lhs, rhs in
            let left = abs(lhs - wanted.frameRate)
            let right = abs(rhs - wanted.frameRate)
            return left == right ? lhs < rhs : left < right
        }) else { return nil }
        let isHDR = wanted.isHDR && supportsHDR(resolution, frameRate: frameRate, in: formats)
        let isEnhanced = wanted.isEnhancedStabilization
            && supportsEnhancedStabilization(resolution, frameRate: frameRate, isHDR: isHDR, in: formats)
        return VideoQuality(resolution: resolution, frameRate: frameRate, isHDR: isHDR, isEnhancedStabilization: isEnhanced)
    }

    /// The index of the format to record `quality` with: one that can, with
    /// full detail where there is a choice, in video range, 8-bit for SDR, and
    /// no faster than it needs to be.
    static func bestFormat(for quality: VideoQuality, in formats: [VideoFormatTraits]) -> Int? {
        let candidates = formats.indices.filter { index in
            let format = formats[index]
            return format.resolution == quality.resolution
                && format.maxFrameRate + 0.5 >= Double(quality.frameRate)
                && (!quality.isHDR || format.supportsHDR)
                && (!quality.isEnhancedStabilization || format.supportsEnhancedStabilization)
        }
        return candidates.min { lhs, rhs in
            let left = formats[lhs]
            let right = formats[rhs]
            let leftRank = [left.isBinned ? 1 : 0, left.isFullRange ? 1 : 0, !quality.isHDR && left.supportsHDR ? 1 : 0]
            let rightRank = [right.isBinned ? 1 : 0, right.isFullRange ? 1 : 0, !quality.isHDR && right.supportsHDR ? 1 : 0]
            if leftRank != rightRank { return leftRank.lexicographicallyPrecedes(rightRank) }
            return left.maxFrameRate < right.maxFrameRate
        }
    }

    /// The Camera app's lens buttons for a camera: its widest view, each lens
    /// it switches to, and 2× where the main lens crops to it.
    static func lensLevels(minimum: CGFloat, switchOvers: [CGFloat], maximum: CGFloat) -> [CGFloat] {
        var levels = [minimum] + switchOvers
        if levels.contains(where: { abs($0 - 1) < 0.05 }), !levels.contains(where: { abs($0 - 2) < 0.05 }), maximum >= 2 {
            levels.append(2)
        }
        let rounded = levels.map { ($0 * 10).rounded() / 10 }.filter { $0 <= maximum }
        return Array(Set(rounded)).sorted()
    }
}

// MARK: - VideoCaptureSession

/// Records video from the camera at the quality the Camera app would, with its
/// controls: lenses and zoom, focus and exposure, torch, the front camera, and
/// the Camera Control's zoom and exposure sliders.  Recordings go straight to
/// PicStrip's protected temporary store — never to the photo library.
///
/// Thread confinement, as `CameraSession`: session and device work happen on
/// `sessionQueue`; preview layers and their rotation on the main actor.
nonisolated final class VideoCaptureSession: NSObject, @unchecked Sendable,
    AVCaptureFileOutputRecordingDelegate, AVCaptureSessionControlsDelegate {

    enum SetupError: Error { case noCamera, cannotConfigure }

    struct Handlers: Sendable {
        /// A recording ended without being stopped — a call, a full disk, a hot
        /// phone: what was written, or `nil` if nothing usable was.
        let recordingEnded: @Sendable (URL?) -> Void
        /// The Camera Control's zoom slider moved, to this Camera-app zoom level.
        let zoomChanged: @MainActor @Sendable (CGFloat) -> Void
        /// The Camera Control's overlay took over the screen, or gave it back.
        let controlsFullscreen: @Sendable (Bool) -> Void
        /// The phone got hot enough to lower the frame rate, or cooled down.
        let hot: @Sendable (Bool) -> Void
    }

    /// The camera in use, what it can record, and how it is set.
    struct Setup: Sendable, Equatable {
        var position: AVCaptureDevice.Position = .back
        var quality = VideoQuality.preferred
        var formats: [VideoFormatTraits] = []
        var zoomLevels: [CGFloat] = [1]
        var maximumZoomLevel: CGFloat = 1
        var hasTorch = false
        var canFlip = false
        var recordsSound = false
        var exposureBiasRange: ClosedRange<Float> = 0...0
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.northcutt.PicStrip.video.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private static let logger = Logger(subsystem: "com.northcutt.PicStrip", category: "VideoCamera")

    @MainActor private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @MainActor private var rotationObservations: [NSKeyValueObservation] = []
    @MainActor private weak var previewLayer: AVCaptureVideoPreviewLayer?

    // sessionQueue
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var formats: [AVCaptureDevice.Format] = []
    private var setup = Setup()
    private var captureRotationAngle: CGFloat = 0
    private var handlers: Handlers?
    private var pressureObservation: NSKeyValueObservation?
    private var isRecording = false
    private var stopContinuation: CheckedContinuation<URL?, Never>?

    // MARK: Lifecycle

    /// Sets up the camera at `position` for `quality` (or the nearest it can
    /// record) and starts it.
    @MainActor
    func start(
        position: AVCaptureDevice.Position, quality: VideoQuality, recordsSound: Bool,
        previewLayer: AVCaptureVideoPreviewLayer, handlers: Handlers
    ) async throws -> Setup {
        self.previewLayer = previewLayer
        let (device, setup) = try await onSessionQueue { [self] in
            self.handlers = handlers
            let configured = try configure(position: position, quality: quality, recordsSound: recordsSound)
            session.startRunning()
            return configured
        }
        attachRotation(to: device)
        return setup
    }

    @MainActor
    func stop() {
        rotationObservations.removeAll()
        rotationCoordinator = nil
        sessionQueue.async { [self] in
            handlers = nil
            pressureObservation = nil
            if movieOutput.isRecording { movieOutput.stopRecording() }
            if session.isRunning { session.stopRunning() }
            stopContinuation?.resume(returning: nil)
            stopContinuation = nil
        }
    }

    /// Restarts a session the system stopped (a media-services reset).
    func resume() {
        sessionQueue.async { [self] in
            if device != nil, !session.isRunning { session.startRunning() }
        }
    }

    /// The other camera, front or back, at the same quality where it can.
    @MainActor
    func flip() async throws -> Setup {
        let (device, setup) = try await onSessionQueue { [self] in
            guard !isRecording else { throw SetupError.cannotConfigure }
            return try configure(
                position: setup.position == .back ? .front : .back,
                quality: setup.quality, recordsSound: setup.recordsSound
            )
        }
        attachRotation(to: device)
        return setup
    }

    /// Records at `quality`, or the nearest the camera can.
    func setQuality(_ quality: VideoQuality) async -> Setup {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard !isRecording, let device,
                      let chosen = VideoFormatCatalog.nearest(to: quality, in: setup.formats) else {
                    continuation.resume(returning: setup)
                    return
                }
                session.beginConfiguration()
                apply(chosen, to: device)
                session.commitConfiguration()
                continuation.resume(returning: setup)
            }
        }
    }

    // MARK: Recording

    /// Starts recording to `url`; `false` if the camera is not ready.
    func startRecording(to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard session.isRunning, !isRecording, let connection = movieOutput.connection(with: .video) else {
                    continuation.resume(returning: false)
                    return
                }
                // Upright as the phone is held when recording starts, as in the Camera app.
                if connection.isVideoRotationAngleSupported(captureRotationAngle) {
                    connection.videoRotationAngle = captureRotationAngle
                }
                isRecording = true
                movieOutput.startRecording(to: url, recordingDelegate: self)
                continuation.resume(returning: true)
            }
        }
    }

    /// Stops recording: the finished file, or `nil` if nothing usable was written.
    func stopRecording() async -> URL? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard isRecording else {
                    continuation.resume(returning: nil)
                    return
                }
                stopContinuation = continuation
                movieOutput.stopRecording()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: Error?
    ) {
        // An error can still leave a whole recording: a call, a full disk.
        let finished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        if let error { Self.logger.error("Recording ended: \(error.localizedDescription, privacy: .public)") }
        let file = finished ? outputFileURL : nil
        sessionQueue.async { [self] in
            isRecording = false
            if let stopContinuation {
                self.stopContinuation = nil
                stopContinuation.resume(returning: file)
            } else if let handlers {
                handlers.recordingEnded(file)
            } else {
                // The camera closed mid-recording: nobody will see it, so it goes.
                try? FileManager.default.removeItem(at: outputFileURL)
            }
        }
    }

    // MARK: Device controls

    /// `level` as the Camera app labels it: 1 is the main camera's view.
    func setZoom(_ level: CGFloat, animated: Bool) {
        sessionQueue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            let factor = Self.zoomFactor(forLevel: level, of: device)
            if animated { device.ramp(toVideoZoomFactor: factor, withRate: 6) } else { device.videoZoomFactor = factor }
            device.unlockForConfiguration()
        }
    }

    /// Focuses and exposes once on `devicePoint`, until the scene changes.
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [self] in
            guard let device else { return }
            Self.setFocus(of: device, to: devicePoint, continuous: false)
        }
    }

    func resetFocus() {
        sessionQueue.async { [self] in
            guard let device else { return }
            Self.setFocus(of: device, to: CGPoint(x: 0.5, y: 0.5), continuous: true)
            if (try? device.lockForConfiguration()) != nil {
                device.setExposureTargetBias(0)
                device.unlockForConfiguration()
            }
        }
    }

    /// Brighter or darker than the camera would choose, in stops.
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias))
            device.unlockForConfiguration()
        }
    }

    func setTorch(_ isOn: Bool) {
        sessionQueue.async { [self] in
            let mode: AVCaptureDevice.TorchMode = isOn ? .on : .off
            guard let device, device.hasTorch, device.isTorchModeSupported(mode),
                  (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = mode
            device.unlockForConfiguration()
        }
    }

    // MARK: Configuration (sessionQueue)

    private typealias Configured = (device: AVCaptureDevice, setup: Setup)

    private func onSessionQueue(_ work: @escaping () throws -> Configured) async throws -> Configured {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Configured, Error>) in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The camera at `position` in the session, its formats read, `quality`
    /// (or the nearest) applied, sound added if wanted, and the Camera
    /// Control's sliders set up for it.
    private func configure(
        position: AVCaptureDevice.Position, quality: VideoQuality, recordsSound: Bool
    ) throws -> Configured {
        guard let device = Self.camera(at: position) else { throw SetupError.noCamera }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // The colour space is chosen with the format: HLG for HDR.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        let input = try AVCaptureDeviceInput(device: device)
        if let videoInput { session.removeInput(videoInput) }
        guard session.canAddInput(input) else { throw SetupError.cannotConfigure }
        session.addInput(input)
        videoInput = input

        if recordsSound, audioInput == nil, let microphone = AVCaptureDevice.default(for: .audio),
           let audio = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(audio) {
            session.addInput(audio)
            Self.configureSound(audio)
            audioInput = audio
        }
        if !session.outputs.contains(movieOutput) {
            guard session.canAddOutput(movieOutput) else { throw SetupError.cannotConfigure }
            session.addOutput(movieOutput)
        }

        self.device = device
        formats = device.formats.filter { Self.traits(of: $0).resolution != nil }
        let traits = formats.map(Self.traits)
        guard let chosen = VideoFormatCatalog.nearest(to: quality, in: traits) else { throw SetupError.cannotConfigure }

        let multiplier = device.displayVideoZoomFactorMultiplier
        setup = Setup(
            position: position,
            quality: chosen,
            formats: traits,
            zoomLevels: VideoFormatCatalog.lensLevels(
                minimum: device.minAvailableVideoZoomFactor * multiplier,
                switchOvers: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) * multiplier },
                maximum: device.maxAvailableVideoZoomFactor * multiplier
            ),
            maximumZoomLevel: min(device.maxAvailableVideoZoomFactor * multiplier, 25),
            hasTorch: device.hasTorch && device.isTorchModeSupported(.on),
            canFlip: Self.camera(at: position == .back ? .front : .back) != nil,
            recordsSound: audioInput != nil,
            exposureBiasRange: max(device.minExposureTargetBias, -2)...min(device.maxExposureTargetBias, 2)
        )
        apply(chosen, to: device)
        configureControls(for: device)
        watchPressure(of: device)
        return (device, setup)
    }

    /// The format for `quality`, its frame rate held steady, its colour space,
    /// HEVC, and the stabilisation asked for.  Within a configuration block.
    private func apply(_ quality: VideoQuality, to device: AVCaptureDevice) {
        guard let index = VideoFormatCatalog.bestFormat(for: quality, in: setup.formats),
              (try? device.lockForConfiguration()) != nil else { return }
        let format = formats[index]
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(quality.frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        if quality.isHDR, format.supportedColorSpaces.contains(.HLG_BT2020) {
            device.activeColorSpace = .HLG_BT2020
        } else if format.supportedColorSpaces.contains(.P3_D65) {
            device.activeColorSpace = .P3_D65
        } else {
            device.activeColorSpace = .sRGB
        }
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.videoZoomFactor = Self.zoomFactor(forLevel: 1, of: device)
        device.unlockForConfiguration()
        Self.setFocus(of: device, to: CGPoint(x: 0.5, y: 0.5), continuous: true)

        if let connection = movieOutput.connection(with: .video) {
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = quality.isEnhancedStabilization ? .cinematicExtendedEnhanced : .auto
            }
        }
        setup.quality = quality
    }

    /// Stereo where the microphones can, with wind noise taken out.  Audio
    /// zoom, which narrows the sound to the zoomed picture, is on by default
    /// where there is one.
    private static func configureSound(_ input: AVCaptureDeviceInput) {
        guard input.isMultichannelAudioModeSupported(.stereo) else { return }
        input.multichannelAudioMode = .stereo
        if input.isWindNoiseRemovalSupported { input.isWindNoiseRemovalEnabled = true }
    }

    /// The Camera Control's own zoom and exposure sliders, where there is one.
    private func configureControls(for device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        session.setControlsDelegate(self, queue: sessionQueue)
        for control in session.controls { session.removeControl(control) }
        let multiplier = device.displayVideoZoomFactorMultiplier
        let zoomChanged = handlers?.zoomChanged
        let zoom = AVCaptureSystemZoomSlider(device: device) { factor in
            zoomChanged?(factor * multiplier)
        }
        let exposure = AVCaptureSystemExposureBiasSlider(device: device)
        for control in [zoom, exposure] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
    }

    /// A phone too hot to keep up records at 30 fps instead of stopping, as the
    /// Camera app does.
    private func watchPressure(of device: AVCaptureDevice) {
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            let level = device.systemPressureState.level
            let isHot = level == .serious || level == .critical || level == .shutdown
            guard let self else { return }
            sessionQueue.async { [self] in
                handlers?.hot(isHot)
                guard level == .critical, setup.quality.frameRate > 30, (try? device.lockForConfiguration()) != nil else { return }
                let duration = CMTime(value: 1, timescale: 30)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            }
        }
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) { }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        handlers?.controlsFullscreen(true)
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        handlers?.controlsFullscreen(false)
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { }

    // MARK: Helpers

    /// The back camera with every lens where there is one — it switches
    /// between them as it zooms, as the Camera app does — or the front camera.
    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera, .builtInTrueDepthCamera]
        return types.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: position) }.first
    }

    static func traits(of format: AVCaptureDevice.Format) -> VideoFormatTraits {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return VideoFormatTraits(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            maxFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
            supportsHDR: format.supportedColorSpaces.contains(.HLG_BT2020),
            supportsEnhancedStabilization: format.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced),
            isBinned: format.isVideoBinned,
            isFullRange: subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || subtype == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
    }

    private static func zoomFactor(forLevel level: CGFloat, of device: AVCaptureDevice) -> CGFloat {
        let factor = level / device.displayVideoZoomFactorMultiplier
        return min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private static func setFocus(of device: AVCaptureDevice, to point: CGPoint, continuous: Bool) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let focusMode: AVCaptureDevice.FocusMode = continuous ? .continuousAutoFocus : .autoFocus
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
            device.focusPointOfInterest = point
            device.focusMode = focusMode
        }
        // Exposure keeps adjusting after a tap: a video's light changes as it goes.
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = point
            device.exposureMode = .continuousAutoExposure
        }
        device.isSubjectAreaChangeMonitoringEnabled = !continuous
    }

    // MARK: Rotation (main actor)

    @MainActor
    private func attachRotation(to device: AVCaptureDevice) {
        guard let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        // The preview stabilised like the recording, so what is framed is what is kept.
        if let connection = previewLayer.connection, connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .previewOptimized
        }
        updateRotation()
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateRotation() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateRotation() }
            }
        ]
    }

    @MainActor
    private func updateRotation() {
        guard let coordinator = rotationCoordinator else { return }
        let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(previewAngle) {
            connection.videoRotationAngle = previewAngle
        }
        sessionQueue.async { [self] in captureRotationAngle = captureAngle }
    }
}

// MARK: - VideoCameraFixture

/// A movie that stands in for the camera on the simulator, which has none:
/// set `PICSTRIP_VIDEO_CAMERA_FIXTURE` to its path and the camera opens in
/// Video mode, showing its first frame; "recording" hands back a copy of it.
struct VideoCameraFixture {
    let url: URL
    let still: CGImage

    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment["PICSTRIP_VIDEO_CAMERA_FIXTURE"] != nil
    }

    static func fromEnvironment() async -> VideoCameraFixture? {
        guard let path = ProcessInfo.processInfo.environment["PICSTRIP_VIDEO_CAMERA_FIXTURE"] else { return nil }
        let url = URL(fileURLWithPath: path)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let still = try? await generator.image(at: .zero).image else { return nil }
        return VideoCameraFixture(url: url, still: still)
    }

    /// A phone's back camera, roughly: 4K and HD up to 60 fps in HDR, 120 in HD.
    static let setup = VideoCaptureSession.Setup(
        position: .back,
        quality: .preferred,
        formats: [
            VideoFormatTraits(width: 3840, height: 2160, maxFrameRate: 60, supportsHDR: true, supportsEnhancedStabilization: true),
            VideoFormatTraits(width: 1920, height: 1080, maxFrameRate: 120, supportsHDR: true, supportsEnhancedStabilization: true)
        ],
        zoomLevels: [0.5, 1, 2, 4],
        maximumZoomLevel: 25,
        hasTorch: true,
        canFlip: true,
        recordsSound: true,
        exposureBiasRange: -2...2
    )
}

// MARK: - VideoCameraModel

@Observable
@MainActor
final class VideoCameraModel {

    enum State: Equatable { case starting, running, interrupted, unavailable }

    private(set) var state: State = .starting
    private(set) var setup = VideoCaptureSession.Setup()
    /// The Camera app's zoom level, 1 being the main lens.
    private(set) var zoomLevel: CGFloat = 1
    private(set) var isTorchOn = false
    /// When the recording under way started.
    private(set) var recordingStarted: Date?
    /// The recording is being finished and handed over.
    private(set) var isFinishing = false
    /// A recording that ended — stopped, or by itself — ready for the cleaner.
    private(set) var recording: URL?
    /// The recording ended and nothing usable was written.
    private(set) var recordingFailed = false
    /// The microphone may not be used: videos are recorded without sound.
    private(set) var isMicrophoneDenied = false
    /// Hot enough that the frame rate may drop.
    private(set) var isHot = false
    /// The Camera Control's overlay is showing: PicStrip's controls make way.
    private(set) var areControlsHidden = false
    /// Where the user tapped to focus, in view points, until the scene changes.
    private(set) var focusPoint: CGPoint?
    private(set) var exposureBias: Float = 0
    /// Set when a movie stands in for the camera.
    private(set) var fixture: VideoCameraFixture?

    let previewLayer = AVCaptureVideoPreviewLayer()
    @ObservationIgnored private let camera = VideoCaptureSession()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pinchStart: CGFloat?
    @ObservationIgnored private var biasStart: Float?

    var isRecording: Bool { recordingStarted != nil }
    var canChangeSettings: Bool { state == .running && !isRecording && !isFinishing }

    // MARK: Lifecycle

    func start() async {
        if VideoCameraFixture.isConfigured {
            fixture = await VideoCameraFixture.fromEnvironment()
            guard fixture != nil else {
                state = .unavailable
                return
            }
            setup = VideoCameraFixture.setup
            state = .running
            return
        }
        let recordsSound = await Self.microphoneAllowed()
        isMicrophoneDenied = !recordsSound
        previewLayer.session = camera.session
        previewLayer.videoGravity = .resizeAspect
        do {
            setup = try await camera.start(
                position: .back, quality: .preferred, recordsSound: recordsSound,
                previewLayer: previewLayer, handlers: handlers
            )
            zoomLevel = 1
            state = .running
            watchSession()
        } catch {
            state = .unavailable
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        camera.stop()
    }

    private var handlers: VideoCaptureSession.Handlers {
        .init(
            recordingEnded: { [weak self] url in
                Task { @MainActor in self?.finish(with: url) }
            },
            zoomChanged: { [weak self] level in
                self?.zoomLevel = level
            },
            controlsFullscreen: { [weak self] isFullscreen in
                Task { @MainActor in self?.areControlsHidden = isFullscreen }
            },
            hot: { [weak self] isHot in
                Task { @MainActor in self?.isHot = isHot }
            }
        )
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard canChangeSettings else { return }
        if fixture != nil {
            recordingStarted = .now
            return
        }
        guard let url = try? PrivateFileStore.exports.reserve(extension: "mov") else {
            recordingFailed = true
            return
        }
        recordingStarted = .now
        Task {
            if !(await camera.startRecording(to: url)) {
                recordingStarted = nil
                PrivateFileStore.exports.remove(url)
            }
        }
    }

    private func stopRecording() {
        guard isRecording, !isFinishing else { return }
        isFinishing = true
        Task {
            if let fixture {
                finish(with: try? PrivateFileStore.exports.copy(fixture.url, extension: "mov"))
            } else {
                finish(with: await camera.stopRecording())
            }
        }
    }

    private func finish(with url: URL?) {
        recordingStarted = nil
        isFinishing = false
        if isTorchOn { setTorch(false) }
        if let url { recording = url } else { recordingFailed = true }
    }

    func dismissFailure() { recordingFailed = false }

    // MARK: Settings

    func toggleResolution() {
        var quality = setup.quality
        quality.resolution = quality.resolution == .uhd ? .hd : .uhd
        setQuality(quality)
    }

    /// The next frame rate this resolution offers, round again after the fastest.
    func cycleFrameRate() {
        let rates = VideoFormatCatalog.frameRates(for: setup.quality.resolution, in: setup.formats)
        guard let index = rates.firstIndex(of: setup.quality.frameRate) else { return }
        var quality = setup.quality
        quality.frameRate = rates[(index + 1) % rates.count]
        setQuality(quality)
    }

    func toggleHDR() {
        var quality = setup.quality
        quality.isHDR.toggle()
        setQuality(quality)
    }

    func toggleStabilization() {
        var quality = setup.quality
        quality.isEnhancedStabilization.toggle()
        setQuality(quality)
    }

    var canUseHDR: Bool {
        VideoFormatCatalog.supportsHDR(setup.quality.resolution, frameRate: setup.quality.frameRate, in: setup.formats)
    }

    var canUseEnhancedStabilization: Bool {
        VideoFormatCatalog.supportsEnhancedStabilization(
            setup.quality.resolution, frameRate: setup.quality.frameRate, isHDR: setup.quality.isHDR, in: setup.formats
        )
    }

    var canChangeResolution: Bool { VideoFormatCatalog.resolutions(in: setup.formats).count > 1 }

    var canChangeFrameRate: Bool {
        VideoFormatCatalog.frameRates(for: setup.quality.resolution, in: setup.formats).count > 1
    }

    private func setQuality(_ quality: VideoQuality) {
        guard canChangeSettings else { return }
        if fixture != nil {
            setup.quality = VideoFormatCatalog.nearest(to: quality, in: setup.formats) ?? setup.quality
            return
        }
        Task {
            setup = await camera.setQuality(quality)
            zoomLevel = 1
        }
    }

    func flip() {
        guard canChangeSettings, setup.canFlip else { return }
        if fixture != nil { return }
        state = .starting
        Task {
            do {
                setup = try await camera.flip()
                zoomLevel = 1
                isTorchOn = false
                focusPoint = nil
                state = .running
            } catch {
                state = .unavailable
            }
        }
    }

    func setZoom(_ level: CGFloat) {
        guard state == .running else { return }
        zoomLevel = level
        camera.setZoom(level, animated: true)
    }

    /// A pinch on the preview, `scale` from where it started.
    func pinch(_ scale: CGFloat) {
        guard state == .running else { return }
        let start = pinchStart ?? zoomLevel
        pinchStart = start
        let minimum = setup.zoomLevels.first ?? 1
        zoomLevel = min(max(start * scale, minimum), setup.maximumZoomLevel)
        camera.setZoom(zoomLevel, animated: false)
    }

    func endPinch() { pinchStart = nil }

    func setTorch(_ isOn: Bool) {
        guard state == .running else { return }
        isTorchOn = isOn
        camera.setTorch(isOn)
    }

    /// `point` is in the preview's coordinates, which are the preview layer's.
    func focus(at point: CGPoint) {
        guard state == .running else { return }
        focusPoint = point
        exposureBias = 0
        guard fixture == nil else { return }
        camera.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        camera.setExposureBias(0)
    }

    /// A drag up or down after focusing: brighter or darker, by `stops` from where it started.
    func adjustExposure(by stops: Float) {
        guard state == .running, focusPoint != nil else { return }
        let start = biasStart ?? exposureBias
        biasStart = start
        let range = setup.exposureBiasRange
        exposureBias = min(max(start + stops, range.lowerBound), range.upperBound)
        if fixture == nil { camera.setExposureBias(exposureBias) }
    }

    func endExposureAdjustment() { biasStart = nil }

    // MARK: Observation

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Calls and other apps take the camera away; the view says so.  A
    /// recording under way ends with it, and is kept.
    private func watchSession() {
        let session = camera.session
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification, object: session) {
                guard let self else { return }
                if state == .running { state = .interrupted }
                isTorchOn = false
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification, object: session)
            where self?.state == .interrupted {
                self?.state = .running
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification, object: session) {
                self?.camera.resume()
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification) {
                guard let self, focusPoint != nil else { continue }
                focusPoint = nil
                exposureBias = 0
                camera.resetFocus()
            }
        })
    }
}
