import AVFoundation
import CoreImage
import UIKit
import Vision

// MARK: - FaceCover

/// How one face is covered in a video.
nonisolated enum FaceCover: Hashable, Sendable {
    /// A strong blur — the default.
    case blur
    /// A black box.
    case solid
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

    struct Progress: Sendable {
        /// How much of the video has been looked at, 0 … 1.
        var fraction: Double
        /// Waiting for the phone to cool down before looking further.
        var isCooling: Bool
        /// A fresh look at the frame being scanned, a few times a second; `nil`
        /// between them.
        var glimpse: Glimpse?
        /// Faces and distinct text found so far.
        var faceCount = 0
        var textCount = 0
        /// The kinds of text and codes found so far, riskiest first, with how
        /// many of each — shown like the viewfinder's summary.
        var textKinds: [(type: PIIType, count: Int)] = []
    }

    /// The frame being scanned, small, with what was just found in it — for the
    /// scanning screen to show the work as it happens, drawn as the viewfinder
    /// draws it.  Boxes are normalised, top-left origin.
    struct Glimpse: Sendable {
        let image: CGImage
        let marks: [ScanMark]
        /// Every line of text read in the last read.
        let lines: [CGRect]
    }

    /// Frames are looked for faces in at this size: detection is as good as at
    /// full size (checked from 388 to 2173 pixels) and much quicker.
    static let detectionLongSide: CGFloat = 1280

    /// Videos longer than this get a warning that scanning and saving take a while.
    static let longVideoDuration: Double = 180

    /// Finds the faces in one upright frame: boxes normalised, top-left origin.
    typealias FaceDetector = @Sendable (CVPixelBuffer) async throws -> [CGRect]

    /// The faces, text and codes in the video at `url`.  `faceDetector`
    /// replaces Vision's face and head detection in tests.
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

        let (reader, output) = try await uprightReader(for: asset, track: track)
        defer { reader.cancelReading() }

        // Both face detectors where the OS has two: on real frames each finds
        // faces the other misses (revision 4 lost a face in a collage that
        // revision 3 found, and the reverse), so a face either finds is covered.
        // Body pose then adds the heads both miss — turned or looking down.
        let newest = PIIScanner.makeFaceRequest()
        let standard = DetectFaceRectanglesRequest()
        let faceRequests = (newest.revision == standard.revision ? [standard] : [newest, standard]).map(PIIScanner.onSimulatorCPU)
        // Small faces — a crowd, a photo within the picture — are missed in the
        // whole frame and found in overlapping tiles of the full-size frame.
        // Each tile is cut out as its own image: with `regionOfInterest`,
        // revision 3 reports boxes relative to the region and revision 4
        // relative to the whole frame, and mixing the two put covers on a bench.
        func tiledFaces(in pixels: CVPixelBuffer) async -> [[CGRect]] {
            var found: [[CGRect]] = []
            for tile in FaceTracking.tiles {
                guard let cut = detectionSize.crop(pixels, to: tile) else { continue }
                let handler = ImageRequestHandler(cut)
                for request in faceRequests {
                    guard let faces = try? await handler.perform(request) else { continue }
                    found.append(faces.map { FaceTracking.box(PIIScanner.swiftUIBox(from: $0.boundingBox.cgRect), inTile: tile) })
                }
            }
            return found
        }

        func visionFaces(in pixels: CVPixelBuffer, tiles fullSize: CVPixelBuffer?) async throws -> [CGRect] {
            let handler = ImageRequestHandler(pixels)
            var found: [[CGRect]] = []
            for request in faceRequests {
                if let faces = try? await handler.perform(request) {
                    found.append(faces.map { PIIScanner.swiftUIBox(from: $0.boundingBox.cgRect) })
                }
            }
            if found.isEmpty {
                // Neither ran: report why.
                _ = try await handler.perform(PIIScanner.onSimulatorCPU(DetectFaceRectanglesRequest()))
            }
            if let fullSize { found += await tiledFaces(in: fullSize) }
            let boxes = FaceTracking.union(found)
            let poses = (try? await handler.perform(PIIScanner.onSimulatorCPU(DetectHumanBodyPoseRequest()))) ?? []
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            let heads = poses.compactMap { pose -> CGRect? in
                func point(_ name: HumanBodyPoseObservation.JointName) -> CGPoint? {
                    guard let joint = pose.joint(for: name), joint.confidence >= HeadEstimate.minimumConfidence else { return nil }
                    return CGPoint(x: joint.location.x, y: 1 - joint.location.y)
                }
                return HeadEstimate.box(
                    head: [.nose, .leftEye, .rightEye, .leftEar, .rightEar].compactMap(point),
                    neck: point(.neck),
                    frameSize: size
                )
            }
            return HeadEstimate.merged(faces: boxes, heads: heads)
        }

        var faces = FaceTracking()
        var findings = FindingTracking()
        var scan = VideoScan()
        let registration = FrameRegistration()
        let detectionSize = FrameShrinker(longSide: detectionLongSide)
        let registrationSize = FrameShrinker(longSide: 480)
        let readEvery = max(1, Int((FindingTracking.sampleInterval / FaceTracking.sampleInterval).rounded()))
        var frameIndex = 0
        var nextSample = -Double.infinity
        var latestRead = FrameRead()
        var lastGlimpse = ContinuousClock.now - .seconds(1)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            // Should the composition still hand back every frame, skip to the next sample.
            guard time >= nextSample else { continue }
            nextSample = time + FaceTracking.sampleInterval * 0.9
            defer { frameIndex += 1 }

            while LiveAnalysisPacing.isTooHot(ProcessInfo.processInfo.thermalState) {
                progress(Progress(fraction: min(1, time / duration), isCooling: true))
                try await Task.sleep(for: .seconds(2))
            }

            var glimpse: Glimpse?
            do {
                let detection = detectionSize.shrink(pixels) ?? pixels
                let boxes: [CGRect]
                if let faceDetector {
                    boxes = try await faceDetector(pixels)
                } else {
                    boxes = try await visionFaces(
                        in: detection,
                        tiles: frameIndex.isMultiple(of: FaceTracking.tileEvery) ? pixels : nil
                    )
                }
                faces.add(boxes, at: time)

                // A small copy is plenty to see how the picture moved.  A jump of
                // over a quarter of the frame in a tenth of a second is a cut or a
                // misreading, not the camera.
                let small = registrationSize.shrink(detection) ?? detection
                let shift = await registration.shift(to: small, restart: frameIndex == 0)
                scan.path.add(shift.flatMap { hypot($0.dx, $0.dy) <= 0.25 ? $0 : nil }, at: time)

                // Text needs every pixel.
                if frameIndex.isMultiple(of: readEvery) {
                    let read = await PIIScanner.frameFindings(in: pixels, alwaysCover: alwaysCover)
                    findings.add(read.findings, at: time, path: scan.path)
                    latestRead = read
                }

                if ContinuousClock.now - lastGlimpse >= .milliseconds(250), let image = registrationSize.image(of: small) {
                    lastGlimpse = .now
                    glimpse = Glimpse(
                        image: image,
                        marks: boxes.map { ScanMark(type: .face, confidence: .high, box: $0) }
                            + latestRead.findings.map { ScanMark(type: $0.type, confidence: ConfidenceLevel(score: $0.score), box: $0.boundingBox) },
                        lines: latestRead.lines
                    )
                }
            } catch {
                // Vision reports a cancelled request as its own error.
                try Task.checkCancellation()
                throw error
            }
            let groups = FindingGroup.groups(of: findings.tracks)
            let kinds = Dictionary(grouping: groups, by: \.type)
                .map { (type: $0.key, count: $0.value.count) }
                .sorted { ($0.type.riskLevel, $0.count) > ($1.type.riskLevel, $1.count) }
            progress(Progress(
                fraction: min(1, time / duration), isCooling: false, glimpse: glimpse,
                faceCount: faces.tracks.count, textCount: groups.count, textKinds: kinds
            ))
        }
        if reader.status == .failed { throw reader.error ?? VideoCleaner.Failure.cannotExport }
        scan.faces = faces.tracks
        scan.findings = findings.tracks
        return scan
    }
}

