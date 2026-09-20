import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

// MARK: - Fixtures

private enum Fixture {

    /// A solid-colour image encoded with whatever metadata the caller supplies.
    static func image(
        width: Int = 1,
        height: Int = 1,
        type: UTType = .jpeg,
        alpha: Bool = false,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: alphaInfo.rawValue
            )
        else { throw XCTSkip("Could not create bitmap context for fixture.") }

        if !alpha {
            ctx.setFillColor(UIColor.red.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // With alpha the context starts fully transparent — leave it that way.

        let output = NSMutableData()
        guard
            let cgImage = ctx.makeImage(),
            let dest = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { throw XCTSkip("Could not create image destination for fixture.") }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("Fixture finalize failed.") }
        return output as Data
    }

    static var gps: [CFString: Any] {
        [
            kCGImagePropertyGPSLatitude: 37.3317,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.0307,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
    }

    static var exif: [CFString: Any] {
        [
            kCGImagePropertyExifDateTimeOriginal: "2024:01:01 12:00:00",
            kCGImagePropertyExifISOSpeedRatings: [400],
            kCGImagePropertyExifFNumber: 1.8
        ]
    }

    static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func type(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }
}

// MARK: - ImageProcessor

final class ImageProcessorKeepPathTests: XCTestCase {

