import AppIntents
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

final class StripMetadataIntentTests: XCTestCase {

    private func jpegWithGPS() throws -> Data {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let output = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.3317,
                kCGImagePropertyGPSLatitudeRef: "N"
            ] as [CFString: Any]
        ]
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return output as Data
    }

    private func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testClean_removesGPSAndKeepsSourceFormatAndName() async throws {
        let input = IntentFile(data: try jpegWithGPS(), filename: "IMG_0042.JPG", type: .jpeg)
        XCTAssertNotNil(properties(of: input.data)[kCGImagePropertyGPSDictionary], "Fixture must carry GPS.")

        let cleaned = try await StripMetadataIntent.clean([input], preset: .matchSource)

        let output = try XCTUnwrap(cleaned.first)
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertNil(properties(of: output.data)[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(output.type, .jpeg)
        XCTAssertEqual(output.filename, "IMG_0042.jpeg")
    }

    func testClean_usesRequestedFormatForNameAndType() async throws {
        let input = IntentFile(data: try jpegWithGPS(), filename: "holiday.jpg", type: .jpeg)
        let cleaned = try await StripMetadataIntent.clean([input], preset: .losslessPNG)

        let output = try XCTUnwrap(cleaned.first)
        XCTAssertEqual(output.type, .png)
        XCTAssertEqual(output.filename, "holiday.png")
    }

    func testClean_reportsProgress() async throws {
        let files = try (1...3).map { IntentFile(data: try jpegWithGPS(), filename: "\($0).jpg", type: .jpeg) }
        let progress = Progress(totalUnitCount: 3)
        _ = try await StripMetadataIntent.clean(files, preset: .matchSource, progress: progress)
        XCTAssertEqual(progress.completedUnitCount, 3)
    }

    /// Fail closed: one unreadable file fails the whole run, so a shortcut can
    /// never forward an untouched original as though it had been cleaned.
    func testClean_throwsWhenAnyFileCannotBeCleaned() async throws {
        let good = IntentFile(data: try jpegWithGPS(), filename: "good.jpg", type: .jpeg)
        let bad = IntentFile(data: Data("not an image".utf8), filename: "bad.jpg", type: .jpeg)

        do {
            _ = try await StripMetadataIntent.clean([good, bad], preset: .matchSource)
            XCTFail("Expected an error for the undecodable file.")
        } catch let error as StripMetadataIntentError {
            guard case .couldNotClean(let filename) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(filename, "bad.jpg")
        }
    }

    func testClean_throwsForEmptyFile() async {
        let empty = IntentFile(data: Data(), filename: "empty.heic", type: .heic)
        do {
            _ = try await StripMetadataIntent.clean([empty], preset: .matchSource)
            XCTFail("Expected an error for the empty file.")
        } catch let error as StripMetadataIntentError {
            guard case .couldNotRead = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOutputFilename() {
        XCTAssertEqual(StripMetadataIntent.outputFilename(for: "IMG_1.HEIC", type: .png), "IMG_1.png")
        XCTAssertEqual(StripMetadataIntent.outputFilename(for: "scan.final.tiff", type: .jpeg), "scan.final.jpeg")
        XCTAssertEqual(StripMetadataIntent.outputFilename(for: "", type: .heic), "Image.heic")
    }
}

@MainActor
final class IntentRouterTests: XCTestCase {

    func testRequestStaysPendingUntilTheViewPresentsThePicker() {
        let router = IntentRouter()
        XCTAssertFalse(router.isBatchPickerRequested)

        router.requestBatchPicker()
        XCTAssertTrue(router.isBatchPickerRequested, "A cold-launch request must survive until the view appears.")

        router.batchPickerPresented()
        XCTAssertFalse(router.isBatchPickerRequested)
    }
}