// MARK: - ScanMark

/// One thing outlined in a scan glimpse.  Normalised, top-left origin.
nonisolated struct ScanMark: Sendable {
    let type: PIIType
    let confidence: ConfidenceLevel
    let box: CGRect
}

// MARK: - Upright frames

extension VideoScanner {
    /// A reader handing back `asset`'s frames upright, as the video is shown —
    /// the space covers are drawn in — at ten a second, within `timeRange`.
    nonisolated static func uprightReader(
        for asset: AVURLAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange? = nil
    ) async throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.frameDuration = CMTime(seconds: FaceTracking.sampleInterval, preferredTimescale: 600)
        // Otherwise frames follow the video track's timing and every frame
        // comes back: six times the work on a 60 fps video.
        configuration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.videoComposition = AVVideoComposition(configuration: configuration)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoCleaner.Failure.cannotExport }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoCleaner.Failure.cannotExport }
        return (reader, output)
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

    /// The part of `pixels` in `rect` (normalised, top-left origin), at full size,
    /// as an image of its own.
    func crop(_ pixels: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer? {
        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))
        // Core Image counts up from the bottom.
        let region = CGRect(
            x: rect.minX * width, y: (1 - rect.maxY) * height, width: rect.width * width, height: rect.height * height
        ).integral
        guard region.width >= 1, region.height >= 1 else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(region.width), Int(region.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
        guard let cut = made else { return nil }
        let image = CIImage(cvPixelBuffer: pixels)
            .cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        context.render(image, to: cut)
        return cut
    }

    /// `pixels` as an image, for showing.
    func image(of pixels: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        return context.createCGImage(image, from: image.extent)
    }
}

