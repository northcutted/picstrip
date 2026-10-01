import CoreGraphics
import Foundation

// MARK: - CameraPath

/// How far the picture has slid since the start of a video, measured between
/// the frames the faces are looked for in.  It lets a box found at one moment
/// follow its content to another: text is read only twice a second.
nonisolated struct CameraPath: Hashable, Sendable {
    struct Point: Hashable, Sendable {
        let time: Double
        /// Total displacement of the content so far, normalised, top-left origin.
        let offset: CGVector
    }

    private(set) var points: [Point] = []

    /// Records the content's `shift` since the previous point; `nil` (the first
    /// frame, or a frame Vision could not register) counts as no movement.
    mutating func add(_ shift: CGVector?, at time: Double) {
        let last = points.last?.offset ?? .zero
        let shift = shift ?? .zero
        points.append(Point(time: time, offset: CGVector(dx: last.dx + shift.dx, dy: last.dy + shift.dy)))
    }

    /// The displacement at `time`, between the points around it.
    func offset(at time: Double) -> CGVector {
        guard let first = points.first, let last = points.last else { return .zero }
        if time <= first.time { return first.offset }
        if time >= last.time { return last.offset }
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].time <= time { low = middle } else { high = middle }
        }
        let before = points[low]
        let after = points[high]
        let span = after.time - before.time
        let amount = span > 0 ? CGFloat((time - before.time) / span) : 0
        return CGVector(
            dx: before.offset.dx + (after.offset.dx - before.offset.dx) * amount,
            dy: before.offset.dy + (after.offset.dy - before.offset.dy) * amount
        )
    }

    /// The farthest a box is carried from where it was seen.  Further than this
    /// in the second or so a cover is held, the measurement is more likely wrong
    /// (a repeating pattern, a cut) than the camera that fast.
    static let maximumCarry: CGFloat = 0.2

    /// `box`, seen at `from`, moved with the picture to where it is at `to` —
    /// or left where it was if that is implausibly far.
    func move(_ box: CGRect, from: Double, to: Double) -> CGRect {
        let start = offset(at: from)
        let end = offset(at: to)
        let shift = CGVector(dx: end.dx - start.dx, dy: end.dy - start.dy)
        guard hypot(shift.dx, shift.dy) <= Self.maximumCarry else { return box }
        return box.offsetBy(dx: shift.dx, dy: shift.dy)
    }

    /// Whether the path agrees with two sightings of the same thing: carried
    /// from the first, it lands near the second.
    func agrees(_ first: FindingTrack.Sample, _ second: FindingTrack.Sample) -> Bool {
        let carried = move(first.box, from: first.time, to: second.time)
        let miss = hypot(carried.midX - second.box.midX, carried.midY - second.box.midY)
        return miss <= max(0.05, second.box.height * 1.5)
    }
}

// MARK: - FindingTrack

/// One piece of sensitive text or one code followed through a video.
nonisolated struct FindingTrack: Identifiable, Hashable, Sendable {
    struct Sample: Hashable, Sendable {
        let time: Double
        /// Normalised, top-left origin, upright.
        let box: CGRect
    }

    let id: Int
    let type: PIIType
    /// What it says, as first read.
    let snippet: String
    var samples: [Sample]

    var start: Double { samples.first?.time ?? 0 }
    var end: Double { samples.last?.time ?? 0 }

    /// The box to cover at `time`, padded, or `nil` when it is not on screen.
    ///
    /// Each sighting is carried along `path` to `time`; between two sightings
    /// the two carried boxes are blended, so the cover follows the camera
    /// between reads and still lands on the next one.
    func coverBox(at time: Double, path: CameraPath) -> CGRect? {
        guard let first = samples.first, let last = samples.last,
              time >= first.time - FindingTracking.hold, time <= last.time + FindingTracking.hold
        else { return nil }
        let box: CGRect
        if time <= first.time {
            box = path.move(first.box, from: first.time, to: time)
        } else if time >= last.time {
            box = path.move(last.box, from: last.time, to: time)
        } else {
            var low = 0
            var high = samples.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if samples[middle].time <= time { low = middle } else { high = middle }
            }
            let before = samples[low]
            let after = samples[high]
            let span = after.time - before.time
            let amount = span > 0 ? CGFloat((time - before.time) / span) : 0
            // Where the path disagrees with what was read, it is not trusted
            // for this stretch: the cover moves straight from one read to the next.
            box = path.agrees(before, after)
                ? FaceTracking.blend(
                    path.move(before.box, from: before.time, to: time),
                    path.move(after.box, from: after.time, to: time),
                    by: amount
                )
                : FaceTracking.blend(before.box, after.box, by: amount)
        }
        return FindingTracking.padded(box)
    }

    var representativeSample: Sample? {
        samples.isEmpty ? nil : samples[samples.count / 2]
    }
}

