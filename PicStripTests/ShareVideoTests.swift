import AVFoundation
import XCTest
@testable import PicStrip

// MARK: - Fixtures

/// A short H.264 movie carrying the metadata an iPhone writes: where, on what,
/// and when, plus a title.
@MainActor
func makeMovieWithMetadata(frames: Int = 6, in directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
    let url = directory.appendingPathComponent("PicStripShareVideo-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
    writer.metadata = [
        item(.quickTimeMetadataLocationISO6709, "+41.8781-087.6298+180.000/"),
        item(.quickTimeMetadataMake, "Apple"),
        item(.quickTimeMetadataModel, "iPhone 17 Pro"),
        item(.quickTimeMetadataSoftware, "27.0"),
        item(.quickTimeMetadataCreationDate, "2026-09-30T12:00:00-0500"),
        item(.quickTimeMetadataTitle, "Our trip")
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        // A different shade each frame, so the encoder cannot repeat one frame.
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, Int32(frame * 40 % 256), CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    return url
}

// MARK: - VideoMetadataCleaner

/// The metadata-only clean shared by the app, the Share Extension and the
/// Shortcuts action.
@MainActor
final class VideoMetadataCleanerTests: XCTestCase {

    private var cleanup: [URL] = []

    override func tearDown() async throws {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        try await super.tearDown()
    }

    private func outputURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripShareVideoOut-\(UUID().uuidString).mov")
        cleanup.append(url)
        return url
    }

    func testTheCopyHasNoLocationDeviceOrDate() async throws {
        let movie = try await makeMovieWithMetadata()
        cleanup.append(movie)
        let output = outputURL()

        try await VideoMetadataCleaner.clean(movie, to: output)

        let left = try await VideoMetadataCleaner.findings(in: output)
        XCTAssertEqual(left.count, 1, "Only the new random identifier is left: \(left)")
        XCTAssertEqual(left.first?.kind, .other)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(left.first?.value)), "The title and the rest are gone too.")
    }

    /// Passthrough: the same samples in the same format, so nothing was encoded again.
    func testTheFramesAreCopiedNotEncodedAgain() async throws {
        let movie = try await makeMovieWithMetadata(frames: 6)
        cleanup.append(movie)
        let output = outputURL()

        try await VideoMetadataCleaner.clean(movie, to: output)

        let before = try await videoTrackSummary(of: movie)
        let after = try await videoTrackSummary(of: output)
        XCTAssertEqual(after.codec, kCMVideoCodecType_H264, "Still H.264, not HEVC.")
        XCTAssertEqual(after.codec, before.codec)
        XCTAssertEqual([after.width, after.height], [before.width, before.height])
        XCTAssertEqual(after.sampleCount, 6)
        XCTAssertEqual(after.sampleCount, before.sampleCount)
        XCTAssertEqual(after.sampleBytes, before.sampleBytes, "Byte for byte the same frames.")
    }

    /// Fail closed: a copy that still says where, on what or when is deleted.
    func testACopyWithDetailsLeftIsDeleted() async throws {
        let movie = try await makeMovieWithMetadata()
        cleanup.append(movie)

        do {
            try await VideoMetadataCleaner.verify(movie)
            XCTFail("The original still carries a location, a device and a date.")
        } catch VideoMetadataCleaner.Failure.detailsRemain {
            XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path), "Not kept.")
        }
    }

    func testSomethingThatIsNotAVideoLeavesNothingBehind() async throws {
        let notAMovie = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripShareVideo-\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: notAMovie)
        cleanup.append(notAMovie)
        let output = outputURL()

        do {
            try await VideoMetadataCleaner.clean(notAMovie, to: output)
            XCTFail("Expected an error.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    /// A shared video in another MPEG-4 format is copied in under a `.mov`
    /// name (`SharedItemKind.videoFileExtension`); it must still open.
    func testAnMPEG4FileUnderAQuickTimeNameIsCleaned() async throws {
        let movie = try await makeMovieWithMetadata()
        cleanup.append(movie)
        let mp4 = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripShareVideo-\(UUID().uuidString).mp4")
        cleanup.append(mp4)
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: movie), presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: mp4, as: .mp4)
        let renamed = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripShareVideo-\(UUID().uuidString).mov")
        try FileManager.default.copyItem(at: mp4, to: renamed)
        cleanup.append(renamed)
        let output = outputURL()

        try await VideoMetadataCleaner.clean(renamed, to: output)

        let summary = try await videoTrackSummary(of: output)
        XCTAssertEqual(summary.sampleCount, 6)
    }

    /// The video cleaner keeps its API and uses the same policy.
    func testTheVideoCleanerUsesTheSamePolicy() async throws {
        let movie = try await makeMovieWithMetadata()
        cleanup.append(movie)
        let output = outputURL()

        try await VideoCleaner.clean(movie, to: output)

        let left = try await VideoCleaner.findings(in: output)
        XCTAssertEqual(left.map(\.kind), [.other])
        XCTAssertEqual(VideoCleaner.kind(ofKey: "udta/%A9mod"), VideoMetadataCleaner.kind(ofKey: "udta/%A9mod"))
    }

    // MARK: Helpers

    private struct TrackSummary {
        let codec: FourCharCode
        let width: Int32
        let height: Int32
        let sampleCount: Int
        let sampleBytes: Int64
    }

    private func videoTrackSummary(of url: URL) async throws -> TrackSummary {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        return TrackSummary(
            codec: CMFormatDescriptionGetMediaSubType(format),
            width: size.width,
            height: size.height,
            sampleCount: count,
            sampleBytes: try await track.load(.totalSampleDataLength)
        )
    }
}

