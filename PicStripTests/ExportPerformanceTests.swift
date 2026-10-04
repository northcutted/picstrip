import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

/// Repeatable synthetic export measurements. Device/model, OS and configuration
/// are recorded by the test result bundle; these are not scanner speed claims.
@MainActor
final class ExportPerformanceTests: XCTestCase {
    private func fixture(width: Int, height: Int) throws -> Data {
        try XCTUnwrap(fixtureImage(width: width, height: height).jpegData(compressionQuality: 0.9))
    }

    private func fixtureImage(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for row in stride(from: 0, to: height, by: 100) {
                UIColor(hue: CGFloat(row % 500) / 500, saturation: 0.5, brightness: 0.7, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: row, width: width, height: 40))
            }
        }
    }

    /// The same pixels tagged the way a camera tags a portrait photo it stored sideways.
    private func sidewaysFixture(width: Int, height: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(fixtureImage(width: width, height: height).cgImage), [
            kCGImagePropertyOrientation: 6 as UInt32,
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func measureExport(_ data: Data) {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            autoreleasepool {
                do {
                    let result = try ExportPipeline.encode(data, plan: ExportPlan(preset: .highQualityJPEG, metadata: .allEnabled))
                    XCTAssertEqual(result.type, .jpeg)
                    XCTAssertFalse(result.outputFields.contains { !$0.isStructural })
                } catch { XCTFail("Export failed: \(error)") }
            }
        }
    }

    func testTwelveMegapixelVerifiedExport() throws { measureExport(try fixture(width: 4000, height: 3000)) }
    func testTwentyFourMegapixelVerifiedExport() throws { measureExport(try fixture(width: 6000, height: 4000)) }
    func testTwelveMegapixelSidewaysVerifiedExport() throws { measureExport(try sidewaysFixture(width: 4000, height: 3000)) }

    /// The strongest blur and a pixelated line on a 12 MP photo, as the editor exports them.
    func testTwelveMegapixelBlurAndPixelateRedaction() throws {
        let image = try XCTUnwrap(UIImage(data: fixture(width: 4000, height: 3000)))
        let specs = [
            RedactionSpec(rect: CGRect(x: 0.4, y: 0.3, width: 0.12, height: 0.16), style: .blur, color: .black, isEnabled: true, strength: 1),
            RedactionSpec(rect: CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.05), style: .pixelate, color: .black, isEnabled: true)
        ]
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let rendered = expectation(description: "Redaction rendered")
            Task.detached {
                let output = await ImageRedactor().redact(image: image, specs: specs)
                XCTAssertEqual(output?.size, image.size)
                rendered.fulfill()
            }
            wait(for: [rendered], timeout: 60)
        }
    }
}
