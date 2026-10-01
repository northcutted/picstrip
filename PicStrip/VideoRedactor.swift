import AVFoundation
import CoreImage
import UIKit
import Vision

// MARK: - FaceCover

/// How one face is covered in a video.
nonisolated enum FaceCover: Hashable, Sendable {
    /// A strong blur — the default.
    case blur
    /// The emoji on top of the strong blur, as in photos.
    case emoji(String)

    var emoji: String? {
        if case .emoji(let emoji) = self { return emoji }
        return nil
    }
}

// MARK: - VideoScan

/// Everything found in one video.
nonisolated struct VideoScan: Sendable {
    var faces: [FaceTrack] = []
    var findings: [FindingTrack] = []
    /// How the picture moved, for carrying text boxes between reads.
    var path = CameraPath()

    var isEmpty: Bool { faces.isEmpty && findings.isEmpty }
}

// MARK: - VideoScanner

/// Finds what to cover in a video, reading it once in the order it plays:
/// faces in ten frames a second, and — in every fifth of those — text, codes
/// and Always Cover words.  Between frames it measures how the picture moved.
nonisolated enum VideoScanner {

    struct Progress: Equatable, Sendable {
        /// How much of the video has been looked at, 0 … 1.
        var fraction: Double
        /// Waiting for the phone to cool down before looking further.
        var isCooling: Bool
    }

    /// Videos longer than this get a warning that scanning and saving take a while.
    static let longVideoDuration: Double = 180

    /// Finds the faces in one upright frame: boxes normalised, top-left origin.
    typealias FaceDetector = @Sendable (CVPixelBuffer) async throws -> [CGRect]

    /// The faces, text and codes in the video at `url`.  `faceDetector`
    /// replaces Vision's face detector in tests.
    @concurrent
    static func scan(
        _ url: URL,
        alwaysCover: [String] = [],
        faceDetector: FaceDetector? = nil,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> VideoScan {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCleaner.Failure.cannotExport
        }
        let duration = max(try await asset.load(.duration).seconds, FaceTracking.sampleInterval)

        // Read through a plain composition: it turns every frame upright, as the
        // video is shown — the space the covers are drawn in — and its frame
        // duration hands back only the frames that are looked at.
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.frameDuration = CMTime(seconds: FaceTracking.sampleInterval, preferredTimescale: 600)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.videoComposition = AVVideoComposition(configuration: configuration)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoCleaner.Failure.cannotExport }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoCleaner.Failure.cannotExport }
        defer { reader.cancelReading() }

        // As for photos: the newest face detector, or the OS default where it fails.
        var newestRevisionFailed = false
        func visionFaces(in pixels: CVPixelBuffer) async throws -> [CGRect] {
            let handler = ImageRequestHandler(pixels)
            var faces: [FaceObservation]?
            if !newestRevisionFailed {
                faces = try? await handler.perform(PIIScanner.onSimulatorCPU(PIIScanner.makeFaceRequest()))
                newestRevisionFailed = faces == nil
            }
            if faces == nil {
                faces = try await handler.perform(PIIScanner.onSimulatorCPU(DetectFaceRectanglesRequest()))
            }
            return (faces ?? []).map { PIIScanner.swiftUIBox(from: $0.boundingBox.cgRect) }
        }

        var faces = FaceTracking()
        var findings = FindingTracking()
        var scan = VideoScan()
        let registration = FrameRegistration()
        let shrinker = FrameShrinker()
        let readEvery = max(1, Int((FindingTracking.sampleInterval / FaceTracking.sampleInterval).rounded()))
        var frameIndex = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            defer { frameIndex += 1 }

            while LiveAnalysisPacing.isTooHot(ProcessInfo.processInfo.thermalState) {
                progress(Progress(fraction: min(1, time / duration), isCooling: true))
                try await Task.sleep(for: .seconds(2))
            }

            do {
                let boxes: [CGRect]
                if let faceDetector {
                    boxes = try await faceDetector(pixels)
                } else {
                    boxes = try await visionFaces(in: pixels)
                }
                faces.add(boxes, at: time)

                // A small copy is plenty to see how the picture moved.  A jump of
                // over a quarter of the frame in a tenth of a second is a cut or a
                // misreading, not the camera.
                let small = shrinker.shrink(pixels) ?? pixels
                let shift = await registration.shift(to: small, restart: frameIndex == 0)
                scan.path.add(shift.flatMap { hypot($0.dx, $0.dy) <= 0.25 ? $0 : nil }, at: time)

                if frameIndex.isMultiple(of: readEvery) {
                    let found = await PIIScanner.frameFindings(in: pixels, alwaysCover: alwaysCover)
                    findings.add(found, at: time, path: scan.path)
                }
            } catch {
                // Vision reports a cancelled request as its own error.
                try Task.checkCancellation()
                throw error
            }
            progress(Progress(fraction: min(1, time / duration), isCooling: false))
        }
        if reader.status == .failed { throw reader.error ?? VideoCleaner.Failure.cannotExport }
        scan.faces = faces.tracks
        scan.findings = findings.tracks
        return scan
    }
}

