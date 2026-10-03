import AVFoundation
import XCTest
@testable import PicStrip

final class VideoAudioTests: XCTestCase {

    private var cleanup: [URL] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        super.tearDown()
    }

    func testOverlappingStretchesMerge() {
        XCTAssertEqual(VideoAudioEditor.merged([2...3, 0.5...1, 2.5...4, 4...4.5]), [0.5...1, 2...4.5])
        XCTAssertEqual(VideoAudioEditor.merged([]), [])
    }

    func testTheWaveformFollowsTheSound() async throws {
        let movie = try await makeMovie(seconds: 2, silentAfter: 1)
        let levels = await VideoAudioEditor.levels(of: movie, count: 20)
        XCTAssertEqual(levels.count, 20)
        XCTAssertEqual(levels.max() ?? 0, 1, accuracy: 0.001, "Scaled to the loudest.")
        XCTAssertGreaterThan(levels[4], 0.5, "Loud in the first second.")
        XCTAssertLessThan(levels[15], 0.05, "Quiet in the second.")
    }

    func testMutedAndBleepedStretchesAreSavedThatWay() async throws {
        let movie = try await makeMovie(seconds: 3)
        let edits = [
            AudioEdit(id: 0, kind: .mute, range: 0.5...1.0),
            AudioEdit(id: 1, kind: .bleep, range: 1.5...2.0)
        ]
        let edited = try await VideoAudioEditor.edited(movie, edits: edits)
        if let tone = edited.toneFile { cleanup.append(tone) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripAudioOut-\(UUID().uuidString).mov")
        cleanup.append(output)
        try await VideoCleaner.clean(edited.asset, audioMix: edited.audioMix, to: output)

        let samples = try await monoSamples(of: output)
        func stretch(_ range: ClosedRange<Double>) -> ArraySlice<Float> {
            let rate = 8_000.0
            return samples[Int((range.lowerBound + 0.05) * rate)..<min(samples.count, Int((range.upperBound - 0.05) * rate))]
        }
        // The original 440 Hz sound outside the edits.
        XCTAssertGreaterThan(rms(stretch(0.0...0.5)), 0.05)
        XCTAssertEqual(frequency(stretch(0.0...0.5)), 440, accuracy: 40)
        // Silence where muted.
        XCTAssertLessThan(rms(stretch(0.5...1.0)), 0.01, "Muted.")
        // Only the 1 kHz tone where bleeped.
        XCTAssertGreaterThan(rms(stretch(1.5...2.0)), 0.05, "Bleeped, not silent.")
        XCTAssertEqual(frequency(stretch(1.5...2.0)), VideoAudioEditor.toneFrequency, accuracy: 60, "The tone, not the voice.")
        // And the original again after.
        XCTAssertEqual(frequency(stretch(2.2...2.9)), 440, accuracy: 40)
    }

    func testWithoutEditsTheSourceIsUsedAsItIs() async throws {
        let movie = try await makeMovie(seconds: 1)
        let edited = try await VideoAudioEditor.edited(movie, edits: [])
        XCTAssertEqual((edited.asset as? AVURLAsset)?.url, movie)
        XCTAssertNil(edited.audioMix)
        XCTAssertNil(edited.toneFile)
    }

    // MARK: Helpers

    /// A movie with plain frames and a 440 Hz tone, silent from `silentAfter` on.
    private func makeMovie(seconds: Double, silentAfter: Double = .infinity) async throws -> URL {
        let url = try await SoundMovie.make(seconds: seconds, silentAfter: silentAfter)
        cleanup.append(url)
        return url
    }

    /// The saved sound, mixed to one channel at 8 kHz, −1 … 1.
    private func monoSamples(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1, "One mixed sound track in the saved copy.")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8_000
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [Int16](repeating: 0, count: length / 2)
            _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += bytes.map { Float($0) / Float(Int16.max) }
        }
        return samples
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
    }

    /// The dominant frequency, from zero crossings, in Hz at 8 kHz.
    private func frequency(_ samples: ArraySlice<Float>) -> Double {
        let values = Array(samples)
        guard values.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<values.count where (values[index - 1] < 0) != (values[index] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(values.count) / 8_000)
    }
}

// MARK: - SoundMovie

/// Movies with sound, for the audio tests and the editor's.
enum SoundMovie {

    /// A movie with plain frames and a 440 Hz tone, silent from `silentAfter` on.
    static func make(seconds: Double, silentAfter: Double = .infinity) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicStripAudio-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        let rate = 44_100.0
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ])
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Video and sound are written a tenth of a second at a time, side by
        // side: the writer interleaves them and stalls one input waiting on the other.
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true))
        let perStep = Int(rate / 10)
        func waitFor(_ input: AVAssetWriterInput) async throws {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        for step in 0..<Int(seconds * 10) {
            try await waitFor(video)
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &made)
            XCTAssertTrue(adaptor.append(try XCTUnwrap(made), withPresentationTime: CMTime(value: CMTimeValue(step), timescale: 10)))

            try await waitFor(audio)
            let first = step * perStep
            var samples = [Int16](repeating: 0, count: perStep)
            for index in 0..<perStep {
                let time = Double(first + index) / rate
                if time < silentAfter {
                    samples[index] = Int16(12_000 * sin(2 * Double.pi * 440 * time))
                }
            }
            let buffer = try Self.sampleBuffer(samples, format: format, at: CMTime(value: CMTimeValue(first), timescale: CMTimeScale(rate)))
            XCTAssertTrue(audio.append(buffer))
        }
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private static func sampleBuffer(_ samples: [Int16], format: AVAudioFormat, at time: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        let length = samples.count * 2
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block
        )
        let blockBuffer = try XCTUnwrap(block)
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length) }
        var buffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: time.timescale), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = 2
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: samples.count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &buffer
        )
        return try XCTUnwrap(buffer)
    }
}
