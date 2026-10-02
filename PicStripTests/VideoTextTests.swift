import AVFoundation
import UIKit
import XCTest
@testable import PicStrip

// MARK: - Camera path and text tracks

final class FindingTrackingTests: XCTestCase {

    private func finding(_ type: PIIType = .email, x: CGFloat, y: CGFloat = 0.5, snippet: String = "alex@example.com") -> FrameFinding {
        FrameFinding(type: type, boundingBox: CGRect(x: x, y: y, width: 0.3, height: 0.05), score: 0.9, snippet: snippet)
    }

    func testThePathAddsUpAndInterpolates() {
        var path = CameraPath()
        path.add(nil, at: 0)
        path.add(CGVector(dx: -0.01, dy: 0), at: 0.1)
        path.add(CGVector(dx: -0.01, dy: 0.02), at: 0.2)
        XCTAssertEqual(path.offset(at: 0.2).dx, -0.02, accuracy: 1e-9)
        XCTAssertEqual(path.offset(at: 0.2).dy, 0.02, accuracy: 1e-9)
        XCTAssertEqual(path.offset(at: 0.15).dx, -0.015, accuracy: 1e-9)
        XCTAssertEqual(path.offset(at: 5).dx, -0.02, accuracy: 1e-9, "Past the end it holds.")
        let moved = path.move(CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), from: 0, to: 0.2)
        XCTAssertEqual(moved.minX, 0.48, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.52, accuracy: 1e-9)
    }

    func testTextFollowsTheCameraBetweenReads() throws {
        // The camera pans: everything slides left 0.02 every tenth of a second.
        var path = CameraPath()
        for step in 0...10 { path.add(step == 0 ? nil : CGVector(dx: -0.02, dy: 0), at: Double(step) * 0.1) }
        var tracking = FindingTracking()
        tracking.add([finding(x: 0.5)], at: 0, path: path)
        tracking.add([finding(x: 0.4)], at: 0.5, path: path)
        tracking.add([finding(x: 0.3)], at: 1.0, path: path)
        let tracks = tracking.tracks
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)

        let between = try XCTUnwrap(track.coverBox(at: 0.25, path: path))
        XCTAssertEqual(between.midX, 0.45 + 0.15, accuracy: 0.001, "Halfway between reads, it is where the camera put it.")
        let after = try XCTUnwrap(track.coverBox(at: 1.5, path: path))
        XCTAssertEqual(after.midX, 0.3 + 0.15, accuracy: 0.001, "The path holds still after its last point.")
        XCTAssertNil(track.coverBox(at: 1.0 + FindingTracking.hold + 0.01, path: path))
    }

    func testAPathThatDisagreesWithTheReadsIsNotTrusted() throws {
        // The measurement says the picture jumped right; the text stayed put.
        var path = CameraPath()
        path.add(nil, at: 0)
        path.add(CGVector(dx: 0.15, dy: 0), at: 0.2)
        var tracking = FindingTracking()
        tracking.add([finding(x: 0.4)], at: 0, path: path)
        tracking.add([finding(x: 0.4)], at: 0.5, path: path)
        let track = try XCTUnwrap(tracking.tracks.first)
        XCTAssertEqual(tracking.tracks.count, 1, "A wrong path does not split the track.")
        XCTAssertEqual(try XCTUnwrap(track.coverBox(at: 0.3, path: path)).midX, 0.55, accuracy: 0.001,
                       "The cover stays on the text, not on the path.")

        var jump = CameraPath()
        jump.add(nil, at: 0)
        jump.add(CGVector(dx: 0.5, dy: 0), at: 0.1)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.05)
        XCTAssertEqual(jump.move(box, from: 0, to: 0.1), box, "An implausible jump is not followed.")
    }

    func testDifferentKindsAndFarTextStaySeparate() {
        let path = CameraPath()
        var tracking = FindingTracking()
        tracking.add([finding(x: 0.1), finding(.phoneNumber, x: 0.1, y: 0.7, snippet: "+1 202 555 0147")], at: 0, path: path)
        tracking.add([finding(.phoneNumber, x: 0.1, y: 0.5, snippet: "+1 202 555 0147")], at: 0.5, path: path)
        let types = tracking.tracks.map(\.type)
        XCTAssertEqual(types.filter { $0 == .email }.count, 1)
        XCTAssertEqual(types.filter { $0 == .phoneNumber }.count, 1, "The phone number moved, it did not turn into the email.")
    }

    func testTheSameTextLaterIsOneRow() {
        let path = CameraPath()
        var tracking = FindingTracking()
        tracking.add([finding(x: 0.1)], at: 0, path: path)
        tracking.add([finding(x: 0.6, snippet: "Alex@Example.com ")], at: 5, path: path)
        tracking.add([finding(x: 0.6, snippet: "someone@else.org")], at: 9, path: path)
        let groups = FindingGroup.groups(of: tracking.tracks)
        XCTAssertEqual(tracking.tracks.count, 3)
        XCTAssertEqual(groups.map(\.tracks.count), [2, 1], "Case and spacing do not split a row.")
    }
}

// MARK: - Panning text movie

/// A camera panning across a checkered wall with a label on it: the content
/// slides left by `pan` (a share of the width) over the movie.
struct PanningTextMovie {
    let url: URL
    let seconds: Double
    let pan: CGFloat
    static let size = CGSize(width: 640, height: 360)
    static let text = "alex@example.com"

