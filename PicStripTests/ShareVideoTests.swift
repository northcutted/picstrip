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
