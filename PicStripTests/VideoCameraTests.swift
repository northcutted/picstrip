import CoreGraphics
import XCTest
@testable import PicStrip

/// Choosing what to record with, from a camera's formats — the part of Video
/// mode that does not need a camera.
final class VideoFormatCatalogTests: XCTestCase {

    /// Roughly a recent iPhone's back camera: 4K HDR to 60 fps, 4K SDR to 120,
    /// HD HDR to 120, and binned and full-range duplicates.
    private let camera: [VideoFormatTraits] = [
        VideoFormatTraits(width: 3840, height: 2160, maxFrameRate: 60, supportsHDR: true, supportsEnhancedStabilization: true),
        VideoFormatTraits(width: 3840, height: 2160, maxFrameRate: 120, supportsHDR: false, supportsEnhancedStabilization: false),
        VideoFormatTraits(width: 1920, height: 1080, maxFrameRate: 120, supportsHDR: true, supportsEnhancedStabilization: true),
        VideoFormatTraits(width: 1920, height: 1080, maxFrameRate: 30, supportsHDR: false, supportsEnhancedStabilization: true, isBinned: true),
        VideoFormatTraits(width: 1920, height: 1080, maxFrameRate: 60, supportsHDR: false, supportsEnhancedStabilization: true),
        VideoFormatTraits(width: 1920, height: 1080, maxFrameRate: 60, supportsHDR: false, supportsEnhancedStabilization: true, isFullRange: true),
        // 4:3 photo formats are not offered for video.
        VideoFormatTraits(width: 4032, height: 3024, maxFrameRate: 30, supportsHDR: false, supportsEnhancedStabilization: false)
    ]

    func testTheChoicesComeFromTheFormats() {
        XCTAssertEqual(VideoFormatCatalog.resolutions(in: camera), [.hd, .uhd])
        XCTAssertEqual(VideoFormatCatalog.frameRates(for: .uhd, in: camera), [24, 30, 60, 120])
        XCTAssertTrue(VideoFormatCatalog.supportsHDR(.uhd, frameRate: 60, in: camera))
        XCTAssertFalse(VideoFormatCatalog.supportsHDR(.uhd, frameRate: 120, in: camera), "4K at 120 fps is SDR only here.")
        XCTAssertTrue(VideoFormatCatalog.supportsEnhancedStabilization(.uhd, frameRate: 30, isHDR: true, in: camera))
        XCTAssertFalse(VideoFormatCatalog.supportsEnhancedStabilization(.uhd, frameRate: 120, isHDR: false, in: camera))
        XCTAssertNil(VideoFormatTraits(width: 4032, height: 3024, maxFrameRate: 30, supportsHDR: false, supportsEnhancedStabilization: false).resolution)
    }

    func testTheNearestChoiceKeepsWhatItCan() {
        XCTAssertEqual(VideoFormatCatalog.nearest(to: .preferred, in: camera), .preferred, "4K 30 HDR is there as asked.")

        let fast = VideoQuality(resolution: .uhd, frameRate: 120, isHDR: true, isEnhancedStabilization: true)
        XCTAssertEqual(
            VideoFormatCatalog.nearest(to: fast, in: camera),
            VideoQuality(resolution: .uhd, frameRate: 120, isHDR: false, isEnhancedStabilization: false),
            "The resolution and frame rate win; HDR and stabilisation go where they cannot come along."
        )

        let hdOnly = camera.filter { $0.resolution == .hd }
        XCTAssertEqual(VideoFormatCatalog.nearest(to: .preferred, in: hdOnly)?.resolution, .hd, "No 4K: HD.")

        let slow = [VideoFormatTraits(width: 1920, height: 1080, maxFrameRate: 30, supportsHDR: false, supportsEnhancedStabilization: false)]
        let sixty = VideoQuality(resolution: .hd, frameRate: 60, isHDR: false, isEnhancedStabilization: false)
        XCTAssertEqual(VideoFormatCatalog.nearest(to: sixty, in: slow)?.frameRate, 30, "The nearest frame rate there is.")
        XCTAssertNil(VideoFormatCatalog.nearest(to: .preferred, in: []))
    }

