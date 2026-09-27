import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

/// Repeatable synthetic export measurements. Device/model, OS and configuration
/// are recorded by the test result bundle; these are not scanner speed claims.
@MainActor
final class ExportPerformanceTests: XCTestCase {
    private func fixture(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for row in stride(from: 0, to: height, by: 100) {
                UIColor(hue: CGFloat(row % 500) / 500, saturation: 0.5, brightness: 0.7, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: row, width: width, height: 40))
            }
        }.jpegData(compressionQuality: 0.9))
    }

    private func measureExport(width: Int, height: Int) throws {
        let data = try fixture(width: width, height: height)
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

    func testTwelveMegapixelVerifiedExport() throws { try measureExport(width: 4000, height: 3000) }
    func testTwentyFourMegapixelVerifiedExport() throws { try measureExport(width: 6000, height: 4000) }
}
