import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import PicStrip

// MARK: - Face tracks

final class FaceTrackingTests: XCTestCase {

    private func box(_ x: CGFloat, _ y: CGFloat = 0.4, size: CGFloat = 0.2) -> CGRect {
        CGRect(x: x, y: y, width: size, height: size)
    }

    func testAMovingFaceStaysOneTrack() {
        var tracking = FaceTracking()
        for step in 0..<20 {
            tracking.add([box(0.1 + CGFloat(step) * 0.02)], at: Double(step) * 0.1)
        }
        XCTAssertEqual(tracking.tracks.count, 1)
        XCTAssertEqual(tracking.tracks.first?.samples.count, 20)
    }

    func testTwoFacesKeepTheirOwnTracks() {
        var tracking = FaceTracking()
        for step in 0..<10 {
            let shift = CGFloat(step) * 0.01
            // Listed in a different order each frame: matching is by place, not order.
            let faces = [box(0.1 + shift), box(0.6 - shift)]
            tracking.add(step.isMultiple(of: 2) ? faces : faces.reversed(), at: Double(step) * 0.1)
        }
        let tracks = tracking.tracks
        XCTAssertEqual(tracks.count, 2)
        for track in tracks {
            let xs = track.samples.map(\.box.minX)
            XCTAssertEqual(xs.count, 10)
            XCTAssertTrue(xs == xs.sorted() || xs == xs.sorted(by: >), "Each track moves one way: \(xs)")
        }
    }

    func testAShortMissIsFilledAndALongOneStartsANewTrack() {
        var tracking = FaceTracking()
        tracking.add([box(0.2)], at: 0)
        tracking.add([box(0.22)], at: 1.6)     // missed for 1.6 s: same face
        tracking.add([box(0.24)], at: 4.0)     // missed for 2.4 s: a new track
        let tracks = tracking.tracks
        XCTAssertEqual(tracks.map(\.samples.count), [2, 1])
        XCTAssertEqual(tracking.trackCount, 2, "Finished and active tracks are both counted.")

        let filled = try? XCTUnwrap(tracks.first?.coverBox(at: 0.8))
        XCTAssertEqual(filled?.midX ?? 0, FaceTracking.padded(box(0.21)).midX, accuracy: 0.001,
                       "Between sightings the cover moves in a straight line.")
    }

    func testTheCoverIsPaddedAndHeldAroundTheSightings() throws {
        let track = FaceTrack(id: 0, samples: [
            .init(time: 1.0, box: box(0.2)),
            .init(time: 2.0, box: box(0.4))
        ])
        let early = try XCTUnwrap(track.coverBox(at: 1.0 - FaceTracking.hold + 0.01))
        XCTAssertEqual(early, FaceTracking.padded(box(0.2)))
        XCTAssertGreaterThan(early.width, 0.2 * 1.29)
        XCTAssertNotNil(track.coverBox(at: 2.0 + FaceTracking.hold - 0.01))
        XCTAssertNil(track.coverBox(at: 1.0 - FaceTracking.hold - 0.01))
        XCTAssertNil(track.coverBox(at: 2.0 + FaceTracking.hold + 0.01))
        XCTAssertEqual(try XCTUnwrap(track.coverBox(at: 1.5)).midX, FaceTracking.padded(box(0.3)).midX, accuracy: 0.0001)
    }

