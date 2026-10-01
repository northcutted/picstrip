import CoreGraphics

// MARK: - FaceTrack

/// One face followed through a video: where it was each time the video was
/// looked at.  Boxes are normalised with a top-left origin, in the video's
/// upright (displayed) orientation — the same space as every other region.
nonisolated struct FaceTrack: Identifiable, Hashable, Sendable {
    struct Sample: Hashable, Sendable {
        /// Seconds on the video's timeline.
        let time: Double
        let box: CGRect
    }

    let id: Int
    var samples: [Sample]

    var start: Double { samples.first?.time ?? 0 }
    var end: Double { samples.last?.time ?? 0 }

    /// The box to cover at `time`, padded, or `nil` when the face is not on screen.
    ///
    /// Between two sightings the box moves in a straight line, which also covers
    /// the moments the face was missed.  Before the first sighting and after the
    /// last, the face stays covered for `FaceTracking.hold`: a face is usually on
    /// screen a little before it is big or square-on enough to be found.
    func coverBox(at time: Double) -> CGRect? {
        guard let first = samples.first, let last = samples.last,
              time >= first.time - FaceTracking.hold, time <= last.time + FaceTracking.hold
        else { return nil }
        let box: CGRect
        if time <= first.time {
            box = first.box
        } else if time >= last.time {
            box = last.box
        } else {
            // `low` ends on the last sample at or before `time`.
            var low = 0
            var high = samples.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if samples[middle].time <= time { low = middle } else { high = middle }
            }
            let before = samples[low]
            let after = samples[high]
            let span = after.time - before.time
            box = FaceTracking.blend(before.box, after.box, by: span > 0 ? CGFloat((time - before.time) / span) : 0)
        }
        return FaceTracking.padded(box)
    }

    /// The sample nearest the middle of the track: the face's most typical look.
    var representativeSample: Sample? {
        samples.isEmpty ? nil : samples[samples.count / 2]
    }
}

// MARK: - FaceTracking

/// Links the faces found in a video's sampled frames into tracks, one sampled
/// frame at a time, in the order they play.
nonisolated struct FaceTracking {
    /// How often frames are looked at, in seconds.
    static let sampleInterval = 0.1
    /// Added on every side of a found face, as a share of its size: a face box
    /// stops short of the ears and chin, and the face moves between samples.
    static let padding: CGFloat = 0.15
    /// Added above instead: a face box starts at the eyebrows, so this takes in
    /// the forehead and hairline.
    static let foreheadPadding: CGFloat = 0.35
    /// How long a face stays covered before it is first found and after it is last seen.
    /// Generous on purpose: a face is often on screen before it is found, and a
    /// small one in the background is found only now and then.
    static let hold = 1.0
    /// A face unseen for longer than this starts a new track when it is found
    /// again; within it, the cover is carried across.  Linking too much only
    /// covers a little more; splitting leaves the face bare in the gap.
    static let maximumGap = 2.0

    private var finished: [FaceTrack] = []
    private var active: [FaceTrack] = []
    private var nextID = 0

    private struct Pair {
        let track: Int
        let box: Int
        let score: CGFloat
    }

    /// Adds the faces found in the frame at `time`.  Times must not go backwards.
    mutating func add(_ boxes: [CGRect], at time: Double) {
        finished += active.filter { time - $0.end > Self.maximumGap }
        active.removeAll { time - $0.end > Self.maximumGap }

        // Greedy: the closest track-and-face pairs claim each other first.
        var pairs: [Pair] = []
        for (trackIndex, track) in active.enumerated() {
            guard let last = track.samples.last?.box else { continue }
            for (boxIndex, box) in boxes.enumerated() {
                let score = Self.matchScore(last, box)
                if score > 0 { pairs.append(Pair(track: trackIndex, box: boxIndex, score: score)) }
            }
        }
        pairs.sort { $0.score > $1.score }

        var matchedTracks = Set<Int>()
        var matchedBoxes = Set<Int>()
        for pair in pairs where !matchedTracks.contains(pair.track) && !matchedBoxes.contains(pair.box) {
            matchedTracks.insert(pair.track)
            matchedBoxes.insert(pair.box)
            active[pair.track].samples.append(FaceTrack.Sample(time: time, box: boxes[pair.box]))
        }
        for (index, box) in boxes.enumerated() where !matchedBoxes.contains(index) {
            active.append(FaceTrack(id: nextID, samples: [FaceTrack.Sample(time: time, box: box)]))
            nextID += 1
        }
    }

    /// Every track so far, in the order the faces first appeared.
    var tracks: [FaceTrack] {
        (finished + active).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// How likely two boxes, a sample apart, are the same face: overlapping boxes
    /// score above 1 by their overlap; boxes apart score below 1 by how near they
    /// are, within one and a half times the larger — a face crossing the frame
    /// close up moves about its own width in a tenth of a second.  Zero means a
    /// different face.
    static func matchScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        if !intersection.isNull, intersection.width > 0, intersection.height > 0 {
            let shared = intersection.width * intersection.height
            return 1 + shared / (lhs.width * lhs.height + rhs.width * rhs.height - shared)
        }
        let distance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
        let reach = 1.5 * max(lhs.width, lhs.height, rhs.width, rhs.height)
        return distance < reach ? 1 - distance / reach : 0
    }

    static func blend(_ from: CGRect, _ to: CGRect, by amount: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * amount,
            y: from.minY + (to.minY - from.minY) * amount,
            width: from.width + (to.width - from.width) * amount,
            height: from.height + (to.height - from.height) * amount
        )
    }

    /// `box` (top-left origin) grown by `padding`, and by `foreheadPadding` above.
    static func padded(_ box: CGRect) -> CGRect {
        CGRect(
            x: box.minX - box.width * padding,
            y: box.minY - box.height * foreheadPadding,
            width: box.width * (1 + 2 * padding),
            height: box.height * (1 + padding + foreheadPadding)
        )
    }
}