    /// The label's frame at `time`, normalised, top-left origin.
    func labelBox(at time: Double) -> CGRect {
        let shift = -pan * CGFloat(min(1, time / seconds))
        return CGRect(x: 0.3 + shift, y: 0.42, width: 0.45, height: 0.16)
    }

    static func make(seconds: Double = 2.5, pan: CGFloat = 0.15) async throws -> PanningTextMovie {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripText-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let movie = PanningTextMovie(url: url, seconds: seconds, pan: pan)
        // Fixed pseudo-random blocks, wider than the frame by the pan.
        var seed: UInt64 = 42
        func next() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        let wall = (0..<160).map { _ in
            (rect: CGRect(x: next() * size.width * (1 + pan) - 20, y: next() * size.height - 20,
                          width: 12 + next() * 50, height: 12 + next() * 50),
             shade: 0.3 + next() * 0.6)
        }
        let fps = 30
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let time = Double(frame) / Double(fps)
            let label = movie.labelBox(at: time)
            let shift = (label.minX - 0.3) * size.width
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                // The wall: scattered blocks that do not repeat, so the picture's
                // movement can be measured.
                UIColor(white: 0.7, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                for block in wall {
                    UIColor(white: block.shade, alpha: 1).setFill()
                    context.fill(block.rect.offsetBy(dx: shift, dy: 0))
                }
                let rect = CGRect(x: label.minX * size.width, y: label.minY * size.height,
                                  width: label.width * size.width, height: label.height * size.height)
                UIColor.white.setFill()
                context.fill(rect)
                let font = UIFont.systemFont(ofSize: 26, weight: .medium)
                let text = text as NSString
                let glyph = text.size(withAttributes: [.font: font])
                text.draw(at: CGPoint(x: rect.midX - glyph.width / 2, y: rect.midY - glyph.height / 2),
                          withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &made)
            let buffer = try XCTUnwrap(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return movie
    }
}

// MARK: - Scanning and covering text

final class VideoTextRedactionTests: XCTestCase {

    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        super.tearDown()
    }

    private func scanned() async throws -> (PanningTextMovie, VideoScan) {
        let movie = try await PanningTextMovie.make()
        cleanup.append(movie.url)
        let scan = try await VideoScanner.scan(movie.url, faceDetector: { _ in [] }) { _ in }
        return (movie, scan)
    }

    func testTheEmailIsReadAndThePanMeasured() async throws {
        try skipUnlessVisionModelsRunHere()
        let (movie, scan) = try await scanned()
        let emails = scan.findings.filter { $0.type == .email }
        XCTAssertEqual(emails.count, 1, "One email, one track: \(scan.findings.map { ($0.type, $0.samples.count) })")
        let track = try XCTUnwrap(emails.first)
        XCTAssertGreaterThanOrEqual(track.samples.count, 4, "Read about twice a second for 2.5 s.")
        XCTAssertEqual(FindingTracking.normalized(track.snippet), FindingTracking.normalized(PanningTextMovie.text))
        XCTAssertEqual(scan.path.offset(at: movie.seconds).dx, -movie.pan, accuracy: 0.04, "The pan was measured.")
        XCTAssertEqual(scan.path.offset(at: movie.seconds).dy, 0, accuracy: 0.03)

        // Between reads the cover is on the label.
        for time in [0.25, 0.75, 1.25, 1.75] {
            let cover = try XCTUnwrap(track.coverBox(at: time, path: scan.path), "at \(time)")
            let label = movie.labelBox(at: time)
            XCTAssertEqual(cover.midX, label.midX, accuracy: 0.05, "at \(time)")
            XCTAssertEqual(cover.midY, label.midY, accuracy: 0.05, "at \(time)")
        }
    }

    func testTheSavedCopyHasTheTextCovered() async throws {
        let (movie, scan) = try await scanned()
        let plan = VideoRedactor.Plan(
            findings: scan.findings.map { VideoRedactor.FindingCoverage(track: $0, style: .solid) },
            path: scan.path
        )
        let composition = try await VideoRedactor.composition(for: AVURLAsset(url: movie.url), plan: plan)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripTextOut-\(UUID().uuidString).mov")
        cleanup.append(output)
        try await VideoCleaner.clean(movie.url, to: output, videoComposition: composition)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in [0.25, 1.25, 2.2] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let label = movie.labelBox(at: time)
            // The middle of the label, where the text is.
            let text = CGRect(x: label.midX - 0.12, y: label.midY - 0.03, width: 0.24, height: 0.06)
            XCTAssertLessThan(try meanLuminance(of: frame, in: text), 25, "The text is under a solid cover at \(time).")
        }
    }

    private func meanLuminance(of image: CGImage, in rect: CGRect) throws -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0
        var count = 0
        for y in Int(rect.minY * CGFloat(height))..<Int(rect.maxY * CGFloat(height)) {
            for x in Int(rect.minX * CGFloat(width))..<Int(rect.maxX * CGFloat(width)) {
                let offset = (y * width + x) * 4
                total += 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
                count += 1
            }
        }
        return total / Double(max(count, 1))
    }
}

// MARK: - Taking over a picked video

final class PrivateFileStoreAdoptTests: XCTestCase {

    func testAPickedFileIsMovedInNotWrittenTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripAdopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateFileStore(directory: directory)
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripPicked-\(UUID().uuidString).mov")
        try Data("movie".utf8).write(to: picked)

        let adopted = try store.adopt(picked, extension: "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path), "Moved, not copied.")
        XCTAssertEqual(try Data(contentsOf: adopted), Data("movie".utf8))
        XCTAssertEqual(adopted.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    }
}
