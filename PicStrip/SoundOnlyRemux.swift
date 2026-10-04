import AVFoundation

// MARK: - SoundOnlyRemux

/// Writes a copy of a video whose sound was edited (`VideoAudioEditor`) and
/// whose pictures were not: the video samples are copied as they are, and
/// only the mixed sound is encoded again.  Encoding a whole video again to
/// bleep a word took as long as covering faces, and cost picture quality.
///
/// The metadata is the caller's to choose (`VideoCleaner.clean`), as for an
/// export: the file carries exactly `metadata`, under the same sharing filter,
/// and no track carries any.  The caller still reads the copy back and fails
/// closed.
nonisolated enum SoundOnlyRemux {

    /// AAC's highest sample rate in common use.
    private static let highestRate = 48_000.0
    private static let lowestRate = 8_000.0
    /// AAC bit rate per channel: near what the highest-quality export preset
    /// gave the sound before (a little over 200 kbit/s for mono).
    private static let bitRatePerChannel = 160_000

    /// The samples are moved on queues of the writer's: the caller's actor only
    /// sets the copy up and waits.
    static func write(
        _ asset: AVAsset,
        audioMix: AVAudioMix,
        to output: URL,
        metadata: [AVMetadataItem],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.metadata = fileMetadata(metadata)

        var pumps: [SamplePump] = []
        for track in videoTracks {
            let (formats, transform, timeScale) = try await track.load(.formatDescriptions, .preferredTransform, .naturalTimeScale)
            // No settings: the samples come out and go in as they were encoded.
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            samples.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
            input.transform = transform
            if timeScale > 0 { input.mediaTimeScale = timeScale }
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(samples), writer.canAdd(input) else { throw VideoCleaner.Failure.cannotExport }
            reader.add(samples)
            writer.add(input)
            pumps.append(SamplePump(output: samples, input: input))
        }
        if !audioTracks.isEmpty {
            let (rate, channels) = try await soundFormat(of: audioTracks)
            // Every sound track — the original and the bleeps' tones — mixed
            // into one, through the mix that silences the edited stretches.
            let mixed = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            mixed.audioMix = audioMix
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRatePerChannel * channels
            ])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(mixed), writer.canAdd(input) else { throw VideoCleaner.Failure.cannotExport }
            reader.add(mixed)
            writer.add(input)
            pumps.append(SamplePump(output: mixed, input: input))
        }
        guard !pumps.isEmpty else { throw VideoCleaner.Failure.cannotExport }

        guard reader.startReading() else { throw reader.error ?? VideoCleaner.Failure.cannotExport }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? VideoCleaner.Failure.cannotExport
        }
        writer.startSession(atSourceTime: .zero)

        // The first video track reports how far the copy has got.
        if let first = pumps.first, !videoTracks.isEmpty, let progress {
            let reporter = ProgressReporter(duration: duration.seconds, report: progress)
            first.onSample = { time in reporter.reached(time) }
        }

        // Every track is fed as the writer asks for it, each on its own queue:
        // fed one after the other, the writer waits on one input for the other.
        let allPumps = pumps
        let fed = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                for pump in allPumps { group.addTask { await pump.run() } }
                var fed = true
                // One track the writer would not take stops them all: the
                // others could wait on the writer for ever.
                for await result in group where !result {
                    fed = false
                    allPumps.forEach { $0.stop() }
                }
                return fed
            }
        } onCancel: {
            allPumps.forEach { $0.stop() }
        }
        if Task.isCancelled || !fed || reader.status != .completed {
            // Only now, with every pump stopped: cancelling the reader while
            // one waits for a sample crashes inside AVFoundation.
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            try Task.checkCancellation()
            throw writer.error ?? reader.error ?? VideoCleaner.Failure.cannotExport
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? VideoCleaner.Failure.cannotExport
        }
        progress?(1)
    }

    /// The file-level metadata: the caller's items, through the filter an
    /// export applies for sharing.  Track-level metadata is never written.
    private static func fileMetadata(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
        AVMetadataItem.metadataItems(from: items, filteredBy: .forSharing())
    }

    /// The original sound's sample rate and channels, as AAC carries them:
    /// within its rates, and at most stereo.
    private static func soundFormat(of tracks: [AVAssetTrack]) async throws -> (rate: Double, channels: Int) {
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  description.mSampleRate > 0 else { continue }
            let rate = min(max(description.mSampleRate, lowestRate), highestRate)
            let channels = min(max(Int(description.mChannelsPerFrame), 1), 2)
            return (rate, channels)
        }
        return (44_100, 2)
    }
}

// MARK: - SamplePump

/// Moves one track's samples from the reader to the writer whenever the
/// writer is ready for more, on a queue of its own.
nonisolated private final class SamplePump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.northcutt.PicStrip.remux")
    /// Called with each sample's time, on the pump's queue.
    var onSample: (@Sendable (CMTime) -> Void)?
    /// Both touched only on `queue`.
    private var waiting: CheckedContinuation<Bool, Never>?
    private var isDone = false
    /// Set from anywhere to stop at the next sample.
    private let stopping = NSLock()
    private var isStopping = false

    private var shouldStop: Bool { stopping.withLock { isStopping } }

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    /// Feeds every sample; `false` if the writer would not take one, or the
    /// pump was stopped.
    func run() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                // Stopped before it started: a finished input takes no requests.
                guard !isDone else { return continuation.resume(returning: false) }
                waiting = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while !isDone, input.isReadyForMoreMediaData {
                        guard !shouldStop else { return finish(fed: false) }
                        guard let buffer = output.copyNextSampleBuffer() else {
                            finish(fed: true)
                            return
                        }
                        // Markers without media have nothing to copy.
                        guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
                        guard input.append(buffer) else {
                            finish(fed: false)
                            return
                        }
                        onSample?(CMSampleBufferGetPresentationTimeStamp(buffer))
                    }
                }
            }
        }
    }

    /// Gives up on the rest: the copy is being abandoned.  A pump copying
    /// stops at its next sample, and one waiting for the writer at once.
    func stop() {
        stopping.withLock { isStopping = true }
        queue.async { [self] in finish(fed: false) }
    }

    /// Done with this track.  The input is marked finished whatever the
    /// reason: until it is, the writer keeps asking for more.
    private func finish(fed: Bool) {
        guard !isDone else { return }
        isDone = true
        input.markAsFinished()
        waiting?.resume(returning: fed)
        waiting = nil
    }
}

// MARK: - ProgressReporter

/// Turns sample times into a fraction done, reported each time it has grown
/// by a hundredth rather than for every sample.
nonisolated private final class ProgressReporter: @unchecked Sendable {
    private let duration: Double
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var reported = 0.0

    init(duration: Double, report: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.report = report
    }

    func reached(_ time: CMTime) {
        guard duration > 0 else { return }
        let fraction = min(1, max(0, time.seconds / duration))
        let due: Bool = lock.withLock {
            guard fraction - reported >= 0.01 else { return false }
            reported = fraction
            return true
        }
        if due { report(fraction) }
    }
}