    func testAHeadIsDrawnAroundTheJointsOfATurnedFace() throws {
        // A profile: nose, one eye and one ear, then the neck below — in a portrait frame.
        let size = CGSize(width: 1080, height: 1920)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x / size.width, y: y / size.height) }
        let head = try XCTUnwrap(HeadEstimate.box(
            head: [point(500, 600), point(540, 580), point(620, 590)],
            neck: point(600, 720),
            frameSize: size
        ))
        let pixels = CGRect(x: head.minX * size.width, y: head.minY * size.height,
                            width: head.width * size.width, height: head.height * size.height)
        XCTAssertEqual(pixels.width, pixels.height, accuracy: 0.5, "Square in pixels, whatever the frame.")
        XCTAssertGreaterThan(pixels.width, 180, "About a head: wider than nose to ear, taller than to the neck.")
        XCTAssertLessThan(pixels.width, 320)
        for joint in [CGPoint(x: 500, y: 600), CGPoint(x: 620, y: 590)] {
            XCTAssertTrue(pixels.contains(joint), "\(joint) is inside \(pixels)")
        }
        XCTAssertNil(HeadEstimate.box(head: [point(500, 600)], neck: nil, frameSize: size), "One point is not a head.")
    }

    func testAHeadOnlyAddsWhatTheFaceDetectorMissed() {
        let face = CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.06)
        let sameHead = CGRect(x: 0.38, y: 0.17, width: 0.15, height: 0.09)
        let otherHead = CGRect(x: 0.7, y: 0.3, width: 0.12, height: 0.07)
        XCTAssertEqual(HeadEstimate.merged(faces: [face], heads: [sameHead, otherHead]), [face, otherHead])
    }

    func testTwoDetectorsFindEachFaceOnce() {
        let shared = CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
        let sharedAgain = CGRect(x: 0.21, y: 0.19, width: 0.1, height: 0.11)
        let onlyNewest = CGRect(x: 0.6, y: 0.2, width: 0.1, height: 0.1)
        let onlyOlder = CGRect(x: 0.4, y: 0.7, width: 0.08, height: 0.08)
        XCTAssertEqual(FaceTracking.union([[shared, onlyNewest], [sharedAgain, onlyOlder]]), [shared, onlyNewest, onlyOlder])
        let neighbour = CGRect(x: 0.31, y: 0.2, width: 0.1, height: 0.1)
        XCTAssertEqual(FaceTracking.union([[shared], [neighbour]]).count, 2, "Two people side by side stay two.")
        // A kiss, from the collage that showed it: the second face's centre is
        // inside the first face's box.
        let kisser = CGRect(x: 563, y: 551, width: 112, height: 112).applying(CGAffineTransform(scaleX: 1 / 1280, y: 1 / 1280))
        let kissed = CGRect(x: 614, y: 598, width: 81, height: 81).applying(CGAffineTransform(scaleX: 1 / 1280, y: 1 / 1280))
        XCTAssertEqual(FaceTracking.union([[kisser], [kissed]]).count, 2, "Cheek to cheek is still two faces.")
    }

    func testAFaceFoundInATileLandsWhereItIsInTheFrame() {
        // The bottom-right tile, top-left origin: x 0.4…1.0, y 0.4…1.0.
        let tile = CGRect(x: 0.4, y: 0.4, width: 0.6, height: 0.6)
        let inTile = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        let inFrame = FaceTracking.box(inTile, inTile: tile)
        XCTAssertEqual(inFrame.minX, 0.7, accuracy: 1e-9)
        XCTAssertEqual(inFrame.minY, 0.7, accuracy: 1e-9)
        XCTAssertEqual(inFrame.width, 0.06, accuracy: 1e-9)
    }

    func testATileIsCutFromTheRightPlace() throws {
        // A frame white on top, black below: the bottom tiles are mostly black.
        let size = CGSize(width: 200, height: 100)
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &made)
        let pixels = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<Int(size.height) {
            memset(base + y * rowBytes, y < 50 ? 255 : 0, rowBytes)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        let shrinker = FrameShrinker()
        let bottom = try XCTUnwrap(shrinker.crop(pixels, to: CGRect(x: 0.4, y: 0.4, width: 0.6, height: 0.6)))
        XCTAssertEqual(CVPixelBufferGetWidth(bottom), 120)
        XCTAssertEqual(CVPixelBufferGetHeight(bottom), 60)
        CVPixelBufferLockBaseAddress(bottom, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bottom, .readOnly) }
        let cut = try XCTUnwrap(CVPixelBufferGetBaseAddress(bottom)).assumingMemoryBound(to: UInt8.self)
        let cutRow = CVPixelBufferGetBytesPerRow(bottom)
        XCTAssertGreaterThan(cut[0], 200, "Its top rows (frame rows 40…49) are white.")
        XCTAssertLessThan(cut[(59 * cutRow)], 50, "Its bottom row (frame row 99) is black.")
    }

    func testFarApartFacesDoNotMatch() {
        XCTAssertEqual(FaceTracking.matchScore(box(0.0), box(0.7)), 0)
        XCTAssertGreaterThan(FaceTracking.matchScore(box(0.2), box(0.25)), 1, "Overlapping boxes beat near ones.")
        XCTAssertGreaterThan(FaceTracking.matchScore(box(0.2), box(0.45)), 0, "A face that jumped about its size still matches.")
    }
}

// MARK: - Face movies

/// A short movie of an emoji face gliding left to right on a pale background.
/// `YellowFaceDetector` finds the default 👨; Vision itself finds 🧑🏽 at
/// some sizes, which lets the real detector run on the simulator.
struct FaceMovie {
    let url: URL
    /// Upright (as shown) size.
    let displaySize: CGSize
    let seconds: Double
    let fontSize: CGFloat

