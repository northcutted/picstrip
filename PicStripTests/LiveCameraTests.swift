import CoreVideo
import XCTest
@testable import PicStrip

// MARK: - AnalysisThrottle

final class AnalysisThrottleTests: XCTestCase {

    func testOneFrameAtATime_andNoMoreOftenThanTheInterval() {
        var throttle = AnalysisThrottle(minimumInterval: 0.25)

        XCTAssertTrue(throttle.begin(at: 10.0), "The first frame is analysed.")
        XCTAssertFalse(throttle.begin(at: 10.5), "A frame is still being analysed.")

        throttle.end()
        XCTAssertFalse(throttle.begin(at: 10.2), "Too soon after the last analysis started.")
        XCTAssertTrue(throttle.begin(at: 10.25))

        throttle.end()
        XCTAssertTrue(throttle.begin(at: 11.0))
    }
}

// MARK: - LiveOverlayGeometry

final class LiveOverlayGeometryTests: XCTestCase {

    func testPortraitVideoIsLetterboxedInATallerView() {
        let rect = LiveOverlayGeometry.videoRect(videoSize: CGSize(width: 1080, height: 1440), in: CGSize(width: 300, height: 600))
        XCTAssertEqual(rect, CGRect(x: 0, y: 100, width: 300, height: 400))
    }

    func testVideoIsPillarboxedInAWiderView() {
        let rect = LiveOverlayGeometry.videoRect(videoSize: CGSize(width: 1080, height: 1440), in: CGSize(width: 600, height: 400))
        XCTAssertEqual(rect, CGRect(x: 150, y: 0, width: 300, height: 400))
    }

    func testNoVideoYet_meansNoRect() {
        XCTAssertEqual(LiveOverlayGeometry.videoRect(videoSize: .zero, in: CGSize(width: 300, height: 600)), .zero)
    }

    /// A box must land on the letterboxed video, not on the view's black bars.
    func testBoxIsPlacedInsideTheVideoRect() {
        let video = CGRect(x: 0, y: 100, width: 300, height: 400)
        let rect = LiveOverlayGeometry.rect(for: CGRect(x: 0.5, y: 0.25, width: 0.2, height: 0.1), in: video)
        XCTAssertEqual(rect, CGRect(x: 150, y: 200, width: 60, height: 40))
    }
}

// MARK: - Per-frame scan

final class LiveBoxesTests: XCTestCase {

    private func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            // Camera frames are IOSurface-backed; Vision's pixel-buffer path expects that.
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()
        ]
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixelBuffer
    }

    /// The viewfinder's fast pass must box the same email and phone number the
    /// full scan finds in the fixture, in the same top-left normalised space.
    func testLiveBoxes_findThePIIInAFrame() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        nonisolated(unsafe) let frame = try pixelBuffer(from: image)

        let boxes = await PIIScanner.liveBoxes(in: frame)
        let full = try await PIIScanner().scanImage(data: data)

        XCTAssertFalse(boxes.isEmpty, "The fixture's email and phone number should be boxed.")
        for box in boxes {
            XCTAssertTrue(CGRect(x: -0.01, y: -0.01, width: 1.02, height: 1.02).contains(box), "\(box) is not normalised.")
        }
        let email = try XCTUnwrap(full.first { $0.type == .email }?.instances.first?.boundingBox)
        XCTAssertTrue(
            boxes.contains { abs($0.midY - email.midY) < 0.03 && $0.intersects(email) },
            "A live box should sit where the full scan finds the email (\(email)); got \(boxes)."
        )
    }
}
