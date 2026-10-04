import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

/// Review & Share keeps its full-size render while it is open, without
/// changing what comes out.
@MainActor
final class ReviewAndBatchPipelineTests: XCTestCase {

    private static let face = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    private func whitePhoto(width: Int = 64, height: Int = 64) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
    }

    private func reviewedModel() async throws -> ScrubberViewModel {
        let finding = DetectionResult(type: .face, score: 0.99, instances: [
            DetectedInstance(snippet: "Face", boundingBox: Self.face, score: 0.99)
        ])
        let model = ScrubberViewModel(scanImage: { _ in [finding] })
        await model.loadData(try whitePhoto())
        try await waitUntil { !model.isScanningPII && !model.redactionRegions.isEmpty }
        model.typesToRedact = [.face]
        model.selectedExportFormat = .jpeg
        model.requestSave()
        try await waitUntil { model.activeSheet == .preSave && !model.isProcessing }
        return model
    }

    private func type(of data: Data?) -> UTType? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }

    /// The red channel at the centre of the exported photo.
    private func centreLevel(of data: Data?) throws -> UInt8 {
        let source = try XCTUnwrap(data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) })
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return pixel[0]
    }

    // MARK: - Review & Share

    func testChangingTheFormatInReviewOnlyEncodesAgain() async throws {
        let model = try await reviewedModel()
        let render = try XCTUnwrap(model.reviewRedaction?.image, "The open review keeps its render.")
        XCTAssertLessThan(try centreLevel(of: model.processedData), 40, "The face is covered.")

        model.selectedExportFormat = .png
        try await waitUntil { !model.isProcessing && self.type(of: model.processedData) == .png }
        XCTAssertTrue(model.reviewRedaction?.image === render, "A format change reuses the render.")
        XCTAssertLessThan(try centreLevel(of: model.processedData), 40, "The new format is covered too.")

        model.releaseReviewRedaction()
        XCTAssertNil(model.reviewRedaction, "A memory warning lets the render go.")
        model.selectedExportFormat = .jpeg
        try await waitUntil { !model.isProcessing && self.type(of: model.processedData) == .jpeg }
        XCTAssertLessThan(try centreLevel(of: model.processedData), 40, "Rendering again still covers the face.")
    }

    func testClosingTheReviewLetsTheRenderGoAndReopeningUnchangedEncodesNothing() async throws {
        let model = try await reviewedModel()
        let encoded = try XCTUnwrap(model.processedData)
        XCTAssertNotNil(model.reviewRedaction)

        model.activeSheet = nil
        XCTAssertNil(model.reviewRedaction, "Closing the review releases the full-size render.")

        model.requestSave()
        try await waitUntil { model.activeSheet == .preSave && !model.isProcessing }
        XCTAssertEqual(model.processedData, encoded)
        XCTAssertNil(model.reviewRedaction, "Nothing changed, so nothing was rendered again.")

        // Uncovering the face is a change: the next review encodes the photo again.
        model.activeSheet = nil
        let id = try XCTUnwrap(model.redactionRegions.first?.id)
        model.toggleRedactionRegion(id: id)
        model.requestSave()
        try await waitUntil { model.activeSheet == .preSave && !model.isProcessing }
        XCTAssertGreaterThan(try centreLevel(of: model.processedData), 200, "The uncovered face shows.")
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