    /// Where the face's centre is at `time`, normalised, top-left origin, upright.
    func faceCenter(at time: Double) -> CGPoint {
        CGPoint(x: 0.3 + 0.4 * min(1, time / seconds), y: 0.5)
    }

    /// With `rotated`, the frames are stored sideways and a transform turns them
    /// upright, as an iPhone stores portrait video.
    static func make(seconds: Double = 2, rotated: Bool = false, face: String = "👨", fontSize: CGFloat = 120) async throws -> FaceMovie {
        let stored = CGSize(width: 640, height: 360)
        let display = rotated ? CGSize(width: stored.height, height: stored.width) : stored
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripFaces-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(stored.width), AVVideoHeightKey: Int(stored.height)
        ])
        if rotated {
            // An iPhone's portrait transform: a quarter turn clockwise, moved back into view.
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: stored.height, ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(stored.width), kCVPixelBufferHeightKey as String: Int(stored.height)
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let movie = FaceMovie(url: url, displaySize: display, seconds: seconds, fontSize: fontSize)
        let fps = 30
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let time = Double(frame) / Double(fps)
            let center = movie.faceCenter(at: time)
            let displayPoint = CGPoint(x: center.x * display.width, y: center.y * display.height)
            // Stored (x, y) shows at (height - y, x) under the transform.
            let storedPoint = rotated ? CGPoint(x: displayPoint.y, y: stored.height - displayPoint.x) : displayPoint
            let buffer = try drawFrame(size: stored, face: face, fontSize: fontSize, at: storedPoint, angle: rotated ? -.pi / 2 : 0)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return movie
    }

    private static func drawFrame(size: CGSize, face: String, fontSize: CGFloat, at point: CGPoint, angle: CGFloat) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &made)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        // UIKit drawing: top-left origin.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor(red: 0.82, green: 0.86, blue: 0.9, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        // A stripe that stays put, to check the rest of the frame is untouched.
        UIColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 24))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: size.height))

        let font = UIFont.systemFont(ofSize: fontSize)
        let text = face as NSString
        let glyph = text.size(withAttributes: [.font: font])
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        text.draw(at: CGPoint(x: -glyph.width / 2, y: -glyph.height / 2), withAttributes: [.font: font])
        return buffer
    }
}

// MARK: - YellowFaceDetector

/// Stands in for Vision: the box around the frame's yellow pixels, which in a
/// `FaceMovie` are 👨's face and hair.  Runs on the same upright frames.
enum YellowFaceDetector {
    static let detect: VideoScanner.FaceDetector = { pixels in
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bytes + y * rowBytes + x * 4   // BGRA
                if pixel[2] > 180 && pixel[1] > 120 && pixel[0] < 110 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return [] }
        return [CGRect(
            x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width), height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )]
    }
}

// MARK: - Scanning and covering