    /// Keeping GPS must put real, correctly-typed coordinates back into the file —
    /// the catalogue alone saying "not stripped" is not enough.
    func testKeptGPS_roundTripsIntoOutputFile() throws {
        let input = try Fixture.image(properties: [kCGImagePropertyGPSDictionary: Fixture.gps])

        var config = StripConfig.default
        config.categoryEnabled["GPS"] = false
        let result = try ImageProcessor.process(data: input, preset: .highQualityJPEG, config: config)

        let gps = try XCTUnwrap(
            Fixture.properties(of: result.data)[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            "Output must carry a GPS dictionary when the GPS category is kept."
        )
        let latitude = try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double)
        let longitude = try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? Double)
        XCTAssertEqual(latitude, 37.3317, accuracy: 0.0001)
        XCTAssertEqual(longitude, 122.0307, accuracy: 0.0001)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "N")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
    }

    /// Array- and rational-valued EXIF fields used to be flattened into a
    /// description string ("(\n 400\n)") when kept.
    func testKeptEXIF_preservesArrayAndNumericTypes() throws {
        let input = try Fixture.image(properties: [kCGImagePropertyExifDictionary: Fixture.exif])

        var config = StripConfig.default
        config.categoryEnabled["EXIF"] = false
        let result = try ImageProcessor.process(data: input, preset: .highQualityJPEG, config: config)

        let exif = try XCTUnwrap(
            Fixture.properties(of: result.data)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        )
        let iso = try XCTUnwrap(
            exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
            "ISOSpeedRatings must survive as an array of numbers, not a string."
        )
        XCTAssertEqual(iso, [400])
        let fNumber = try XCTUnwrap(exif[kCGImagePropertyExifFNumber] as? Double)
        XCTAssertEqual(fNumber, 1.8, accuracy: 0.01)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:01:01 12:00:00")
    }

    /// With everything stripped the same fields must be gone from the file.
    func testDefaultConfig_removesGPSAndPrivateEXIFFromOutputFile() throws {
        let input = try Fixture.image(properties: [
            kCGImagePropertyGPSDictionary: Fixture.gps,
            kCGImagePropertyExifDictionary: Fixture.exif
        ])
        let result = try ImageProcessor.process(data: input, preset: .highQualityJPEG)

        let props = Fixture.properties(of: result.data)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS must not survive a default strip.")
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifISOSpeedRatings])

        let leftovers = ImageProcessor.readAllFields(from: result.data).filter { !$0.isStructural }
        XCTAssertTrue(
            leftovers.isEmpty,
            "Only structural fields may remain; found \(leftovers.map { "\($0.category).\($0.key)" })"
        )
    }

    /// A HEIC always carries its tile grid and primary-image index, and ImageIO
    /// reports an HDR headroom for it.  None of that is personal data and none of
    /// it can be stripped, so a cleaned HEIC must not list them as leftovers — or
    /// claim in the audit that a HEIC → HEIC export "removed" them.
    func testHEICOutput_reportsOnlyStructuralFields() throws {
        // Large enough for the encoder to tile; the simulator on some CI hosts
        // has no HEVC encoder at all, in which case the fixture skips.
        let input = try Fixture.image(width: 1024, height: 768, type: .heic, properties: [
            kCGImagePropertyGPSDictionary: Fixture.gps,
            kCGImagePropertyExifDictionary: Fixture.exif
        ])
        let result = try ImageProcessor.process(data: input, preset: .heicOriginal)
        XCTAssertEqual(Fixture.type(of: result.data), UTType.heic)

        XCTAssertNil(Fixture.properties(of: result.data)[kCGImagePropertyGPSDictionary])
        let leftovers = ImageProcessor.readAllFields(from: result.data).filter { !$0.isStructural }
        XCTAssertTrue(
            leftovers.isEmpty,
            "Only structural fields may remain; found \(leftovers.map { "\($0.category).\($0.key)" })"
        )

        let sourceTileFields = ImageProcessor.readAllFields(from: input)
            .filter { $0.key == "TileWidth" || $0.key == "TileLength" }
        XCTAssertTrue(sourceTileFields.allSatisfy(\.isStructural), "Tile geometry is container structure.")
    }

    /// Pixels are rotated upright during processing.  Re-injecting the source's
    /// TIFF orientation on top of that would rotate the saved photo a second time.
    func testKeptTIFF_doesNotReapplySourceOrientation() throws {
        let input = try Fixture.image(width: 4, height: 2, properties: [
            kCGImagePropertyOrientation: 6 as UInt32,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFOrientation: 6,
                kCGImagePropertyTIFFModel: "PicStripTests"
            ] as [CFString: Any]
        ])

        var config = StripConfig.default
        config.categoryEnabled["TIFF"] = false
        let result = try ImageProcessor.process(data: input, preset: .highQualityJPEG, config: config)

        let props = Fixture.properties(of: result.data)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 2, "Rotated pixels: width and height swap.")
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 4)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "PicStripTests")
    }

    /// ImageIO truncates fractional numbers when writing rational EXIF fields, so
    /// kept values are handed over as exact rational strings instead.
    func testRationalString_findsExactSmallFractions() {
        XCTAssertEqual(ImageProcessor.rationalString(for: 1.8), "9/5")
        XCTAssertEqual(ImageProcessor.rationalString(for: 0.008), "1/125")
        XCTAssertEqual(ImageProcessor.rationalString(for: 1.0 / 60.0), "1/60")
        XCTAssertEqual(ImageProcessor.rationalString(for: -1.25), "-5/4")
        XCTAssertEqual(ImageProcessor.rationalString(for: 12.5), "25/2")
        XCTAssertNil(ImageProcessor.rationalString(for: .infinity))
        XCTAssertNil(ImageProcessor.rationalString(for: .nan))
    }

    func testRationalString_staysAccurateForAwkwardValues() throws {
        for value in [6.965784, 271.4, 0.000125, 123_456.789, 3.141592653589793] {
            let parts = try XCTUnwrap(ImageProcessor.rationalString(for: value)).split(separator: "/")
            let numerator = try XCTUnwrap(Double(parts[0]))
            let denominator = try XCTUnwrap(Double(parts[1]))
            XCTAssertLessThanOrEqual(denominator, 1_000_000)
            XCTAssertEqual(numerator / denominator, value, accuracy: max(1e-6, value * 1e-9))
        }
    }

    func testKeptGPS_preservesFractionalAltitudeAndSpeed() throws {
        var gps = Fixture.gps
        gps[kCGImagePropertyGPSAltitude] = 12.5
        gps[kCGImagePropertyGPSSpeed] = 3.7
        let input = try Fixture.image(properties: [kCGImagePropertyGPSDictionary: gps])

        var config = StripConfig.default
        config.categoryEnabled["GPS"] = false
        let result = try ImageProcessor.process(data: input, preset: .highQualityJPEG, config: config)

        let output = try XCTUnwrap(
            Fixture.properties(of: result.data)[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        )
        XCTAssertEqual(try XCTUnwrap(output[kCGImagePropertyGPSAltitude] as? Double), 12.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(output[kCGImagePropertyGPSSpeed] as? Double), 3.7, accuracy: 0.001)
    }

    /// A rotated image with transparency used to be flattened onto black because
    /// the normalising renderer was forced opaque.
    func testRotatedTransparentPNG_keepsAlpha() throws {
        let input = try Fixture.image(
            width: 4, height: 2, type: .png, alpha: true,
            properties: [kCGImagePropertyOrientation: 6 as UInt32]
        )
        guard UIImage(data: input)?.imageOrientation != .up else {
            throw XCTSkip("PNG orientation was not honoured by the decoder; nothing to normalise.")
        }

        let result = try ImageProcessor.process(data: input, preset: .losslessPNG)
        let cgImage = try XCTUnwrap(UIImage(data: result.data)?.cgImage)

        var pixel = [UInt8](repeating: 255, count: 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(pixel[3], 0, "Transparent source pixels must stay transparent after processing.")
    }
}

// MARK: - ScrubberViewModel

@MainActor
final class ScrubberViewModelRegressionTests: XCTestCase {

    /// Export contracts do not depend on Vision startup or OCR of tiny fixtures.
    /// PIIScannerTests exercise the real scanner; this suite controls completion.
    private func makeViewModel() -> ScrubberViewModel {
        ScrubberViewModel(scanImage: { _ in [] })
    }

    func testSave_waitsForScanBeforeEncoding() async throws {
        let scan = ControlledScan()
        defer { scan.finish() }
        let viewModel = ScrubberViewModel(scanImage: { _ in await scan.run() })
        await viewModel.loadData(try Fixture.image(width: 8, height: 8))
        try await waitUntil { scan.isWaiting }

        viewModel.requestSave()
        try await waitUntil { viewModel.isProcessing }
        XCTAssertNil(viewModel.activeSheet)
        XCTAssertNil(viewModel.processedData)

        scan.finish()
        try await waitUntil { viewModel.activeSheet == .preSave && !viewModel.isProcessing }
        XCTAssertEqual(Fixture.type(of: try XCTUnwrap(viewModel.processedData)), .png)
        XCTAssertFalse(viewModel.isScanningPII)
    }

    /// The UI showed "PNG" while the first save silently encoded "match source".
    func testFreshViewModel_encodesTheFormatItDisplays() async throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.selectedPreset, viewModel.selectedExportFormat.exportPreset)

        await viewModel.loadData(try Fixture.image(width: 8, height: 8))
        viewModel.requestSave()
        try await waitUntil { viewModel.activeSheet == .preSave }

        let output = try XCTUnwrap(viewModel.processedData)
        XCTAssertEqual(viewModel.selectedExportFormat, .png)
        XCTAssertEqual(Fixture.type(of: output), .png, "A JPEG source must be exported as the displayed PNG format.")
    }

    func testChangingFormat_changesPreset() {
        let viewModel = makeViewModel()
        for format in ExportFormat.allCases {
            viewModel.selectedExportFormat = format
            XCTAssertEqual(viewModel.selectedPreset, format.exportPreset)
        }
    }

    /// A slow load for photo A must not overwrite state after B was chosen.
    func testSupersededLoad_doesNotOverwriteNewerImage() async throws {
        let viewModel = makeViewModel()
        let first = try Fixture.image(width: 4, height: 4, type: .png)
        let second = try Fixture.image(width: 8, height: 2, type: .jpeg)

        let loadFirst = Task { await viewModel.loadData(first) }
        let loadSecond = Task { await viewModel.loadData(second) }
        await loadFirst.value
        await loadSecond.value

        XCTAssertEqual(viewModel.imageSize, CGSize(width: 8, height: 2))
        XCTAssertEqual(viewModel.sourceUTType, .jpeg)
        XCTAssertFalse(viewModel.isProcessing)
    }

    /// Once an encode has run, the output file — not the strip config — decides
    /// what counts as removed.  PNG output carries no metadata at all, so a field
    /// the user asked to keep must still be reported as removed.
    func testIsRemoved_reflectsActualOutputAfterEncode() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadData(try Fixture.image(
            width: 8, height: 8,
            properties: [kCGImagePropertyGPSDictionary: Fixture.gps]
        ))
        viewModel.stripConfig.categoryEnabled["GPS"] = false

        let latitude = try XCTUnwrap(
            viewModel.allSourceMetadata?.fields.first { $0.category == "GPS" && $0.key == "Latitude" }
        )
        XCTAssertFalse(viewModel.isRemoved(latitude), "Before encoding, a kept field is predicted to survive.")

        viewModel.selectedExportFormat = .jpeg
        viewModel.requestSave()
        try await waitUntil { viewModel.activeSheet == .preSave && !viewModel.isProcessing }
        XCTAssertFalse(viewModel.isRemoved(latitude), "JPEG output keeps GPS when asked to.")

        viewModel.selectedExportFormat = .png
        try await waitUntil {
            !viewModel.isProcessing && viewModel.processedData.flatMap(Fixture.type(of:)) == .png
        }
        XCTAssertTrue(viewModel.isRemoved(latitude), "PNG output has no GPS, whatever the config says.")
    }

    /// Pasted, dropped, and shared bytes are not guaranteed to be an image.  The
    /// failure must be reported, not left as a silent return to the home screen.
    func testLoadData_reportsUndecodableBytes() async {
        let viewModel = makeViewModel()
        await viewModel.loadData(Data("definitely not an image".utf8))

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.inputImage)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isScanningPII, "No scan should start for bytes that cannot be shown.")
    }

    /// Bytes that did not come from the picker have no library original to replace.
    func testLoadData_disablesReplaceOriginal() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadData(try Fixture.image())
        XCTAssertNil(viewModel.selectedItem)
        XCTAssertFalse(viewModel.canReplaceOriginal)
    }

    // MARK: Batch

    func testBatch_countsOnlyPhotosThatWereCleanedAndSaved() async throws {
        let viewModel = makeViewModel()
        let good = try Fixture.image(properties: [kCGImagePropertyGPSDictionary: Fixture.gps])
        let sources = [
            BatchSource(assetIdentifier: nil) { good },
            BatchSource(assetIdentifier: nil) { Data("not an image".utf8) },
            BatchSource(assetIdentifier: nil) { nil }
        ]
        let saved = SavedPhotos()

        var config = BatchConfig()
        config.redactVisualPII = false
        await viewModel.runBatch(sources: sources, config: config) { data, _, _ in
            await saved.append(data)
            return .saved
        }

        XCTAssertEqual(viewModel.batchSucceededCount, 1)
        XCTAssertEqual(viewModel.batchFailedCount, 2)
        XCTAssertNotNil(viewModel.batchErrorMessage)
        XCTAssertTrue(viewModel.batchComplete)

        // Fail closed: the undecodable photo must never reach the library untouched.
        let written = await saved.all
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(Fixture.properties(of: try XCTUnwrap(written.first))[kCGImagePropertyGPSDictionary])

        let gpsReport = viewModel.batchReports.first?.metadataStripped.first { $0.category == "GPS" }
        XCTAssertNotNil(gpsReport, "The audit entry must list the GPS fields that were removed.")

        let url = try XCTUnwrap(viewModel.generateBatchAuditJSON())
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let audit = try decoder.decode(BatchAuditReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(audit.photoCount, 1)
        XCTAssertEqual(audit.failedCount, 2)
    }

    func testBatch_saveFailureIsReportedAsFailure() async throws {
        let viewModel = makeViewModel()
        let good = try Fixture.image()
        var config = BatchConfig()
        config.redactVisualPII = false

        await viewModel.runBatch(
            sources: [BatchSource(assetIdentifier: nil) { good }],
            config: config
        ) { _, _, _ in .failed }

        XCTAssertEqual(viewModel.batchSucceededCount, 0)
        XCTAssertEqual(viewModel.batchFailedCount, 1)
        XCTAssertTrue(viewModel.batchReports.isEmpty)
    }

    func testBatch_redactionRequestedOnUnreadablePhoto_failsClosed() async {
        let viewModel = makeViewModel()
        var config = BatchConfig()
        config.stripMetadata = false      // redaction only — the scan itself must gate the save
        let saved = SavedPhotos()

        await viewModel.runBatch(
            sources: [BatchSource(assetIdentifier: nil) { Data("not an image".utf8) }],
            config: config
        ) { data, _, _ in
            await saved.append(data)
            return .saved
        }

        let written = await saved.all
        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(viewModel.batchFailedCount, 1)
    }

    // MARK: Captured pages (document scanner)

    func testCapturedSinglePage_opensInEditorWithNoOriginalToReplace() async throws {
        let page = try Fixture.image(width: 8, height: 8)
        let scanned = ScannedBytes()
        let viewModel = ScrubberViewModel(scanImageWithHints: { data, hints in
            await scanned.record(data, hints: hints)
            return []
        })

        await viewModel.loadCaptured(CapturedPages(count: 1, hints: .scannedDocument) { _ in page })
        try await waitUntil { viewModel.inputImage != nil && !viewModel.isScanningPII }

        XCTAssertNil(viewModel.activeSheet, "One page is edited like any other image, not batched.")
        XCTAssertFalse(viewModel.canReplaceOriginal)
        XCTAssertTrue(viewModel.scannedBatchSources.isEmpty)
        let seen = await scanned.all
        XCTAssertEqual(seen, [page], "The detector must see exactly the captured bytes.")
        let hints = await scanned.hints
        XCTAssertEqual(hints, [.scannedDocument], "A document scan must reach the detector as a whole-page document.")
    }

    func testCapturedSinglePage_unreadablePageIsReported() async {
        let viewModel = makeViewModel()
        await viewModel.loadCaptured(CapturedPages(count: 1) { _ in nil })
        XCTAssertNil(viewModel.inputImage)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testCapturedPhoto_isEncodedAndOpensInTheEditor() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let scanned = ScannedBytes()
        let viewModel = ScrubberViewModel(scanImageWithHints: { data, hints in
            await scanned.record(data, hints: hints)
            return []
        })

        await viewModel.loadCaptured(CapturedPages(photo: photo))
        try await waitUntil { viewModel.inputImage != nil && !viewModel.isScanningPII }

        XCTAssertFalse(viewModel.canReplaceOriginal)
        let hints = await scanned.hints
        XCTAssertEqual(hints, [ScanHints.none], "A photo is not a document edge to edge.")
        let seen = await scanned.all
        XCTAssertEqual(Fixture.type(of: try XCTUnwrap(seen.first)), .jpeg)
    }

    func testCapturedPages_goThroughBatchAndAreNeverReplaceable() async throws {
        let viewModel = makeViewModel()
        let page = try Fixture.image(properties: [kCGImagePropertyGPSDictionary: Fixture.gps])

        await viewModel.loadCaptured(CapturedPages(count: 3, hints: .scannedDocument) { index in index == 1 ? nil : page })

        XCTAssertEqual(viewModel.activeSheet, .batch)
        XCTAssertTrue(viewModel.scannedBatchSources.allSatisfy { $0.hints == .scannedDocument })
        XCTAssertEqual(viewModel.batchCount, 3)
        XCTAssertFalse(viewModel.batchAllowsReplaceOriginal)

        var requested = BatchConfig()
        requested.redactVisualPII = false
        requested.saveMode = .replaceOriginal
        let config = viewModel.effectiveBatchConfig(requested)
        XCTAssertEqual(config.saveMode, .saveAsNew, "A scan has no library original to delete.")

        let saves = SavedCalls()
        await viewModel.runBatch(sources: viewModel.currentBatchSources(), config: config) { _, identifier, mode in
            await saves.record(identifier: identifier, mode: mode)
            return .saved
        }

        let calls = await saves.all
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.identifier == nil && $0.mode == .saveAsNew })
        XCTAssertEqual(viewModel.batchSucceededCount, 2)
        XCTAssertEqual(viewModel.batchFailedCount, 1, "A page that cannot be produced counts as failed.")

        viewModel.clearBatchState()
        XCTAssertTrue(viewModel.scannedBatchSources.isEmpty, "Clearing the batch must release the scan.")
        XCTAssertTrue(viewModel.batchAllowsReplaceOriginal)
    }

    func testPickerBatch_keepsTheRequestedSaveMode() {
        let viewModel = makeViewModel()
        var requested = BatchConfig()
        requested.saveMode = .replaceOriginal
        XCTAssertEqual(viewModel.effectiveBatchConfig(requested).saveMode, .replaceOriginal)
    }

    func testBatchConfig_hasWorkOnlyWhenAnOptionIsOn() {
        var config = BatchConfig()
        XCTAssertTrue(config.hasWork)
        config.stripMetadata = false
        XCTAssertTrue(config.hasWork)
        config.redactVisualPII = false
        XCTAssertFalse(config.hasWork)
    }

    // MARK: Helpers

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition.")
                throw WaitTimeout.expired
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum WaitTimeout: Error {
    case expired
}

@MainActor
private final class ControlledScan {
    private var continuation: CheckedContinuation<[DetectionResult], Never>?
    var isWaiting: Bool { continuation != nil }

    func run() async -> [DetectionResult] {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: [])
        continuation = nil
    }
}

/// Collects what the injected batch saver was asked to write.
private actor ScannedBytes {
    private(set) var all: [Data] = []
    private(set) var hints: [ScanHints] = []
    func record(_ data: Data, hints: ScanHints) {
        all.append(data)
        self.hints.append(hints)
    }
}

private actor SavedCalls {
    private(set) var all: [(identifier: String?, mode: BatchSaveMode)] = []
    func record(identifier: String?, mode: BatchSaveMode) { all.append((identifier, mode)) }
}

private actor SavedPhotos {
    private(set) var all: [Data] = []
    func append(_ data: Data) { all.append(data) }
}