// MARK: - FindingTracking

/// Links the text and codes found in a video's sampled frames into tracks.
nonisolated struct FindingTracking {
    /// How often text is read, in seconds: OCR is far slower than face detection.
    static let sampleInterval = 0.5
    /// How long a finding stays covered before it is first read and after it is
    /// last read — a little over one read, so text that appears just after a
    /// read is covered from the start.
    static let hold = 0.75
    /// A finding unread for longer than this starts a new track.
    static let maximumGap = 1.6

    private var finished: [FindingTrack] = []
    private var active: [FindingTrack] = []
    private var nextID = 0

    private struct Pair {
        let track: Int
        let finding: Int
        let score: CGFloat
    }

    /// Adds the findings read in the frame at `time`, comparing each with where
    /// the earlier sightings have moved to along `path`.
    mutating func add(_ findings: [FrameFinding], at time: Double, path: CameraPath) {
        finished += active.filter { time - $0.end > Self.maximumGap }
        active.removeAll { time - $0.end > Self.maximumGap }

        var pairs: [Pair] = []
        for (trackIndex, track) in active.enumerated() {
            guard let last = track.samples.last else { continue }
            let expected = path.move(last.box, from: last.time, to: time)
            for (findingIndex, finding) in findings.enumerated() where finding.type == track.type {
                // Where the path expects it, or where it was: a wrong path must
                // not split a track.
                var score = max(
                    FaceTracking.matchScore(expected, finding.boundingBox),
                    FaceTracking.matchScore(last.box, finding.boundingBox)
                )
                guard score > 0 else { continue }
                // The same words again: almost certainly the same finding.
                if Self.normalized(finding.snippet) == Self.normalized(track.snippet) { score += 1 }
                pairs.append(Pair(track: trackIndex, finding: findingIndex, score: score))
            }
        }
        pairs.sort { $0.score > $1.score }

        var matchedTracks = Set<Int>()
        var matchedFindings = Set<Int>()
        for pair in pairs where !matchedTracks.contains(pair.track) && !matchedFindings.contains(pair.finding) {
            matchedTracks.insert(pair.track)
            matchedFindings.insert(pair.finding)
            active[pair.track].samples.append(FindingTrack.Sample(time: time, box: findings[pair.finding].boundingBox))
        }
        for (index, finding) in findings.enumerated() where !matchedFindings.contains(index) {
            active.append(FindingTrack(
                id: nextID, type: finding.type, snippet: finding.snippet,
                samples: [FindingTrack.Sample(time: time, box: finding.boundingBox)]
            ))
            nextID += 1
        }
    }

    /// Every track so far, in the order the findings first appeared.
    var tracks: [FindingTrack] {
        (finished + active).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Text boxes are tight around the glyphs, and the camera can turn or zoom
    /// between reads, which the path does not model: pad by the text's height.
    static func padded(_ box: CGRect) -> CGRect {
        box.insetBy(dx: -(box.height * 0.4 + box.width * 0.03), dy: -box.height * 0.4)
    }

    /// The snippet compared and grouped by: case, spaces and punctuation ignored.
    static func normalized(_ snippet: String) -> String {
        String(snippet.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: - FindingGroup

/// The tracks that read the same: one row in the list, covered or not together.
nonisolated struct FindingGroup: Identifiable, Hashable, Sendable {
    let id: String
    let type: PIIType
    let snippet: String
    let tracks: [FindingTrack]

    var start: Double { tracks.map(\.start).min() ?? 0 }

    static func groups(of tracks: [FindingTrack]) -> [FindingGroup] {
        var order: [String] = []
        var members: [String: [FindingTrack]] = [:]
        for track in tracks {
            let key = "\(track.type.rawValue)|\(FindingTracking.normalized(track.snippet))"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(track)
        }
        return order.compactMap { key in
            guard let tracks = members[key], let first = tracks.first else { return nil }
            return FindingGroup(id: key, type: first.type, snippet: first.snippet, tracks: tracks)
        }
    }
}