// MARK: - FrameShrinker

/// Scales frames down for image registration, which needs the picture's
/// movement, not its detail.
nonisolated final class FrameShrinker: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let longSide: CGFloat

    init(longSide: CGFloat = 480) {
        self.longSide = longSide
    }

    func shrink(_ pixels: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))
        let scale = longSide / max(width, height)
        guard scale < 1 else { return pixels }
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
        guard let small = made else { return nil }
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(image, to: small)
        return small
    }
}

// MARK: - VideoRedactor

/// Covers faces and text in every frame of a video.  The same composition
/// drives the preview and the saved copy, so what plays is what is saved.
nonisolated enum VideoRedactor {

    struct FaceCoverage: Sendable {
        let track: FaceTrack
        let style: FaceCover
    }

    struct FindingCoverage: Sendable {
        let track: FindingTrack
        /// `.solid`, `.pixelate` or `.blur`.
        let style: RedactionStyle
    }

    /// What one copy covers.
    struct Plan: Sendable {
        var faces: [FaceCoverage] = []
        var findings: [FindingCoverage] = []
        var path = CameraPath()

        var isEmpty: Bool { faces.isEmpty && findings.isEmpty }
    }

    /// Plays or exports `asset` with `plan` drawn over it.
    static func composition(for asset: AVAsset, plan: Plan) async throws -> AVVideoComposition {
        var glyphs: [String: CIImage] = [:]
        for emoji in Set(plan.faces.compactMap(\.style.emoji)) {
            glyphs[emoji] = glyphImage(emoji)
        }
        let frozen = glyphs
        return try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            AVCIImageFilteringResult(resultImage: render(
                parameters.sourceImage, at: parameters.compositionTime.seconds, plan: plan, glyphs: frozen
            ))
        }
    }

    /// `frame` (upright, as displayed) with everything in `plan` on screen at
    /// `time` covered.
    ///
    /// Faces get the photo blur at full strength — a mosaic sized to the face,
    /// then smoothed — and an emoji on top where chosen, at its size in photos.
    /// Text and codes get their style.  Whatever cannot be blurred is painted
    /// black: nothing chosen is ever left showing.
    static func render(_ frame: CIImage, at time: Double, plan: Plan, glyphs: [String: CIImage]) -> CIImage {
        let extent = frame.extent
        var output = frame

        func pixels(_ box: CGRect) -> CGRect {
            CGRect(
                x: extent.minX + box.minX * extent.width,
                y: extent.minY + (1 - box.maxY) * extent.height,
                width: box.width * extent.width,
                height: box.height * extent.height
            )
        }

        func obscure(_ full: CGRect, style: RedactionStyle) {
            let rect = full.intersection(extent)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
            let cover: CIImage
            if style == .solid {
                cover = CIImage(color: .black)
            } else {
                let blockSize = RedactionStrength.blockSize(
                    shortSide: min(full.width, full.height), strength: RedactionStrength.range.upperBound
                )
                cover = ImageRedactor.obscuredLayer(style == .pixelate ? .pixelate : .blur, blockSize: blockSize, of: output)
                    ?? CIImage(color: .black)
            }
            output = cover.cropped(to: rect).composited(over: output)
        }

        for finding in plan.findings {
            guard let box = finding.track.coverBox(at: time, path: plan.path) else { continue }
            obscure(pixels(box), style: finding.style)
        }
        for face in plan.faces {
            guard let box = face.track.coverBox(at: time) else { continue }
            let full = pixels(box)
            obscure(full, style: .blur)
            if let emoji = face.style.emoji, let glyph = glyphs[emoji] {
                let scale = max(full.width, full.height) * EmojiCover.coverage / max(glyph.extent.width, glyph.extent.height)
                let sized = glyph.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                output = sized
                    .transformed(by: CGAffineTransform(translationX: full.midX - sized.extent.midX, y: full.midY - sized.extent.midY))
                    .composited(over: output)
            }
        }
        return output.cropped(to: extent)
    }

    /// `emoji` drawn once, large, on a clear background; frames scale it to each face.
    static func glyphImage(_ emoji: String) -> CIImage? {
        let font = UIFont.systemFont(ofSize: 480)
        let text = emoji as NSString
        let size = text.size(withAttributes: [.font: font])
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            text.draw(at: .zero, withAttributes: [.font: font])
        }
        return image.cgImage.map { CIImage(cgImage: $0) }
    }
}