// MARK: - VideoRedactor

/// Covers faces and text in every frame of a video.  The same composition
/// drives the preview and the saved copy, so what plays is what is saved.
nonisolated enum VideoRedactor {

    struct FaceCoverage: Sendable {
        let track: FaceTrack
        let style: FaceCover
        /// Set on the timeline; otherwise the track's own.
        var range: ClosedRange<Double>?
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
        // Every cover is cut from the untouched frame and the covers are
        // stacked at the end.  Building each on the frame-so-far nested the
        // image graph one level per cover, and 21 faces in a collage overflowed
        // Core Image's stack on a device.
        var layers: [CIImage] = []

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
                cover = ImageRedactor.obscuredLayer(style == .pixelate ? .pixelate : .blur, blockSize: blockSize, of: frame)
                    ?? CIImage(color: .black)
            }
            layers.append(cover.cropped(to: rect))
        }

        for finding in plan.findings {
            guard let box = finding.track.coverBox(at: time, path: plan.path) else { continue }
            obscure(pixels(box), style: finding.style)
        }
        for face in plan.faces {
            guard let box = face.track.coverBox(at: time, within: face.range) else { continue }
            let full = pixels(box)
            obscure(full, style: face.style == .solid ? .solid : .blur)
            if let emoji = face.style.emoji, let glyph = glyphs[emoji] {
                let scale = max(full.width, full.height) * EmojiCover.coverage / max(glyph.extent.width, glyph.extent.height)
                let sized = glyph.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                layers.append(sized.transformed(by: CGAffineTransform(
                    translationX: full.midX - sized.extent.midX, y: full.midY - sized.extent.midY
                )))
            }
        }
        guard let covers = stacked(layers) else { return frame }
        return covers.composited(over: frame).cropped(to: extent)
    }

    /// `layers` in order, each over the ones before — combined in pairs, so the
    /// image graph grows with the logarithm of their number, not the number.
    static func stacked(_ layers: [CIImage]) -> CIImage? {
        var level = layers
        while level.count > 1 {
            var next: [CIImage] = []
            var index = 0
            while index < level.count {
                next.append(index + 1 < level.count ? level[index + 1].composited(over: level[index]) : level[index])
                index += 2
            }
            level = next
        }
        return level.first
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
