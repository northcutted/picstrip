import AppIntents
import AVFoundation
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

    func testClean_removesGPSAndKeepsSourceFormatWithNeutralName() async throws {
        let input = IntentFile(data: try jpegWithGPS(), filename: "IMG_0042.JPG", type: .jpeg)
        XCTAssertNotNil(properties(of: input.data)[kCGImagePropertyGPSDictionary], "Fixture must carry GPS.")

        let cleaned = try await StripMetadataIntent.clean([input], preset: .matchSource)

        let output = try XCTUnwrap(cleaned.first)
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertNotNil(output.fileURL, "Results must be backed by files, not retained encoded Data.")
        XCTAssertNil(properties(of: try Data(contentsOf: XCTUnwrap(output.fileURL)))[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(output.type, .jpeg)
        XCTAssertEqual(output.filename, "PicStrip.jpeg")
    }

    func testClean_usesRequestedFormatForNameAndType() async throws {
        let input = IntentFile(data: try jpegWithGPS(), filename: "holiday.jpg", type: .jpeg)
        let cleaned = try await StripMetadataIntent.clean([input], preset: .losslessPNG)

        let output = try XCTUnwrap(cleaned.first)
        XCTAssertEqual(output.type, .png)
        XCTAssertEqual(output.filename, "PicStrip.png")
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
        XCTAssertEqual(StripMetadataIntent.outputFilename(for: "IMG_1.HEIC", type: .png), "PicStrip.png")
        XCTAssertEqual(StripMetadataIntent.outputFilename(for: "scan.final.tiff", type: .jpeg), "PicStrip.jpeg")
        XCTAssertEqual(StripMetadataIntent.outputFilename(for: "", type: .heic), "PicStrip.heic")
    }

    // MARK: - Shortcuts wiring

    /// Shortcuts only feeds the previous action's output ("Select Photos", "Get
    /// File", …) into a parameter the extracted metadata marks as the action's
    /// input.  Every test above passed while that flag was missing and the
    /// shortcut ran with no images, so this reads what the build actually ships.
    func testImagesParameterIsTheShortcutsInput() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "extract", withExtension: "actionsdata", subdirectory: "Metadata.appintents"),
            "The test host app should carry extracted App Intents metadata."
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let actions = try XCTUnwrap(root["actions"] as? [String: Any])
        let action = try XCTUnwrap(actions["StripMetadataIntent"] as? [String: Any])
        let parameters = try XCTUnwrap(action["parameters"] as? [[String: Any]])

        let images = try XCTUnwrap(parameters.first { $0["name"] as? String == "images" })
        XCTAssertEqual(images["isInput"] as? Bool, true, "`images` must connect to the previous action's result.")

        let format = try XCTUnwrap(parameters.first { $0["name"] as? String == "format" })
        XCTAssertEqual(format["isInput"] as? Bool, false)
    }
}

// MARK: - Strip Metadata from Videos

@MainActor
final class StripVideoMetadataIntentTests: XCTestCase {

    private var folders: [URL] = []
    private var movies: [URL] = []

    override func tearDown() async throws {
        (folders + movies).forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        movies = []
        try await super.tearDown()
    }

    private func store() -> PrivateFileStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return PrivateFileStore(directory: folder)
    }

    private func movieFile(named filename: String) async throws -> IntentFile {
        let movie = try await makeMovieWithMetadata()
        movies.append(movie)
        return IntentFile(fileURL: movie, filename: filename, type: .quickTimeMovie)
    }

    private func leftovers(in store: PrivateFileStore) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? []
    }

    func testClean_removesLocationDeviceAndDateWithANeutralName() async throws {
        let store = store()
        let input = try await movieFile(named: "IMG_0042.MOV")

        let cleaned = try await StripVideoMetadataIntent.clean([input], store: store)

        let output = try XCTUnwrap(cleaned.first)
        XCTAssertEqual(cleaned.count, 1)
        let url = try XCTUnwrap(output.fileURL, "Results must be files, never videos held in memory.")
        XCTAssertEqual(output.filename, "PicStrip.mov")
        XCTAssertEqual(output.type, .quickTimeMovie)
        let kinds = try await VideoMetadataCleaner.findings(in: url).map(\.kind)
        XCTAssertEqual(kinds, [.other], "Only the new random identifier is left.")
        XCTAssertEqual(leftovers(in: store), [url], "The working copy of the input is deleted.")
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let formats = try await XCTUnwrap(tracks.first).load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264, "Copied, not encoded again.")
    }

    func testClean_acceptsAVideoShortcutsHoldsInMemory() async throws {
        let movie = try await makeMovieWithMetadata()
        movies.append(movie)
        let input = IntentFile(data: try Data(contentsOf: movie), filename: "clip.mov", type: .quickTimeMovie)

        let cleaned = try await StripVideoMetadataIntent.clean([input], store: store())

        let url = try XCTUnwrap(cleaned.first?.fileURL)
        let kinds = try await VideoMetadataCleaner.findings(in: url).map(\.kind)
        XCTAssertEqual(kinds, [.other])
    }

    func testClean_reportsProgress() async throws {
        var files: [IntentFile] = []
        for index in 1...3 { files.append(try await movieFile(named: "\(index).mov")) }
        let progress = Progress(totalUnitCount: 3)
        _ = try await StripVideoMetadataIntent.clean(files, progress: progress, store: store())
        XCTAssertEqual(progress.completedUnitCount, 3)
    }

    /// Fail closed: one video that cannot be cleaned fails the whole run, and
    /// the copies already made are deleted.
    func testClean_throwsAndKeepsNothingWhenAnyVideoCannotBeCleaned() async throws {
        let store = store()
        let good = try await movieFile(named: "good.mov")
        let bad = IntentFile(data: Data("not a movie".utf8), filename: "bad.mov", type: .quickTimeMovie)

        do {
            _ = try await StripVideoMetadataIntent.clean([good, bad], store: store)
            XCTFail("Expected an error for the file that is not a video.")
        } catch let error as StripVideoMetadataIntentError {
            guard case .couldNotClean(let filename) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(filename, "bad.mov")
        }
        XCTAssertEqual(leftovers(in: store), [], "Nothing cleaned or copied is left behind.")
    }

    func testClean_throwsForEmptyFile() async {
        let empty = IntentFile(data: Data(), filename: "empty.mov", type: .quickTimeMovie)
        do {
            _ = try await StripVideoMetadataIntent.clean([empty], store: store())
            XCTFail("Expected an error for the empty file.")
        } catch let error as StripVideoMetadataIntentError {
            guard case .couldNotRead = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// As for images: the extracted metadata must mark `videos` as the input.
    func testVideosParameterIsTheShortcutsInput() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "extract", withExtension: "actionsdata", subdirectory: "Metadata.appintents"),
            "The test host app should carry extracted App Intents metadata."
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let actions = try XCTUnwrap(root["actions"] as? [String: Any])
        let action = try XCTUnwrap(actions["StripVideoMetadataIntent"] as? [String: Any])
        let parameters = try XCTUnwrap(action["parameters"] as? [[String: Any]])

        let videos = try XCTUnwrap(parameters.first { $0["name"] as? String == "videos" })
        XCTAssertEqual(videos["isInput"] as? Bool, true, "`videos` must connect to the previous action's result.")
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
