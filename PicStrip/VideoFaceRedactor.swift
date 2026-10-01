import AVFoundation
import CoreImage
import CoreML
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

// MARK: - VideoFaceScanner

/// Finds the faces in a video: looks at ten frames a second, in the order they
/// play, and links what it finds into `FaceTrack`s.
nonisolated enum VideoFaceScanner {

    struct Progress: Equatable, Sendable {
        /// How much of the video has been looked at, 0 … 1.
        var fraction: Double
        /// Waiting for the phone to cool down before looking further.
        var isCooling: Bool
    }

    /// Videos longer than this get a warning that scanning and saving take a while.
    static let longVideoDuration: Double = 180

    /// Finds the faces in one upright frame: boxes normalised, top-left origin.
    typealias Detector = @Sendable (CVPixelBuffer) async throws -> [CGRect]

    /// The faces in the video at `url`, followed from frame to frame.  `detector`
    /// replaces Vision's face detector in tests.
    @concurrent
    static func scan(
        _ url: URL,
        detector: Detector? = nil,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> [FaceTrack] {
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

        // As for photos: the newest detector, or the OS default where it fails.
        var newestRevisionFailed = false
        func visionFaces(in pixels: CVPixelBuffer) async throws -> [CGRect] {
            let handler = ImageRequestHandler(pixels)
            var faces: [FaceObservation]?
            if !newestRevisionFailed {
                faces = try? await handler.perform(runnable(PIIScanner.makeFaceRequest()))
                newestRevisionFailed = faces == nil
            }
            if faces == nil {
                faces = try await handler.perform(runnable(DetectFaceRectanglesRequest()))
            }
            return (faces ?? []).map { PIIScanner.swiftUIBox(from: $0.boundingBox.cgRect) }
        }

        var tracking = FaceTracking()
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds

            while LiveAnalysisPacing.isTooHot(ProcessInfo.processInfo.thermalState) {
                progress(Progress(fraction: min(1, time / duration), isCooling: true))
                try await Task.sleep(for: .seconds(2))
            }

            let boxes: [CGRect]
            if let detector {
                boxes = try await detector(pixels)
            } else {
                boxes = try await visionFaces(in: pixels)
            }
            tracking.add(boxes, at: time)
            progress(Progress(fraction: min(1, time / duration), isCooling: false))
        }
        if reader.status == .failed { throw reader.error ?? VideoCleaner.Failure.cannotExport }
        return tracking.tracks
    }

    /// `request` as it can run here.  The simulator's GPU cannot create the face
    /// model's inference context; its CPU can.
    private static func runnable(_ request: DetectFaceRectanglesRequest) -> DetectFaceRectanglesRequest {
        #if targetEnvironment(simulator)
        var request = request
        let cpu = request.supportedComputeStageDevices[.main]?.first {
            if case .cpu = $0 { return true }
            return false
        }
        if let cpu { request.setComputeDevice(cpu, for: .main) }
        return request
        #else
        return request
        #endif
    }
}

// MARK: - VideoFaceRedactor

/// Covers faces in every frame of a video.  The same composition drives the
/// preview and the saved copy, so what plays is what is saved.
nonisolated enum VideoFaceRedactor {

    struct Cover: Sendable {
        let track: FaceTrack
        let style: FaceCover
    }

    /// Plays or exports `asset` with `covers` drawn over its faces.
    static func composition(for asset: AVAsset, covers: [Cover]) async throws -> AVVideoComposition {
        var glyphs: [String: CIImage] = [:]
        for emoji in Set(covers.compactMap(\.style.emoji)) {
            glyphs[emoji] = glyphImage(emoji)
        }
        let frozen = glyphs
        return try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            AVCIImageFilteringResult(resultImage: render(
                parameters.sourceImage, at: parameters.compositionTime.seconds, covers: covers, glyphs: frozen
            ))
        }
    }

    /// `frame` (upright, as displayed) with every face on screen at `time` covered.
    ///
    /// Each face is blurred the way photos are at full strength: a mosaic sized
    /// to the face, then smoothed.  An emoji goes on top of that, at the size it
    /// has in photos.  If the blur cannot be made, the face is painted black —
    /// a face is never left showing.
    static func render(_ frame: CIImage, at time: Double, covers: [Cover], glyphs: [String: CIImage]) -> CIImage {
        let extent = frame.extent
        var output = frame
        for cover in covers {
            guard let box = cover.track.coverBox(at: time) else { continue }
            let full = CGRect(
                x: extent.minX + box.minX * extent.width,
                y: extent.minY + (1 - box.maxY) * extent.height,
                width: box.width * extent.width,
                height: box.height * extent.height
            )
            let rect = full.intersection(extent)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }

            let blockSize = RedactionStrength.blockSize(
                shortSide: min(full.width, full.height), strength: RedactionStrength.range.upperBound
            )
            let blurred = ImageRedactor.obscuredLayer(.blur, blockSize: blockSize, of: output)
                ?? CIImage(color: .black)
            output = blurred.cropped(to: rect).composited(over: output)

            if let emoji = cover.style.emoji, let glyph = glyphs[emoji] {
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
