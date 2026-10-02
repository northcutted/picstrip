import AVFoundation
import CoreImage
import Vision

// MARK: - VideoObjectFollower

/// Follows something the user drew a box around through a video — forward
/// from the moment they drew it until the tracker loses it or the video ends,
/// and back the same way — so a cover the scan missed moves with its subject.
nonisolated enum VideoObjectFollower {

    /// Below this, the tracker is guessing.
    static let minimumConfidence: Float = 0.3
    /// Guesses in a row before the subject counts as lost.
    static let missesAllowed = 3
    /// How much is read at a time going backwards: frames are read forwards,
    /// so a stretch is read, then followed in reverse.
    static let backwardStretch = 2.0
    /// Frames are followed at this size: enough to hold on to a subject.
    static let longSide: CGFloat = 640

    /// Where the subject in `box` (normalised, top-left origin, upright) at
    /// `time` is at each looked-at moment it can be followed to, in time order.
    /// `progress` runs 0 … 1 over the whole follow.
    @concurrent
    static func follow(
        _ box: CGRect,
        at time: Double,
        in url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [FaceTrack.Sample] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCleaner.Failure.cannotExport
        }
        let duration = try await asset.load(.duration).seconds
        let shrinker = FrameShrinker(longSide: longSide)
        let span = max(duration, FaceTracking.sampleInterval)

        // Forwards, from the drawn frame.
        var forward: [FaceTrack.Sample] = [FaceTrack.Sample(time: time, box: box)]
        do {
            let range = CMTimeRange(
                start: CMTime(seconds: time, preferredTimescale: 600),
                end: CMTime(seconds: duration, preferredTimescale: 600)
            )
            let (reader, output) = try await VideoScanner.uprightReader(for: asset, track: track, timeRange: range)
            defer { reader.cancelReading() }
            var tracker = Tracker(box: box)
            var isFirst = true
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
                let frameTime = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                let small = shrinker.shrink(pixels) ?? pixels
                if isFirst {
                    // The drawn frame starts the tracker; it is not followed.
                    isFirst = false
                    _ = try? await tracker.follow(into: small)
                    continue
                }
                guard let next = try await tracker.follow(into: small) else {
                    if tracker.isLost { break }
                    continue
                }
                forward.append(FaceTrack.Sample(time: frameTime, box: next))
                progress(min(1, (frameTime - time) / span))
            }
        }

        // Backwards, a stretch at a time.
        var backward: [FaceTrack.Sample] = []
        var tracker = Tracker(box: box)
        var stretchEnd = time
        backwards: while stretchEnd > 0 {
            try Task.checkCancellation()
            let stretchStart = max(0, stretchEnd - backwardStretch)
            let range = CMTimeRange(
                start: CMTime(seconds: stretchStart, preferredTimescale: 600),
                end: CMTime(seconds: stretchEnd, preferredTimescale: 600)
            )
            let (reader, output) = try await VideoScanner.uprightReader(for: asset, track: track, timeRange: range)
            var frames: [(time: Double, pixels: CVPixelBuffer)] = []
            while let buffer = output.copyNextSampleBuffer() {
                guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
                let frameTime = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                // The drawn frame itself is already the start of the forward pass.
                guard frameTime < stretchEnd - 0.001, let small = shrinker.shrink(pixels) else { continue }
                frames.append((frameTime, small))
            }
            reader.cancelReading()
            if backward.isEmpty, frames.isEmpty { break }
            for frame in frames.reversed() {
                try Task.checkCancellation()
                guard let next = try await tracker.follow(into: frame.pixels) else {
                    if tracker.isLost { break backwards }
                    continue
                }
                backward.append(FaceTrack.Sample(time: frame.time, box: next))
                progress(min(1, (duration - time + (time - frame.time)) / span))
            }
            stretchEnd = stretchStart
        }
        progress(1)
        return backward.reversed() + forward
    }

    /// One direction of following: Vision's object tracker, and how many
    /// guesses it has made in a row.
    private struct Tracker {
        private var request: TrackObjectRequest
        private var misses = 0

        init(box: CGRect) {
            let vision = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            request = PIIScanner.onSimulatorCPU(TrackObjectRequest(
                detectedObject: DetectedObjectObservation(boundingBox: NormalizedRect(normalizedRect: vision))
            ))
        }

        var isLost: Bool { misses >= VideoObjectFollower.missesAllowed }

        /// The subject's box in `pixels`, or `nil` while the tracker is unsure.
        mutating func follow(into pixels: CVPixelBuffer) async throws -> CGRect? {
            let observation: DetectedObjectObservation??
            do {
                observation = try await ImageRequestHandler(pixels).perform(request)
            } catch {
                try Task.checkCancellation()
                misses += 1
                return nil
            }
            guard let found = observation ?? nil, found.confidence >= VideoObjectFollower.minimumConfidence else {
                misses += 1
                return nil
            }
            misses = 0
            let box = PIIScanner.swiftUIBox(from: found.boundingBox.cgRect)
            guard box.width > 0.005, box.height > 0.005, CGRect(x: 0, y: 0, width: 1, height: 1).intersects(box) else {
                misses = VideoObjectFollower.missesAllowed
                return nil
            }
            return box
        }
    }
}
