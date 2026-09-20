import os
import XCTest
@testable import PicStrip

// MARK: - SegmentationMask

final class SegmentationMaskTests: XCTestCase {

    /// A black mask with one white rectangle, in pixels from the top-left.
    private func mask(width: Int, height: Int, white: CGRect?) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let white {
            // Core Graphics draws with a bottom-left origin; flip so `white` is top-left based.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(
                x: white.minX, y: CGFloat(height) - white.maxY, width: white.width, height: white.height
            ))
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testBoundingBox_isNormalisedFromTheTopLeft() throws {
        let image = try mask(width: 200, height: 100, white: CGRect(x: 20, y: 10, width: 60, height: 30))

        let box = try XCTUnwrap(SegmentationMask.boundingBox(of: image))

        XCTAssertEqual(box.minX, 0.10, accuracy: 0.011)
        XCTAssertEqual(box.minY, 0.10, accuracy: 0.011, "An object near the top must get a box near the top.")
        XCTAssertEqual(box.width, 0.30, accuracy: 0.015)
        XCTAssertEqual(box.height, 0.30, accuracy: 0.015)
    }

    func testBoundingBox_downsamplesLargeMasks() throws {
        let image = try mask(width: 2000, height: 1000, white: CGRect(x: 1000, y: 500, width: 500, height: 250))

        let box = try XCTUnwrap(SegmentationMask.boundingBox(of: image))

        XCTAssertEqual(box.minX, 0.5, accuracy: 0.01)
        XCTAssertEqual(box.minY, 0.5, accuracy: 0.01)
        XCTAssertEqual(box.width, 0.25, accuracy: 0.015)
        XCTAssertEqual(box.height, 0.25, accuracy: 0.015)
    }

    func testBoundingBox_isNilForAnEmptyMask() throws {
        XCTAssertNil(SegmentationMask.boundingBox(of: try mask(width: 64, height: 64, white: nil)))
    }

    /// A mask that covers everything is the background, not an object; a region
    /// from it would redact the whole photo on a single tap.
    func testBoundingBox_isNilWhenTheMaskCoversTheImage() throws {
        let image = try mask(width: 64, height: 64, white: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertNil(SegmentationMask.boundingBox(of: image))
    }
}

// MARK: - Consent flow

@MainActor
final class ObjectSelectionFlowTests: XCTestCase {

    private struct DownloadFailed: Error { }

    private func pngData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func loadedViewModel(_ selection: ObjectSelection) async throws -> ScrubberViewModel {
        let viewModel = ScrubberViewModel(scanImage: { _ in [] }, objectSelection: selection)
        await viewModel.loadData(try pngData())
        return viewModel
    }

    func testReadyModel_addsARegionWithoutAsking() async throws {
        let box = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.25)
        let viewModel = try await loadedViewModel(ObjectSelection(
            availability: { .ready }, downloadModel: { XCTFail("Must not download.") }, boundingBox: { _, _ in box }
        ))

        await viewModel.selectObject(at: CGPoint(x: 0.4, y: 0.4))

        XCTAssertFalse(viewModel.isAskingToDownloadObjectModel)
        XCTAssertEqual(viewModel.redactionRegions.map(\.rect), [box])
        XCTAssertTrue(viewModel.canUndo)
    }

    /// The app makes no network request of its own, so the OS download of the
    /// model must never start until the user has said yes.
    func testMissingModel_asksFirstAndDownloadsOnlyAfterConsent() async throws {
        let downloaded = OSAllocatedUnfairLock(initialState: false)
        let box = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let viewModel = try await loadedViewModel(ObjectSelection(
            availability: { downloaded.withLock { $0 } ? .ready : .needsDownload },
            downloadModel: { downloaded.withLock { $0 = true } },
            boundingBox: { _, _ in box }
        ))

        await viewModel.selectObject(at: CGPoint(x: 0.2, y: 0.2))

        XCTAssertTrue(viewModel.isAskingToDownloadObjectModel)
        XCTAssertFalse(downloaded.withLock { $0 }, "Nothing may be downloaded before the user agrees.")
        XCTAssertTrue(viewModel.redactionRegions.isEmpty)

        await viewModel.downloadObjectModelAndContinue()

        XCTAssertTrue(downloaded.withLock { $0 })
        XCTAssertEqual(viewModel.redactionRegions.map(\.rect), [box], "The tap that asked must be finished after the download.")
    }

    func testDecliningTheDownload_downloadsNothing() async throws {
        let viewModel = try await loadedViewModel(ObjectSelection(
            availability: { .needsDownload }, downloadModel: { XCTFail("Declined — must not download.") },
            boundingBox: { _, _ in nil }
        ))

        await viewModel.selectObject(at: CGPoint(x: 0.5, y: 0.5))
        viewModel.declineObjectModelDownload()
        await viewModel.downloadObjectModelAndContinue()   // no pending tap left to honour

        XCTAssertTrue(viewModel.redactionRegions.isEmpty)
    }

    func testFailedDownload_isReportedAndAddsNothing() async throws {
        let viewModel = try await loadedViewModel(ObjectSelection(
            availability: { .needsDownload }, downloadModel: { throw DownloadFailed() }, boundingBox: { _, _ in nil }
        ))

        await viewModel.selectObject(at: CGPoint(x: 0.5, y: 0.5))
        await viewModel.downloadObjectModelAndContinue()

        XCTAssertNotNil(viewModel.objectSelectionMessage)
        XCTAssertTrue(viewModel.redactionRegions.isEmpty)
        XCTAssertFalse(viewModel.isSelectingObject)
    }

    func testNothingUnderTheTap_isReported() async throws {
        let viewModel = try await loadedViewModel(ObjectSelection(
            availability: { .ready }, downloadModel: { }, boundingBox: { _, _ in nil }
        ))

        await viewModel.selectObject(at: CGPoint(x: 0.5, y: 0.5))

        XCTAssertNotNil(viewModel.objectSelectionMessage)
        XCTAssertTrue(viewModel.redactionRegions.isEmpty)
    }

    func testUnsupported_isNeverOffered() async throws {
        let viewModel = try await loadedViewModel(.unsupported)
        await viewModel.refreshObjectSelectionSupport()
        XCTAssertFalse(viewModel.isObjectSelectionSupported)

        await viewModel.selectObject(at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(viewModel.isAskingToDownloadObjectModel)
    }
}
