import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

@MainActor
final class PrivacyExportTests: XCTestCase {
    private func image() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        let bytes = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.3317, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.0307, kCGImagePropertyGPSLongitudeRef: "W"
        ]
        CGImageDestinationAddImage(output, try XCTUnwrap(bitmap.cgImage), [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return bytes as Data
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testFailedScanRemainsVisibleAndRequiresManualReview() async throws {
        let model = ScrubberViewModel(scanImage: { _ in throw PIIScannerError.textRecognitionFailed })
        await model.loadData(try image())
        try await settle { !model.isScanningPII }
        model.requestSave()
        try await settle { model.activeSheet == .preSave && !model.isProcessing }
        XCTAssertNotNil(model.scanFailureMessage)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.scanCoverage.requiresManualReview)
        XCTAssertFalse(model.canExport)
        model.manualReviewAcknowledged = true
        XCTAssertTrue(model.canExport)
        model.clearState()
        XCTAssertFalse(model.manualReviewAcknowledged)
        XCTAssertNil(model.scanFailureMessage)
    }

    func testPartialScanWithNoFindingsIsNotACompleteScan() async throws {
        var partial = ScanCoverage.complete
        partial[.faces] = .failed
        let coverage = partial
        let model = ScrubberViewModel(scan: { _, _, _ in ScanOutput(results: [], lines: [], coverage: coverage) })
        await model.loadData(try image())
        try await settle { !model.isScanningPII }
        model.requestSave()
        try await settle { model.activeSheet == .preSave && !model.isProcessing }
        XCTAssertEqual(model.scanCoverage[.faces], .failed)
        XCTAssertFalse(model.canExport)
    }

    func testAuditOmitsSensitiveValuesButDescribesRemovedFields() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        await model.loadData(try image())
        try await settle { !model.isScanningPII }
        model.requestSave()
        try await settle { model.activeSheet == .preSave && !model.isProcessing }
        let url = try XCTUnwrap(model.generateAuditJSON())
        defer { PrivateFileStore.exports.remove(url) }
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("37.3317"))
        XCTAssertFalse(json.contains("122.0307"))
        XCTAssertTrue(json.contains("GPS"))
        XCTAssertFalse(ImageProcessor.readAllFields(from: try XCTUnwrap(model.processedData)).contains { $0.category == "GPS" })
    }

    func testTypedSharingOffersTheEncodedImageFormat() async throws {
        for (preset, type) in [(ExportPreset.losslessPNG, UTType.png), (.highQualityJPEG, .jpeg), (.heicOriginal, .heic)] {
            let output = try ExportPipeline.encode(image(), plan: ExportPlan(preset: preset, metadata: .allEnabled))
            let share = try XCTUnwrap(CleanedImage(data: output.processed.data))
            let provider = NSItemProvider()
            provider.register(share)
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(type.identifier), "\(provider.registeredTypeIdentifiers)")
            let received = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { bytes, error in
                    if let bytes { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: error ?? ExportPipeline.ExportError.invalidOutput) }
                }
            }
            XCTAssertEqual(received, output.processed.data, "Receivers must get the verified encoded bytes")
            XCTAssertFalse(ImageProcessor.readAllFields(from: received).contains { $0.category == "GPS" })
        }
    }

    func testIncomingTransferPreservesOriginalBytesAndMetadata() async throws {
        let original = try image()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Incoming-\(UUID().uuidString).jpg")
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        for fileBacked in [true, false] {
            let provider = NSItemProvider()
            if fileBacked {
                provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
                    completion(url, false, nil)
                    return nil
                }
            } else {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
                    completion(original, nil)
                    return nil
                }
            }
            let received = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IncomingImage, Error>) in
                _ = provider.loadTransferable(type: IncomingImage.self) { continuation.resume(with: $0) }
            }
            XCTAssertEqual(received.data, original)
            XCTAssertTrue(ImageProcessor.readAllFields(from: received.data).contains { $0.category == "GPS" },
                          "Import must preserve metadata until the user reviews the original")
        }
    }

    func testUnattendedExportRejectsPartialCoverage() async throws {
        var incomplete = ScanCoverage.complete
        incomplete[.barcodes] = .failed
        let coverage = incomplete
        do {
            _ = try await ExportPipeline.clean(
                image(), plan: ExportPlan(preset: .losslessPNG, metadata: .allEnabled), redact: true,
                scan: { _, _, _ in ScanOutput(results: [], lines: [], coverage: coverage) }
            )
            XCTFail("An unattended export must not accept a failed detector")
        } catch ExportPipeline.ExportError.incompleteScan {
            // Required privacy behavior.
        }
    }

    func testPrivateFilesExpireAndConsumeInOrderWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PrivateFileStore(directory: folder, lifetime: 10)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let first = try store.write(Data("first".utf8), extension: "data", now: now)
        let second = try store.write(Data("second".utf8), extension: "data", now: now.addingTimeInterval(1))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // The simulator filesystem does not implement iOS data protection.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: second.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
        XCTAssertEqual(store.consume(now: now.addingTimeInterval(2)), .image(Data("first".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNil(store.consume(now: now.addingTimeInterval(12)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testPrivateFileAdmissionAlsoBoundsPreviouslyWrittenHandoffs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PrivateFileStore(directory: folder, maximumBytes: 16)
        defer { try? FileManager.default.removeItem(at: folder) }
        let oversized = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try store.write(oversized, extension: "data"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent("previous.data")
        try oversized.write(to: legacy)
        XCTAssertNil(store.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
