import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

@MainActor
final class ScrubberViewModelPreviewTests: XCTestCase {

    func testReviewPreview_prefersCachedProcessedPreviewWhenAvailable() async throws {
        let viewModel = ScrubberViewModel()
        let source = try makeImage(color: .green)
        let processed = try makeImage(color: .blue)
        let redacted = try makeImage(color: .red)

        viewModel.sourceUIImage = source
        viewModel.processedData = try XCTUnwrap(processed.pngData())
        viewModel.processedPreviewUIImage = processed
        viewModel.detectedPII = [
            DetectionResult(
                type: .email,
                score: 0.94,
                instances: [
                    DetectedInstance(
                        snippet: "test@example.com",
                        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
                        score: 0.94
                    )
                ]
            )
        ]
        viewModel.typesToRedact = [.email]
        // Legacy full-size redaction cache should not be needed when a decoded
        // processed preview is already available.
        viewModel.redactedUIImage = redacted

        XCTAssertEqual(
            try dominantColor(of: XCTUnwrap(viewModel.reviewPreviewUIImage)),
            try dominantColor(of: processed),
            "Review preview should use the cached processed preview without re-decoding export bytes."
        )
    }

    func testReviewPreview_usesProcessedImageWhenNoRedactionsAreSelected() async throws {
        let viewModel = ScrubberViewModel()
        let source = try makeImage(color: .green)
        let processed = try makeImage(color: .blue)
        let redacted = try makeImage(color: .red)

        viewModel.sourceUIImage = source
        viewModel.processedData = try XCTUnwrap(processed.pngData())
        viewModel.processedPreviewUIImage = processed
        viewModel.redactedUIImage = redacted
        viewModel.detectedPII = [
            DetectionResult(
                type: .email,
                score: 0.94,
                instances: [
                    DetectedInstance(
                        snippet: "test@example.com",
                        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
                        score: 0.94
                    )
                ]
            )
        ]
        viewModel.typesToRedact = []

        XCTAssertEqual(
            try dominantColor(of: XCTUnwrap(viewModel.reviewPreviewUIImage)),
            try dominantColor(of: processed),
            "Without selected redactions, review preview should show the processed output."
        )
    }

    func testRedactionPreviewResults_includeOnlySelectedSensitiveData() async {
        let viewModel = ScrubberViewModel()
        let email = DetectionResult(
            type: .email,
            score: 0.94,
            instances: [
                DetectedInstance(
                    snippet: "test@example.com",
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
                    score: 0.94
                )
            ]
        )
        let phone = DetectionResult(
            type: .phoneNumber,
            score: 0.88,
            instances: [
                DetectedInstance(
                    snippet: "555-1212",
                    boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.1),
                    score: 0.88
                )
            ]
        )

        viewModel.detectedPII = [email, phone]
        viewModel.typesToRedact = [.email]

        XCTAssertEqual(viewModel.redactionPreviewResults.map(\.type), [.email])
    }

    func testFocusPIIResult_temporarilySelectsSensitiveData() async {
        let viewModel = ScrubberViewModel()
        let email = DetectionResult(
            type: .email,
            score: 0.94,
            instances: [
                DetectedInstance(
                    snippet: "test@example.com",
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
                    score: 0.94
                )
            ]
        )

        viewModel.focusPIIResult(email)

        XCTAssertEqual(viewModel.selectedPIIResult, email)

        // Poll until selectedPIIResult clears (production delay is 1.5 s).
        // A fixed sleep is too fragile under CI scheduler load; use a generous
        // timeout with a tight poll interval instead.
        let deadline = Date().addingTimeInterval(5)
        while viewModel.selectedPIIResult != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertNil(viewModel.selectedPIIResult, "selectedPIIResult should clear within 5 s after focusPIIResult")
    }

    /// `loadData` should populate metadata catalogues from the source bytes but
    /// MUST NOT eagerly re-encode the image.  The encode is deferred to
    /// `prepareAndReview` so picking a photo doesn't pay full-image-encode cost.
    func testLoadData_catalogsMetadataWithoutEagerEncoding() async throws {
        let viewModel = ScrubberViewModel()
        let data = try makeJPEGWithMetadata()

        await viewModel.loadData(data)

        // Settle the OCR task so the assertions are deterministic.
        let scanDeadline = Date().addingTimeInterval(5)
        while viewModel.isScanningPII, Date() < scanDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNotNil(viewModel.pendingStrippedMetadata,
                        "pendingStrippedMetadata must populate from source props on load")
        XCTAssertGreaterThan(viewModel.pendingStrippedMetadata?.fields.count ?? 0, 0,
                             "Fixture carries EXIF/GPS; pendingStrippedMetadata should not be empty")
        XCTAssertNotNil(viewModel.allSourceMetadata,
                        "allSourceMetadata must populate from source props on load")
        XCTAssertNotNil(viewModel.sourceUTType,
                        "sourceUTType must populate from CGImageSource on load")
        XCTAssertNil(viewModel.processedData,
                     "Eager encode is deferred; processedData must remain nil after load")
        XCTAssertNil(viewModel.processedPreviewUIImage,
                     "Eager encode is deferred; processedPreviewUIImage must remain nil after load")
        XCTAssertTrue(viewModel.outputFileFields.isEmpty,
                      "outputFileFields is populated only on save; should be empty after load")
        XCTAssertFalse(viewModel.isProcessing,
                       "isProcessing must clear once catalog completes")
    }

    private func makeJPEGWithMetadata() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard
            let ctx = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ),
            let cgImage = ctx.makeImage()
        else { throw XCTSkip("Could not create 1×1 CGImage for test fixture") }

        let outputData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outputData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw XCTSkip("Could not create destination for test fixture") }

        let metadata: [CFString: Any] = [
            kCGImagePropertyOrientation: 1 as UInt32,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:01:01 12:00:00",
                kCGImagePropertyExifUserComment: "PicStripTestFixture"
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.3317,
                kCGImagePropertyGPSLongitude: -122.0307
            ] as [CFString: Any]
        ]
        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("Finalize failed for test fixture")
        }
        return outputData as Data
    }

    private func makeImage(color: UIColor) throws -> UIImage {
        let size = CGSize(width: 4, height: 4)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func dominantColor(of image: UIImage) throws -> [UInt8] {
        guard let cgImage = image.cgImage else {
            throw XCTSkip("Test image must have CGImage backing.")
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create bitmap context.")
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }
}
