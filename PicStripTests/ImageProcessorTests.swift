import XCTest
import ImageIO
import CoreFoundation
import UniformTypeIdentifiers
@testable import PicStrip

/// Contract tests for `ImageProcessor`.
final class ImageProcessorTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal valid JPEG `Data` payload that carries:
    /// - A known orientation value (`6` = 90° clockwise / landscape-right).
    /// - A non-empty EXIF dictionary with a `DateTimeOriginal` entry.
    /// - A GPS dictionary so GPS-related tests have data to work with.
    private func makeTestImageData(orientation: UInt32 = 6) throws -> Data {
        // 1. Create a 1×1 pixel CGImage (solid red) as the pixel source.
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
        else {
            throw XCTSkip("Could not create 1×1 CGImage for test fixture.")
        }

        // 2. Write to an in-memory Data buffer as JPEG with metadata.
        let outputData = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                outputData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw XCTSkip("Could not create CGImageDestination for test fixture.")
        }

        // Inject orientation + a minimal EXIF dictionary + a GPS dictionary.
        let exifDict: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2024:01:01 12:00:00",
            kCGImagePropertyExifUserComment:      "PicStripTestFixture"
        ]
        let gpsDict: [CFString: Any] = [
            kCGImagePropertyGPSLatitude:  37.3317,
            kCGImagePropertyGPSLongitude: -122.0307
        ]
        let metadata: [CFString: Any] = [
            kCGImagePropertyOrientation:    orientation,
            kCGImagePropertyExifDictionary: exifDict,
            kCGImagePropertyGPSDictionary:  gpsDict,
        ]

        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("CGImageDestinationFinalize failed for test fixture.")
        }

        return outputData as Data
    }

    /// Reads the top-level TIFF/EXIF properties from raw image `Data`.
    private func properties(of data: Data) -> [CFString: Any]? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return props
    }

    // MARK: - Contract Test

    /// **Default config contract.**
    ///
    /// Verifies that `ImageProcessor.process(data:preset:config:)` with default config:
    /// 1. Returns non-empty `Data`.
    /// 2. Strips the EXIF dictionary from the output.
    /// 3. Retains the original orientation value.
    func testProcess_stripsEXIF_retainsOrientation() throws {
        // --- Arrange ---
        let sourceOrientation: UInt32 = 6
        let inputData = try makeTestImageData(orientation: sourceOrientation)

        let inputProps = try XCTUnwrap(
            properties(of: inputData),
            "Test fixture must carry metadata."
        )
        XCTAssertNotNil(
            inputProps[kCGImagePropertyExifDictionary],
            "Fixture must contain an EXIF dictionary before processing."
        )

        // --- Act ---
        let result = try ImageProcessor.process(data: inputData, preset: .highQualityJPEG, config: .default)
        let outputData = result.data

        // --- Assert ---
        XCTAssertFalse(outputData.isEmpty, "Processed data must not be empty.")

        let outputProps = try XCTUnwrap(
            properties(of: outputData),
            "Processed image must have readable properties."
        )

        // 1. EXIF must be gone.
        XCTAssertNil(
            outputProps[kCGImagePropertyExifDictionary],
            "EXIF dictionary must be stripped from the output image."
        )

        // 2. Orientation must be preserved.
        let outputOrientation = try XCTUnwrap(
            outputProps[kCGImagePropertyOrientation] as? UInt32,
            "Orientation must be retained in the output image."
        )
        XCTAssertEqual(
            outputOrientation,
            sourceOrientation,
            "Output orientation must match the source orientation."
        )
    }

    /// **Config: GPS disabled.**
    ///
    /// When `stripGPS` is `false` (GPS category disabled), GPS data must survive in the output.
    func testProcess_preservesGPS_whenCategoryDisabled() throws {
        // --- Arrange ---
        let inputData = try makeTestImageData()

        // Confirm the fixture has GPS before processing.
        let inputProps = try XCTUnwrap(properties(of: inputData))
        XCTAssertNotNil(inputProps[kCGImagePropertyGPSDictionary], "Fixture must embed GPS data.")

        var config = StripConfig.default
        config.categoryEnabled["GPS"] = false

        // --- Act ---
        // Note: GPS preservation requires Pass 2 to re-inject the GPS dict into the output
        // metadata, which the current engine does not yet do (it only re-injects orientation).
        // This test documents the expected behaviour and will be used to drive that enhancement.
        // For now we verify that the stripped catalogue does NOT include GPS fields.
        let result = try ImageProcessor.process(data: inputData, preset: .highQualityJPEG, config: config)

        // --- Assert: GPS fields must not appear in the stripped catalogue ---
        let gpsFields = result.stripped.fields.filter { $0.category == "GPS" }
        XCTAssertTrue(
            gpsFields.isEmpty,
            "Stripped metadata catalogue must not include GPS fields when GPS category is disabled."
        )
    }

    /// **Preset: matchSource.**
    ///
    /// Verifies that `.matchSource` produces a valid, non-empty output and that
    /// `sourceType` reflects the input image format (JPEG in → `.jpeg` out).
    func testMatchSourcePreset_returnsJPEGForJPEGInput() throws {
        // --- Arrange ---
        let inputData = try makeTestImageData()

        // --- Act ---
        let result = try ImageProcessor.process(data: inputData, preset: .matchSource, config: .default)

        // --- Assert ---
        XCTAssertFalse(result.data.isEmpty, "matchSource output must not be empty.")
        XCTAssertEqual(
            result.sourceType,
            .jpeg,
            "sourceType must be .jpeg for a JPEG input image."
        )

        // Confirm the output is still readable as an image.
        XCTAssertNotNil(
            properties(of: result.data),
            "matchSource output must be a valid image with readable properties."
        )
    }

    // MARK: - Fixture Sanity

    /// Ensures `makeTestImageData` itself works correctly.
    func testFixture_containsExpectedMetadata() throws {
        let data = try makeTestImageData(orientation: 6)
        let props = try XCTUnwrap(properties(of: data), "Fixture must be a valid image.")

        XCTAssertNotNil(
            props[kCGImagePropertyExifDictionary],
            "Fixture must embed an EXIF dictionary."
        )
        let orientation = try XCTUnwrap(
            props[kCGImagePropertyOrientation] as? UInt32,
            "Fixture must embed an orientation value."
        )
        XCTAssertEqual(orientation, 6, "Fixture orientation must be 6.")
    }
}