    func testTheBestFormatHasFullDetailInVideoRange() throws {
        let hd30 = VideoQuality(resolution: .hd, frameRate: 30, isHDR: false, isEnhancedStabilization: false)
        let index = try XCTUnwrap(VideoFormatCatalog.bestFormat(for: hd30, in: camera))
        XCTAssertFalse(camera[index].isBinned, "Not the binned format, though it is the slowest that will do.")
        XCTAssertFalse(camera[index].isFullRange, "Video range, not the photo range.")
        XCTAssertFalse(camera[index].supportsHDR, "An SDR recording takes an SDR format where there is one.")
        XCTAssertEqual(camera[index].maxFrameRate, 60, "…and the slowest of those that is fast enough.")

        let hdr = VideoQuality(resolution: .hd, frameRate: 60, isHDR: true, isEnhancedStabilization: false)
        XCTAssertTrue(camera[try XCTUnwrap(VideoFormatCatalog.bestFormat(for: hdr, in: camera))].supportsHDR)
        XCTAssertNil(VideoFormatCatalog.bestFormat(
            for: VideoQuality(resolution: .uhd, frameRate: 120, isHDR: true, isEnhancedStabilization: false), in: camera
        ))
    }

    func testTheLensButtonsAreTheCameraApps() {
        // A triple camera: ultra wide at 0.5, switching to the main lens at 1 and the 4× telephoto.
        XCTAssertEqual(VideoFormatCatalog.lensLevels(minimum: 0.5, switchOvers: [1, 4], maximum: 60), [0.5, 1, 2, 4])
        XCTAssertEqual(VideoFormatCatalog.lensLevels(minimum: 1, switchOvers: [], maximum: 10), [1, 2], "One lens: 1× and its 2× crop.")
        XCTAssertEqual(VideoFormatCatalog.lensLevels(minimum: 1, switchOvers: [], maximum: 1.5), [1], "No 2× past what the lens reaches.")
        XCTAssertEqual(VideoFormatCatalog.lensLevels(minimum: 0.5, switchOvers: [1, 2], maximum: 20), [0.5, 1, 2], "2× once only.")
    }

    @MainActor
    func testZoomLabelsReadAsInTheCameraApp() {
        XCTAssertEqual(CameraZoomButtons.label(0.5, suffix: false), ".5")
        XCTAssertEqual(CameraZoomButtons.label(1, suffix: true), "1×")
        XCTAssertEqual(CameraZoomButtons.label(1.6, suffix: true), "1.6×")
        XCTAssertEqual(CameraZoomButtons.label(4, suffix: false), "4")
    }
}

/// Where the picture sits between the camera's control bands.
final class CameraFrameTests: XCTestCase {

    func testThePictureFitsBetweenTheBands() {
        // A tall region: an upright 9:16 video fills its height, centred.
        let tall = CameraFrame.fitted(9.0 / 16, in: CGSize(width: 440, height: 650))
        XCTAssertEqual(tall.height, 650)
        XCTAssertEqual(tall.width, 365.625, accuracy: 0.001)
        XCTAssertEqual(tall.midX, 220, accuracy: 0.001)
        // A 3:4 photo in the same region: full width, centred vertically.
        let photo = CameraFrame.fitted(3.0 / 4, in: CGSize(width: 440, height: 650))
        XCTAssertEqual(photo.width, 440)
        XCTAssertEqual(photo.midY, 325, accuracy: 0.001)
        XCTAssertEqual(CameraFrame.fitted(nil, in: CGSize(width: 10, height: 20)), CGRect(x: 0, y: 0, width: 10, height: 20))
    }
}
