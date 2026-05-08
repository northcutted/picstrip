import UIKit
import XCTest
@testable import PicStrip

@MainActor
final class ScrubberViewModelPreviewTests: XCTestCase {

    func testReviewPreview_prefersRedactedImageWhenRedactionsAreSelected() async throws {
        let viewModel = ScrubberViewModel()
        let source = try makeImage(color: .green)
        let processed = try makeImage(color: .blue)
        let redacted = try makeImage(color: .red)

        viewModel.sourceUIImage = source
        viewModel.processedData = try XCTUnwrap(processed.pngData())
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
        viewModel.typesToRedact = [.email]

        XCTAssertEqual(
            try dominantColor(of: XCTUnwrap(viewModel.reviewPreviewUIImage)),
            try dominantColor(of: redacted),
            "Review preview must show the rendered redaction image before save."
        )
    }

    func testReviewPreview_usesProcessedImageWhenNoRedactionsAreSelected() async throws {
        let viewModel = ScrubberViewModel()
        let source = try makeImage(color: .green)
        let processed = try makeImage(color: .blue)
        let redacted = try makeImage(color: .red)

        viewModel.sourceUIImage = source
        viewModel.processedData = try XCTUnwrap(processed.pngData())
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
