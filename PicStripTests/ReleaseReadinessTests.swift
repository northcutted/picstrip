import AppIntents
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

@MainActor
final class ReleaseReadinessTests: XCTestCase {
    private func sample() throws -> Data { try XCTUnwrap(SamplePhoto.makeData()) }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testImagePixelGeometryDoesNotMirrorInRightToLeftLayout() throws {
        let size = CGSize(width: 240, height: 160)
        let source = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 4, y: 4, width: 16, height: 16))
        }
        func render(_ direction: LayoutDirection, regions: [RedactionRegion], editing: Bool) throws -> Data {
            let view = ZoomableImagePreview(
                image: source, redactionRegions: regions,
                selectedRedactionRegionID: .constant(editing ? regions.first?.id : nil),
                isRedactionEditing: editing, showZoomHint: false
            )
            .frame(width: size.width, height: size.height)
            .environment(\.layoutDirection, direction)
            .environment(\.colorScheme, .light)
            .tint(.green)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        let plain = try render(.leftToRight, regions: [], editing: false)
        for enabled in [false, true] {
            for editing in [false, true] {
                var region = RedactionRegion.custom(rect: CGRect(x: 0.12, y: 0.3, width: 0.24, height: 0.22))
                region.isEnabled = enabled
                let leftToRight = try render(.leftToRight, regions: [region], editing: editing)
                let rightToLeft = try render(.rightToLeft, regions: [region], editing: editing)
                XCTAssertNotEqual(leftToRight, plain, "The renderer must include the region overlay")
                XCTAssertEqual(leftToRight, rightToLeft,
                               "Pixels, selection borders and resize handles must share physical image coordinates")
            }
        }
    }

    func testAdmissionRejectsPixelsAndBytesBeforeProcessing() throws {
        let data = try sample()
        XCTAssertThrowsError(try ImageResourceBudget(maximumPixels: 100, maximumBytes: data.count).validate(data)) {
            guard case ImageResourceBudget.AdmissionError.resolutionTooLarge = $0 else { return XCTFail("Wrong admission failure") }
        }
        XCTAssertThrowsError(try ImageResourceBudget(maximumPixels: 2_000_000, maximumBytes: 10).validate(data)) {
            guard case ImageResourceBudget.AdmissionError.fileTooLarge = $0 else { return XCTFail("Wrong admission failure") }
        }
        try ImageResourceBudget.editor.validate(data)
    }

    func testExplicitSmallerCopyPreservesMetadataForReview() throws {
        let data = try ImageResourceBudget.smallerCopy(sample(), maximumPixels: 200_000)
        let size = try XCTUnwrap(ImageProcessor.pixelSize(of: data))
        XCTAssertLessThanOrEqual(size.width * size.height, 200_000)
        XCTAssertTrue(ImageProcessor.readAllFields(from: data).contains { $0.category == "GPS" })
    }

    func testNominalCameraResolutionsFitTheirAdmissionBudgets() throws {
        let cases: [(ImageResourceBudget, Int, Int)] = [
            (.editor, 5712, 4284), (.background, 4032, 3024), (.shareExtension, 2880, 2160)
        ]
        for (budget, width, height) in cases {
            try autoreleasepool {
                let pixels = Data(repeating: 127, count: width * height)
                let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
                let image = try XCTUnwrap(CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                ))
                let bytes = NSMutableData()
                let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(encoder, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(encoder))
                XCTAssertNoThrow(try budget.validate(bytes as Data), "Nominal camera dimensions \(width)×\(height) must fit")
            }
        }
    }

    func testSampleCanBeReviewedAfterManualRegionEdit() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        await model.loadDemo()
        model.addCustomRedaction(rect: CGRect(x: 0.25, y: 0.4, width: 0.6, height: 0.2))
        model.requestSave()
        try await settle { model.activeSheet == .preSave || model.errorMessage != nil }
        XCTAssertNotNil(model.processedData, model.errorMessage ?? "Missing sample export")
        XCTAssertEqual(model.activeSheet, .preSave)
        XCTAssertTrue(model.isDemo)
    }

    func testClearingSessionRejectsALateCameraPage() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        let data = try sample()
        let started = expectation(description: "Capture encoding started")
        let release = AsyncStream<Void>.makeStream()
        let pages = CapturedPages(count: 1) { _ in
            started.fulfill()
            for await _ in release.stream { break }
            return data
        }
        let loading = Task { await model.loadCaptured(pages) }
        await fulfillment(of: [started], timeout: 2)
        model.clearState()
        release.continuation.yield(())
        release.continuation.finish()
        await loading.value
        XCTAssertNil(model.sourceUIImage)
        XCTAssertNil(model.processedData)
        XCTAssertFalse(model.isProcessing)
    }

    func testIntentFailureCleansEarlierFilesAndSuccessRequestsSystemCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PrivateFileStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = IntentFile(data: try sample(), filename: "private-address.jpg", type: .jpeg)
        let bad = IntentFile(data: Data("invalid".utf8), filename: "bad.jpg", type: .jpeg)
        do {
            _ = try await StripMetadataIntent.clean([good, bad], preset: .highQualityJPEG, store: store)
            XCTFail("A partially failed shortcut must not return images")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 0)
        let files = try await StripMetadataIntent.clean([good], preset: .highQualityJPEG, store: store)
        let file = try XCTUnwrap(files.first)
        XCTAssertTrue(file.removedOnCompletion)
        XCTAssertEqual(file.filename, "PicStrip.jpeg")
        XCTAssertNotNil(file.fileURL)
    }

    func testPresetsPreserveEditedGeometryAndAccessibleAdjustmentsUndoSeparately() throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        let initial = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.1)
        model.addCustomRedaction(rect: initial)
        let id = try XCTUnwrap(model.redactionRegions.first?.id)
        let moved = initial.offsetBy(dx: 0.1, dy: 0)
        model.adjustRedactionRegion(id: id, rect: moved)
        model.adjustRedactionRegion(id: id, rect: moved.offsetBy(dx: 0, dy: 0.1))
        model.undoRedaction()
        XCTAssertEqual(model.redactionRegions.first?.rect, moved)
        model.applySharingPurpose(.photo)
        XCTAssertEqual(model.selectedExportFormat, .jpeg)
        XCTAssertEqual(model.redactionRegions.first?.rect, moved)
        model.undoRedaction()
        XCTAssertEqual(model.redactionRegions.first?.rect, initial)
    }

    /// Names stay opt-in except for documents, where they are usually the point.
    func testSharingPresetsKeepNamesOptInExceptForDocuments() {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        model.detectedPII = [DetectionResult(type: .personName, score: 0.8, instances: []),
                             DetectionResult(type: .email, score: 0.9, instances: [])]
        for purpose in SharingPurpose.allCases {
            model.applySharingPurpose(purpose)
            XCTAssertEqual(model.typesToRedact.contains(.personName), purpose == .document)
            XCTAssertTrue(model.typesToRedact.contains(.email))
        }
    }

    func testDeletedAndMovedFindingsRemainInVisibleWarningCount() throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        model.typesToRedact = [.email]
        model.detectedPII = [DetectionResult(type: .email, score: 0.9,
            instances: [DetectedInstance(snippet: "alex@example.com", boundingBox: box, score: 0.9)])]
        XCTAssertEqual(model.findingsLeftVisible, 0)
        let id = try XCTUnwrap(model.redactionRegions.first?.id)
        model.adjustRedactionRegion(id: id, rect: box.offsetBy(dx: 0.4, dy: 0))
        XCTAssertEqual(model.findingsLeftVisible, 1)
        model.deleteRedactionRegion(id: id)
        XCTAssertEqual(model.findingsLeftVisible, 1)
    }

    func testFailedNameModelIsNotReportedAsComplete() async throws {
        let semantic = SemanticPII(findNames: { _ in [] }, scanNames: { _ in .init(names: [], status: .failed) })
        let model = ScrubberViewModel(scan: { _, _, _ in
            ScanOutput(results: [], lines: [ScannedLine(text: "Alex Example", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.1), confidence: 1)])
        }, semantic: semantic)
        await model.loadData(try sample())
        try await settle { !model.isScanningPII && !model.isFindingNames }
        XCTAssertEqual(model.scanCoverage[.names], .failed)
        model.clearState()
        XCTAssertFalse(model.isFindingNames)
    }

    func testBatchReportOmitsSensitiveValuesAndStopsBeforeNextSave() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        let data = try sample()
        let sources = (0..<3).map { _ in BatchSource(assetIdentifier: nil, load: { data }) }
        var saved = 0
        await model.runBatch(sources: sources, config: BatchConfig()) { _, _, _ in
            saved += 1
            model.cancelBatch()
            return .saved
        }
        XCTAssertEqual(saved, 1)
        let url = try XCTUnwrap(model.generateBatchAuditJSON())
        defer { PrivateFileStore.exports.remove(url) }
        let report = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(report.contains("Fictional sample camera"))
        XCTAssertTrue(report.contains("GPS"))
        XCTAssertEqual(model.batchReports.count, 1)
        XCTAssertNotNil(model.batchErrorMessage)
    }

    func testWindowPrivacyShieldCoversAndRestoresExistingWindows() throws {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter { !$0.isHidden }
        XCTAssertFalse(windows.isEmpty)
        let shield = AppPrivacyShield()
        shield.conceal()
        for window in windows { XCTAssertEqual(window.subviews.last?.accessibilityIdentifier, "privacyShield") }
        shield.reveal()
        for window in windows { XCTAssertFalse(window.subviews.contains { $0.accessibilityIdentifier == "privacyShield" }) }
    }

    func testRealOCRPrivateKeyCoversWholeBlockIncludingLowContrast() async throws {
        for contrast in [CGFloat(0.05), CGFloat(0.45)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1500, height: 700), format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1500, height: 700))
                let lines = ["-----BEGIN RSA PRIVATE KEY-----", "MIIEpAIBAAKCAQEAw6ZmQkLCvqD3O9BcCFOHjQA", "QWxwaGFCZXRhR2FtbWFEZWx0YUVwc2lsb24=", "-----END RSA PRIVATE KEY-----"]
                for (index, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 90, y: 100 + index * 120), withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 38, weight: .medium),
                        .foregroundColor: UIColor(white: contrast, alpha: 1)
                    ])
                }
            }
            let output = try await PIIScanner().scan(data: XCTUnwrap(image.pngData()))
            #if !targetEnvironment(simulator)
            XCTAssertFalse(output.coverage.requiresManualReview, "Required Vision checks should complete on this device")
            #endif
            // There are only four lines in the fixture. Do not assume OCR
            // preserves ambiguous base64 characters such as I/l/1.
            let keyLines = output.lines
            XCTAssertGreaterThanOrEqual(keyLines.count, 4, "OCR precondition: all four synthetic lines must be recognized")
            let blocks = try XCTUnwrap(output.results.first { $0.type == .genericPrivateKey })
            for line in keyLines {
                XCTAssertTrue(blocks.instances.contains { $0.boundingBox.contains(line.boundingBox) }, "Every key line needs full coverage")
            }
        }
    }
}