// MARK: - Share Extension handoff

/// "Edit in PicStrip" with a video: the extension copies the file into the App
/// Group, and the app moves it into its own store instead of reading it.
@MainActor
final class VideoHandoffTests: XCTestCase {

    private var folders: [URL] = []

    override func tearDown() async throws {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        try await super.tearDown()
    }

    private func store(lifetime: TimeInterval = 900) -> PrivateFileStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return PrivateFileStore(directory: folder, lifetime: lifetime, maximumBytes: 64)
    }

    private func contents(of store: PrivateFileStore) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? []
    }

    func testAVideoIsMovedIntoTheAppsStoreNotRead() async throws {
        let handoffs = store()
        let exports = store(lifetime: 3_600)
        let movie = try await makeMovieWithMetadata(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: movie) }

        // Larger than the handoff byte limit, which applies to images read into memory.
        let handedOff = try handoffs.copy(movie, extension: "mov")
        XCTAssertGreaterThan(try XCTUnwrap(handedOff.resourceValues(forKeys: [.fileSizeKey]).fileSize), handoffs.maximumBytes)

        guard case .video(let opened) = handoffs.consume(movingVideosTo: exports) else {
            return XCTFail("Expected the video.")
        }
        XCTAssertEqual(opened.deletingLastPathComponent().standardizedFileURL, exports.directory.standardizedFileURL)
        XCTAssertEqual(opened.pathExtension, "mov")
        XCTAssertTrue(contents(of: handoffs).isEmpty, "Consumed: nothing is left in the App Group.")
        let kinds = Set(try await VideoMetadataCleaner.findings(in: opened).map(\.kind))
        XCTAssertTrue(kinds.contains(.location), "The original, for the cleaner to review.")
        XCTAssertNil(handoffs.consume(movingVideosTo: exports))
    }

    func testImagesAndVideosAreConsumedOldestFirst() async throws {
        let handoffs = store()
        let exports = store(lifetime: 3_600)
        let movie = try await makeMovieWithMetadata()
        defer { try? FileManager.default.removeItem(at: movie) }
        let now = Date()

        _ = try handoffs.copy(movie, extension: "mp4", now: now.addingTimeInterval(-2))
        _ = try handoffs.write(Data("image".utf8), extension: "data", now: now.addingTimeInterval(-1))

        guard case .video(let video) = handoffs.consume(movingVideosTo: exports, now: now) else {
            return XCTFail("The video was handed over first.")
        }
        XCTAssertEqual(video.pathExtension, "mp4")
        XCTAssertEqual(handoffs.consume(movingVideosTo: exports, now: now), .image(Data("image".utf8)))
        XCTAssertNil(handoffs.consume(movingVideosTo: exports, now: now))
    }

    func testAnExpiredVideoIsDeletedNotOpened() async throws {
        let handoffs = store(lifetime: 10)
        let exports = store(lifetime: 3_600)
        let movie = try await makeMovieWithMetadata()
        defer { try? FileManager.default.removeItem(at: movie) }
        let now = Date()

        _ = try handoffs.copy(movie, extension: "mov", now: now)

        XCTAssertNil(handoffs.consume(movingVideosTo: exports, now: now.addingTimeInterval(11)))
        XCTAssertTrue(contents(of: handoffs).isEmpty)
        XCTAssertTrue(contents(of: exports).isEmpty)
    }

    func testTheRequestWaitsUntilTheViewOpensIt() throws {
        let router = IntentRouter()
        let url = URL(fileURLWithPath: "/tmp/PicStrip-handoff.mov")
        XCTAssertNil(router.requestedVideo)
        router.requestVideo(url)
        XCTAssertEqual(router.requestedVideo, url, "Kept while another video is open.")
        router.videoPresented()
        XCTAssertNil(router.requestedVideo)
    }
}