final class VideoFaceRedactionTests: XCTestCase {

    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        super.tearDown()
    }

    private func movie(rotated: Bool = false) async throws -> FaceMovie {
        let movie = try await FaceMovie.make(rotated: rotated)
        cleanup.append(movie.url)
        return movie
    }

    private func scratchURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripFacesOut-\(UUID().uuidString).mov")
        cleanup.append(url)
        return url
    }

    /// The upright frame shown at `time`.
    private func frame(of url: URL, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// Mean and spread of the luminance in `rect` (normalised, top-left origin).
    private func luminance(of image: CGImage, in rect: CGRect) throws -> (mean: Double, spread: Double) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values: [Double] = []
        for y in Int(rect.minY * CGFloat(height))..<Int(rect.maxY * CGFloat(height)) {
            for x in Int(rect.minX * CGFloat(width))..<Int(rect.maxX * CGFloat(width)) {
                let offset = (y * width + x) * 4
                values.append(0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2]))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let spread = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        return (mean, spread)
    }

    private func faceRect(_ movie: FaceMovie, at time: Double) -> CGRect {
        let center = movie.faceCenter(at: time)
        let side = movie.fontSize * 0.8
        let width = side / movie.displaySize.width
        let height = side / movie.displaySize.height
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    func testTheFaceIsFoundAndFollowed() async throws {
        let movie = try await movie()
        let tracks = try await VideoScanner.scan(movie.url, faceDetector: YellowFaceDetector.detect) { _ in }.faces
        XCTAssertEqual(tracks.count, 1, "One face, one track: \(tracks.map(\.samples.count))")
        let track = try XCTUnwrap(tracks.first)
        XCTAssertGreaterThanOrEqual(track.samples.count, 15, "About ten looks a second over two seconds.")
        XCTAssertLessThanOrEqual(track.samples.count, 22, "Not every frame of the 30 fps movie: ten a second.")
        for sample in track.samples {
            let expected = movie.faceCenter(at: sample.time)
            XCTAssertEqual(sample.box.midX, expected.x, accuracy: 0.06, "at \(sample.time)")
            XCTAssertEqual(sample.box.midY, expected.y, accuracy: 0.08, "at \(sample.time)")
        }
    }

    func testAPortraitVideosFaceIsFoundWhereItIsShown() async throws {
        let movie = try await movie(rotated: true)
        let tracks = try await VideoScanner.scan(movie.url, faceDetector: YellowFaceDetector.detect) { _ in }.faces
        let track = try XCTUnwrap(tracks.max { $0.samples.count < $1.samples.count })
        XCTAssertGreaterThanOrEqual(track.samples.count, 15)
        let sample = try XCTUnwrap(track.representativeSample)
        let expected = movie.faceCenter(at: sample.time)
        XCTAssertEqual(sample.box.midX, expected.x, accuracy: 0.08)
        XCTAssertEqual(sample.box.midY, expected.y, accuracy: 0.06)
    }

    func testVisionFindsAFaceInTheVideo() async throws {
        try skipUnlessVisionModelsRunHere()
        let movie = try await FaceMovie.make(face: "🧑🏽", fontSize: 220)
        cleanup.append(movie.url)
        let tracks = try await VideoScanner.scan(movie.url) { _ in }.faces
        let track = try XCTUnwrap(tracks.max { $0.samples.count < $1.samples.count }, "Vision found no face.")
        XCTAssertGreaterThanOrEqual(track.samples.count, 10)
        let sample = try XCTUnwrap(track.representativeSample)
        XCTAssertEqual(sample.box.midX, movie.faceCenter(at: sample.time).x, accuracy: 0.1)
    }

    func testTheScanShowsItsWorkAsItGoes() async throws {
        let movie = try await movie()
        let seen = Glimpses()
        let scan = try await VideoScanner.scan(movie.url, faceDetector: YellowFaceDetector.detect) { progress in
            seen.add(progress)
        }
        let (glimpses, lastFaceCount) = seen.summary
        XCTAssertGreaterThanOrEqual(glimpses.count, 1, "At least one look at the frame being scanned.")
        XCTAssertTrue(glimpses.contains { $0.marks.contains { $0.type == .face } }, "The face is outlined in it.")
        XCTAssertEqual(lastFaceCount, scan.faces.count)
        if let glimpse = glimpses.first {
            XCTAssertLessThanOrEqual(max(glimpse.image.width, glimpse.image.height), 480, "Small: it is only for show.")
        }
    }

    func testCoversStackInOrderAndManyFacesStillRender() async throws {
        // Layers combine in pairs, but the later layer is still on top.
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 5, y: 0, width: 10, height: 10))
        let green = CIImage(color: .green).cropped(to: CGRect(x: 8, y: 0, width: 10, height: 10))
        let stack = try XCTUnwrap(VideoRedactor.stacked([red, blue, green, red.transformed(by: .init(translationX: 30, y: 0))]))
        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(stack, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 9, y: 1, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        XCTAssertGreaterThan(pixel[1], 200, "Green, the last of the three overlapping, is on top: \(pixel)")
        XCTAssertNil(VideoRedactor.stacked([]))

        // A crowd: a hundred faces in one frame render, off the main thread,
        // with every face covered.
        let frame = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 1280))
            .composited(over: CIImage(color: .white))
            .cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 1280))
        let faces = (0..<100).map { index in
            FaceTrack(id: index, samples: [.init(time: 0, box: CGRect(x: CGFloat(index % 10) * 0.1 + 0.02, y: CGFloat(index / 10) * 0.1 + 0.02, width: 0.05, height: 0.05))])
        }
        let plan = VideoRedactor.Plan(faces: faces.map { .init(track: $0, style: .emoji("🙂")) })
        let glyphs = ["🙂": try XCTUnwrap(VideoRedactor.glyphImage("🙂"))]
        let rendered = await Task.detached {
            let image = VideoRedactor.render(frame, at: 0, plan: plan, glyphs: glyphs)
            return CIContext().createCGImage(image, from: image.extent)
        }.value
        XCTAssertNotNil(rendered)
    }

    func testABlankVideoHasNoFaces() async throws {
        let movie = try await FaceMovie.make(seconds: 1, face: " ")
        cleanup.append(movie.url)
        let tracks = try await VideoScanner.scan(movie.url, faceDetector: YellowFaceDetector.detect) { _ in }.faces
        XCTAssertTrue(tracks.isEmpty)
    }

    private func coveredCopy(of movie: FaceMovie, style: FaceCover) async throws -> URL {
        let tracks = try await VideoScanner.scan(movie.url, faceDetector: YellowFaceDetector.detect) { _ in }.faces
        XCTAssertFalse(tracks.isEmpty)
        let composition = try await VideoRedactor.composition(
            for: AVURLAsset(url: movie.url),
            plan: VideoRedactor.Plan(faces: tracks.map { VideoRedactor.FaceCoverage(track: $0, style: style) })
        )
        let output = scratchURL()
        try await VideoCleaner.clean(movie.url, to: output, videoComposition: composition)
        return output
    }

    func testTheSavedCopyHasTheFaceBlurredAndTheRestUntouched() async throws {
        for rotated in [false, true] {
            let movie = try await movie(rotated: rotated)
            let output = try await coveredCopy(of: movie, style: .blur)

            let outputTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
            let outputTrack = try XCTUnwrap(outputTracks.first)
            let (size, transform) = try await outputTrack.load(.naturalSize, .preferredTransform)
            let shown = CGRect(origin: .zero, size: size).applying(transform).size
            XCTAssertEqual(abs(shown.width), movie.displaySize.width, accuracy: 1, "rotated: \(rotated)")
            XCTAssertEqual(abs(shown.height), movie.displaySize.height, accuracy: 1, "rotated: \(rotated)")

            for time in [0.0, 0.5, 1.0, 1.9] {
                let face = faceRect(movie, at: time)
                let before = try luminance(of: try await frame(of: movie.url, at: time), in: face)
                let after = try luminance(of: try await frame(of: output, at: time), in: face)
                XCTAssertGreaterThan(before.spread, 25, "The face has detail to hide (rotated: \(rotated), t \(time)).")
                XCTAssertLessThan(after.spread, before.spread * 0.45, "The face is blurred (rotated: \(rotated), t \(time)).")
            }
            // The stripe along the top is not touched.
            // Stored sideways, the top stripe shows down the right-hand side.
            let stripe = rotated ? CGRect(x: 0.95, y: 0.5, width: 0.03, height: 0.3) : CGRect(x: 0.5, y: 0, width: 0.3, height: 0.02)
            let stripeBefore = try luminance(of: try await frame(of: movie.url, at: 1), in: stripe)
            let stripeAfter = try luminance(of: try await frame(of: output, at: 1), in: stripe)
            XCTAssertEqual(stripeBefore.mean, stripeAfter.mean, accuracy: 6, "rotated: \(rotated)")
        }
    }

    func testAnEmojiCoverIsDrawnOverTheBlur() async throws {
        let movie = try await movie()
        let blurred = try await coveredCopy(of: movie, style: .blur)
        let emoji = try await coveredCopy(of: movie, style: .emoji("🐸"))
        let face = faceRect(movie, at: 1)
        let blurredFace = try luminance(of: try await frame(of: blurred, at: 1), in: face)
        let emojiFace = try luminance(of: try await frame(of: emoji, at: 1), in: face)
        XCTAssertGreaterThan(abs(emojiFace.mean - blurredFace.mean) + abs(emojiFace.spread - blurredFace.spread), 10,
                             "The frog is drawn on top of the blur.")
    }

    func testTheCoveredCopyHasNoHiddenDetails() async throws {
        let movie = try await movie()
        let output = try await coveredCopy(of: movie, style: .blur)
        let left = try await VideoCleaner.findings(in: output)
        XCTAssertTrue(left.allSatisfy { $0.kind == .other }, "Left: \(left)")
    }

}

/// Collects the scanner's progress reports, which arrive off the main actor.
private final class Glimpses: @unchecked Sendable {
    private let lock = NSLock()
    private var glimpses: [VideoScanner.Glimpse] = []
    private var faceCount = 0

    func add(_ progress: VideoScanner.Progress) {
        lock.lock()
        defer { lock.unlock() }
        if let glimpse = progress.glimpse { glimpses.append(glimpse) }
        faceCount = progress.faceCount
    }

    var summary: ([VideoScanner.Glimpse], Int) {
        lock.lock()
        defer { lock.unlock() }
        return (glimpses, faceCount)
    }
}

/// On the simulator, Vision's detection and tracking models run only once they
/// are moved to its CPU, which needs the iOS 27 SDK; the compatibility build
/// (Xcode 26) cannot, so tests that need the real models skip there.
func skipUnlessVisionModelsRunHere() throws {
    #if targetEnvironment(simulator) && !compiler(>=6.4)
    throw XCTSkip("Vision's models need the iOS 27 SDK to run on the simulator.")
    #endif
}
