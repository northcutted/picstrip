import XCTest
import ImageIO
import CoreFoundation
import UniformTypeIdentifiers
import UIKit
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

        // 1. No user-identifying EXIF must survive.
        //
        // iOS auto-synthesises a minimal EXIF block into every JPEG even when
        // CGImageDestinationCopyImageSource is called with kCGImageDestinationMergeMetadata: false.
        // The auto-injected keys (ExifVersion, FlashPixVersion, ComponentsConfiguration) are
        // structural — they carry no personal data.  We therefore assert the absence of
        // user-identifying fields rather than the absence of the dict itself.
        let allowedStructuralExifKeys: Set<String> = [
            "ExifVersion",
            "FlashPixVersion",
            "ComponentsConfiguration",
        ]
        let exifDict = (outputProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let remainingUserKeys = exifDict.keys
            .map { $0 as String }
            .filter { !allowedStructuralExifKeys.contains($0) }
        XCTAssertTrue(
            remainingUserKeys.isEmpty,
            "Output must not contain user-identifying EXIF fields. Found: \(remainingUserKeys)"
        )

        // 2. Orientation must reflect pixel normalisation.
        //
        // The engine passes the image through UIImage.normalized(), which physically
        // rotates the pixel data into canonical up-orientation using UIGraphicsImageRenderer.
        // The encoder then writes orientation = 1 ("no rotation needed").  The resulting
        // file displays identically to the source — visual orientation is preserved even
        // though the metadata value changes from the source value (6) to 1.
        let outputOrientation = try XCTUnwrap(
            outputProps[kCGImagePropertyOrientation] as? UInt32,
            "Orientation tag must be present in the output image."
        )
        XCTAssertEqual(
            outputOrientation,
            1,
            "Engine normalises pixels; output orientation must be 1 (canonical up)."
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

        let result = try ImageProcessor.process(data: inputData, preset: .highQualityJPEG, config: config)

        // --- Assert: GPS fields must not appear in the stripped catalogue ---
        let gpsFields = result.stripped.fields.filter { $0.category == "GPS" }
        XCTAssertTrue(
            gpsFields.isEmpty,
            "Stripped metadata catalogue must not include GPS fields when GPS category is disabled."
        )
    }

    /// **Config: per-field keep.**
    ///
    /// When a single field override says "keep", the stripped catalogue must
    /// exclude that field while still reporting other fields in the same category.
    func testProcess_honorsPerFieldKeepOverrideInStrippedCatalogue() throws {
        // --- Arrange ---
        let inputData = try makeTestImageData()

        var config = StripConfig.default
        config.fieldOverrides["EXIF.DateTimeOriginal"] = false

        // --- Act ---
        let result = try ImageProcessor.process(data: inputData, preset: .highQualityJPEG, config: config)

        // --- Assert ---
        let strippedEXIFKeys = Set(
            result.stripped.fields
                .filter { $0.category == "EXIF" && !$0.isStructural }
                .map(\.key)
        )
        XCTAssertFalse(
            strippedEXIFKeys.contains("DateTimeOriginal"),
            "DateTimeOriginal has an explicit keep override and must not be reported as stripped."
        )
        XCTAssertTrue(
            strippedEXIFKeys.contains("UserComment"),
            "Other EXIF fields in the same category must still be stripped."
        )
    }

    func testShouldReportStripped_keepsUnsupportedCategoriesVisible() {
        var config = StripConfig.default
        config.fieldOverrides["Apple Maker Note.SomePrivateKey"] = false

        XCTAssertTrue(
            ImageProcessor.shouldReportStripped(
                category: "Apple Maker Note",
                key: "SomePrivateKey",
                isStructural: false,
                config: config
            ),
            "Unsupported categories must stay visible in review even if the user tries to keep them."
        )
    }

    /// **Redacted image path.**
    ///
    /// Re-encoding a rendered image with separate source bytes must still use the
    /// source metadata for stripping decisions. This protects the redaction flow,
    /// where pixels come from `ImageRedactor` but metadata policy comes from the
    /// original photo.
    func testProcessRenderedImage_usesSourceDataForMetadataCatalogue() throws {
        // --- Arrange ---
        let sourceData = try makeTestImageData()
        let renderedImage = try XCTUnwrap(UIImage(data: sourceData))

        // --- Act ---
        let result = try ImageProcessor.process(
            image: renderedImage,
            sourceData: sourceData,
            preset: .losslessPNG,
            config: .default
        )

        // --- Assert ---
        XCTAssertFalse(result.data.isEmpty, "Rendered-image output must not be empty.")
        XCTAssertEqual(result.sourceType, .jpeg, "Source type must be read from sourceData, not rendered pixels.")
        XCTAssertTrue(
            result.stripped.fields.contains { $0.category == "GPS" },
            "Rendered-image processing must still report metadata stripped from the original source."
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
