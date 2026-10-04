import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

/// Review & Share keeps its full-size render while it is open, and a batch
/// overlaps loading and saving with the cleaning — without changing what
/// comes out.
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

    // MARK: - Batch

    func testBatchOverlapsLoadingAndSavingButCleansOneAtATimeInOrder() async throws {
        let log = EventLog()
        let photos = try (0..<4).map { try whitePhoto(width: 20 + $0, height: 20) }
        let model = ScrubberViewModel(scan: { _, _, _ in
            await log.cleaningStarted()
            try? await Task.sleep(for: .milliseconds(60))
            await log.cleaningEnded()
            return ScanOutput(results: [], lines: [])
        }, semantic: .unavailable, objectSelection: .unsupported, alwaysCoverList: AlwaysCoverList(fileURL: nil))
        let sources = photos.enumerated().map { index, data in
            BatchSource(assetIdentifier: nil) {
                await log.record("load \(index)")
                try? await Task.sleep(for: .milliseconds(80))
                return data
            }
        }

        var saved: [Int] = []
        await model.runBatch(sources: sources, config: BatchConfig()) { data, _, _ in
            await log.record("save start")
            try? await Task.sleep(for: .milliseconds(80))
            let width = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyPixelWidth] as? Int
            saved.append((width ?? 0) - 20)
            await log.record("save end")
            return .saved
        }

        XCTAssertEqual(saved, [0, 1, 2, 3], "Every photo is saved, in order.")
        XCTAssertEqual(model.batchSucceededCount, 4)
        XCTAssertTrue(model.batchComplete)
        let maximum = await log.mostCleaningAtOnce
        XCTAssertEqual(maximum, 1, "Never more than one photo decoded at a time.")

        let events = await log.events
        let firstSaveEnd = try XCTUnwrap(events.firstIndex(of: "save end"))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "load 1")), firstSaveEnd, "The next photo loads while one is cleaned or saved.")
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "load 2")), firstSaveEnd, "The photo after it loads during the first save.")
        let saves = events.filter { $0.hasPrefix("save") }
        XCTAssertEqual(saves, Array(repeating: ["save start", "save end"], count: 4).flatMap { $0 }, "Saves never overlap.")
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

private actor EventLog {
    private(set) var events: [String] = []
    private(set) var mostCleaningAtOnce = 0
    private var cleaning = 0

    func record(_ event: String) { events.append(event) }

    func cleaningStarted() {
        cleaning += 1
        mostCleaningAtOnce = max(mostCleaningAtOnce, cleaning)
    }

    func cleaningEnded() { cleaning -= 1 }
}
