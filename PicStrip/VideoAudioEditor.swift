import Accelerate
import AVFoundation

// MARK: - AudioEdit

/// A stretch of a video's sound to hide: bleeped over, or muted.
nonisolated struct AudioEdit: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Silenced, with a tone over it — like a bleep on TV.
        case bleep
        /// Silenced.
        case mute
    }

    let id: Int
    var kind: Kind
    /// Seconds on the video's timeline.
    var range: ClosedRange<Double>
}

// MARK: - VideoAudioEditor

/// Applies `AudioEdit`s: the original sound is silenced over every edited
/// stretch, and a tone is laid over the bleeped ones.  The same edited asset
/// and mix drive the preview and the saved copy.
nonisolated enum VideoAudioEditor {

    static let toneFrequency = 1_000.0
    /// About −12 dB: clearly a bleep, not painfully loud.
    static let toneLevel: Float = 0.25
    /// Fades at the ends of a tone, so it starts and stops without a click.
    static let toneFade = 0.008
    /// How quickly the original sound fades out before a stretch and back after.
    static let silenceFade = 0.01
    /// Silence reaches this far past each end of an edit, so rounding in the
    /// encoder cannot let the first or last syllable through.
    static let silencePadding = 0.05

    /// The asset to play or save, and the mix that silences edited stretches.
    struct Edited: @unchecked Sendable {
        let asset: AVAsset
        let audioMix: AVAudioMix?
        /// The tone laid over bleeps, to delete when done.
        let tone: Tone?

        var toneFile: URL? { tone?.url }
    }

    /// A tone file written for bleeps whose longest is `seconds` long: it fades
    /// out at its end, so it is the same file for as long as that bleep is.
    struct Tone: Hashable, Sendable {
        let url: URL
        let seconds: Double
    }

    /// `url` with `edits` applied to its sound — `url` itself when there are none.
    /// `tone`, from an earlier edit, is laid over the bleeps again while the
    /// longest is as long as it was, rather than a new one written.  Built off
    /// the main actor: writing a tone takes a moment.
    @concurrent
    static func edited(_ url: URL, edits: [AudioEdit], reusing tone: Tone? = nil) async throws -> Edited {
        let source = AVURLAsset(url: url)
        guard !edits.isEmpty else { return Edited(asset: source, audioMix: nil, tone: nil) }

        let composition = AVMutableComposition()
        let duration = try await source.load(.duration)
        for track in try await source.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            let range = try await track.load(.timeRange)
            try copy.insertTimeRange(range, of: track, at: range.start)
            if track.mediaType == .video {
                copy.preferredTransform = try await track.load(.preferredTransform)
            }
        }

        // The original sound is silent over every edited stretch.  Single
        // volume points are blended into slow slides by the mixer, so each
        // stretch is spelled out as ramps: a quick fade that ends as the stretch
        // starts, flat silence across it, and a quick fade back after.
        let silenced = merged(edits.map { ($0.range.lowerBound - silencePadding)...($0.range.upperBound + silencePadding) })
        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in composition.tracks(withMediaType: .audio) {
            let input = AVMutableAudioMixInputParameters(track: track)
            var cursor = 0.0
            for range in silenced {
                let fadeStart = max(cursor, range.lowerBound - silenceFade)
                if fadeStart > cursor {
                    input.setVolumeRamp(fromStartVolume: 1, toEndVolume: 1, timeRange: timeRange(cursor, fadeStart))
                }
                if range.lowerBound > fadeStart {
                    input.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: timeRange(fadeStart, range.lowerBound))
                }
                input.setVolumeRamp(fromStartVolume: 0, toEndVolume: 0, timeRange: timeRange(range.lowerBound, range.upperBound))
                input.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: 1, timeRange: timeRange(range.upperBound, range.upperBound + silenceFade)
                )
                cursor = range.upperBound + silenceFade
            }
            parameters.append(input)
        }

        // A tone over each bleep, laid end to end on a track of its own so no
        // insert pushes another along.
        var usedTone: Tone?
        let bleeps = merged(edits.filter { $0.kind == .bleep }.map(\.range))
        if let longest = bleeps.map({ $0.upperBound - $0.lowerBound }).max(), longest > 0 {
            let fitting: Tone
            if let tone, tone.seconds == longest {
                fitting = tone
            } else {
                fitting = Tone(url: try writeTone(seconds: longest), seconds: longest)
            }
            usedTone = fitting
            // Held while its track is inserted: a track does not keep its asset.
            let toneAsset = AVURLAsset(url: fitting.url)
            if let toneTrack = try await toneAsset.loadTracks(withMediaType: .audio).first,
               let lane = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var cursor = CMTime.zero
                for bleep in bleeps {
                    let start = time(bleep.lowerBound)
                    if start > cursor {
                        lane.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start))
                    }
                    let length = CMTimeMinimum(time(bleep.upperBound - bleep.lowerBound), duration - start)
                    guard length > .zero else { continue }
                    try lane.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: toneTrack, at: start)
                    cursor = start + length
                }
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return Edited(asset: composition, audioMix: mix, tone: usedTone)
    }

    /// Overlapping or touching stretches as one, in order.
    static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A sine tone, `seconds` long, faded in and out, in the private store.
    static func writeTone(seconds: Double) throws -> URL {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw VideoCleaner.Failure.cannotExport
        }
        let frames = AVAudioFrameCount((seconds * rate).rounded(.up))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else {
            throw VideoCleaner.Failure.cannotExport
        }
        buffer.frameLength = frames
        let fadeFrames = max(1, Int(toneFade * rate))
        for index in 0..<Int(frames) {
            let fade = min(1, Float(min(index, Int(frames) - 1 - index)) / Float(fadeFrames))
            samples[index] = toneLevel * fade * Float(sin(2 * Double.pi * toneFrequency * Double(index) / rate))
        }
        let url = try PrivateFileStore.exports.reserve(extension: "caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        // Its header is written on closing: until then the file cannot be read.
        file.close()
        return url
    }

    /// How loud the sound is across the video, in `count` even slices, 0 … 1
    /// against the loudest — for the timeline's audio lane.  Empty without sound.
    ///
    /// The whole sound is decoded, which takes a while for a long video, so it
    /// is done off the main actor.
    @concurrent
    static func levels(of url: URL, count: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard count > 0,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds, duration > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        var peaks = [Float](repeating: 0, count: count)
        func slot(at time: Double) -> Int {
            min(count - 1, max(0, Int(time / duration * Double(count))))
        }
        while let buffer = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            // Read where the decoder left the samples, a slice's worth at a time.
            try? buffer.withAudioBufferList(flags: .audioBufferListAssure16ByteAlignment) { list, _ in
                guard let audio = list.first, let data = audio.mData else { return }
                let samples = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self), count: Int(audio.mDataByteSize) / MemoryLayout<Float>.stride
                )
                var index = 0
                while index < samples.count {
                    let current = slot(at: start + Double(index) / rate)
                    // The first sample in the next slice.
                    let next = current == count - 1
                        ? samples.count
                        : Int(((Double(current + 1) * duration / Double(count) - start) * rate).rounded(.up))
                    let end = min(samples.count, max(index + 1, next))
                    peaks[current] = max(peaks[current], vDSP.maximumMagnitude(UnsafeBufferPointer(rebasing: samples[index..<end])))
                    index = end
                }
            }
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    private static func timeRange(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(max(start, end)))
    }
}