// MARK: - Share Extension

/// What the share sheet offers PicStrip, and how each shared item is sorted.
final class ShareExtensionInputTests: XCTestCase {

    func testItemsAreSortedLikeTheLibraryPicker() {
        XCTAssertEqual(SharedItemKind(registeredTypeIdentifiers: ["public.heic", "public.jpeg"]), .photo(typeIdentifier: "public.heic"))
        XCTAssertEqual(SharedItemKind(registeredTypeIdentifiers: ["com.apple.quicktime-movie"]), .video(typeIdentifier: "com.apple.quicktime-movie"))
        XCTAssertEqual(SharedItemKind(registeredTypeIdentifiers: ["public.mpeg-4"]), .video(typeIdentifier: "public.mpeg-4"))
        // A Live Photo carries its movie, but it is a photo.
        XCTAssertEqual(
            SharedItemKind(registeredTypeIdentifiers: ["com.apple.quicktime-movie", "public.heic", "com.apple.live-photo"]),
            .photo(typeIdentifier: "public.heic")
        )
        XCTAssertNil(SharedItemKind(registeredTypeIdentifiers: ["com.apple.live-photo", "com.apple.quicktime-movie"]))
        XCTAssertNil(SharedItemKind(registeredTypeIdentifiers: ["public.url", "public.plain-text"]))
        XCTAssertNil(SharedItemKind(registeredTypeIdentifiers: []))
    }

    func testVideoCopiesKeepAMovieExtensionTheAppOpens() {
        XCTAssertEqual(SharedItemKind.videoFileExtension(for: "com.apple.quicktime-movie"), "mov")
        XCTAssertEqual(SharedItemKind.videoFileExtension(for: "public.mpeg-4"), "mp4")
        XCTAssertEqual(SharedItemKind.videoFileExtension(for: "com.apple.m4v-video"), "m4v")
        XCTAssertEqual(SharedItemKind.videoFileExtension(for: "public.3gpp"), "mov")
        XCTAssertEqual(SharedItemKind.videoFileExtension(for: "public.movie"), "mov")
    }

    // MARK: Activation rule

    private func activationRule() throws -> NSPredicate {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let bundle = try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent("PicStripShareExtension.appex")),
                                   "The app should embed the share extension.")
        let attributes = try XCTUnwrap((bundle.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any])
        return NSPredicate(format: try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String))
    }

    private func offered(_ attachments: [[String]], itemsEach: Bool = false) throws -> Bool {
        let wrapped = attachments.map { ["registeredTypeIdentifiers": $0] }
        let items: [[String: Any]] = itemsEach ? wrapped.map { ["attachments": [$0]] } : [["attachments": wrapped]]
        return try activationRule().evaluate(with: ["extensionItems": items])
    }

    func testTheShareSheetOffersPicStripForPhotosAndVideos() throws {
        XCTAssertTrue(try offered([["public.jpeg"]]))
        XCTAssertTrue(try offered(Array(repeating: ["public.heic"], count: 40)), "Photos have no limit.")
        XCTAssertTrue(try offered([["com.apple.quicktime-movie"]]))
        XCTAssertTrue(try offered([["public.heic"], ["public.mpeg-4"]]), "Photos and videos together.")
        XCTAssertFalse(try offered([["public.url"]]))
        XCTAssertFalse(try offered([["public.plain-text"], ["com.adobe.pdf"]]))
    }

    /// Ten videos at most, however the host app groups its attachments; Live
    /// Photos count as photos.
    func testVideosAreLimitedToTen() throws {
        let movie = ["com.apple.quicktime-movie"]
        XCTAssertTrue(try offered(Array(repeating: movie, count: 10)))
        XCTAssertFalse(try offered(Array(repeating: movie, count: 11)))
        XCTAssertTrue(try offered(Array(repeating: movie, count: 10), itemsEach: true))
        XCTAssertFalse(try offered(Array(repeating: movie, count: 11), itemsEach: true))
        let livePhoto = ["public.heic", "com.apple.quicktime-movie", "com.apple.live-photo"]
        XCTAssertTrue(try offered(Array(repeating: livePhoto, count: 20)))
    }
}
