import AVFoundation
import UIKit
import XCTest

// MARK: - Synthetic movie fixture

/// Shared by the behaviour tests and the accessibility audits: a video that
/// the scanner finds a face and an email in, with sound for the audio lane.
@MainActor
extension XCTestCase {
    /// A movie of 🧑🏽 drifting across a pale frame — a face Vision finds, even
    /// on the simulator — with an email address on a label in the corner, and a
    /// tone for its sound.  The picture and the sound are written separately and
    /// put together: one writer with both inputs stalls waiting on itself.
    func writeFaceMovie(to url: URL, seconds: Double = 2.5) async throws {
        let picture = url.deletingLastPathComponent().appendingPathComponent("picture-\(url.lastPathComponent)")
        let sound = url.deletingLastPathComponent().appendingPathComponent("sound-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: picture)
            try? FileManager.default.removeItem(at: sound)
        }
        try await writeSilentFaceMovie(to: picture, seconds: seconds)

        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(seconds * rate)
        let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        tone.frameLength = frames
        let samples = try XCTUnwrap(tone.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = 0.3 * Float(sin(2 * Double.pi * 440 * Double(index) / rate)) }
        let file = try AVAudioFile(forWriting: sound, settings: format.settings)
        try file.write(from: tone)
        file.close()

        let composition = AVMutableComposition()
        let pictureAsset = AVURLAsset(url: picture)
        let soundAsset = AVURLAsset(url: sound)
        let videoTracks = try await pictureAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await soundAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let duration = try await pictureAsset.load(.duration)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        try? FileManager.default.removeItem(at: url)
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await session.export(to: url, as: .mov)
    }

    private func writeSilentFaceMovie(to url: URL, seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let size = CGSize(width: 640, height: 360)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        func waitFor(_ writerInput: AVAssetWriterInput) async throws {
            while !writerInput.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let frames = Int(seconds * Double(fps))
        let font = UIFont.systemFont(ofSize: 220)
        let face = "🧑🏽" as NSString
        let glyph = face.size(withAttributes: [.font: font])
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for frame in 0..<frames {
            try await waitFor(input)
            let x = size.width * (0.4 + 0.2 * CGFloat(frame) / CGFloat(max(frames - 1, 1)))
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(red: 0.82, green: 0.86, blue: 0.9, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                face.draw(at: CGPoint(x: x - glyph.width / 2, y: size.height / 2 - glyph.height / 2), withAttributes: [.font: font])
                UIColor.white.setFill()
                context.fill(CGRect(x: 6, y: 4, width: 196, height: 30))
                ("alex@example.com" as NSString).draw(
                    at: CGPoint(x: 12, y: 8),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: UIColor.black]
                )
            }
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &made)
            let buffer = try XCTUnwrap(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }
}
