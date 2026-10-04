import CoreGraphics
import Foundation

// The viewfinder's bookkeeping, kept free of AVFoundation and SwiftUI so it can
// be tested without a camera.  Every box here is normalised with a top-left
// origin, like `LiveDetection.boundingBox`.

// MARK: - LiveTrack

/// A finding the viewfinder is following from one pass to the next.
nonisolated struct LiveTrack: Identifiable, Equatable, Sendable {
    let id: Int
    let type: PIIType
    /// Where it is in the stabilised space of `LiveMotion`: the frame it was
    /// found in, shifted back by the camera motion up to that frame.
    var box: CGRect
    /// The match score, smoothed over the passes that saw it.
    var score: Double
    /// The match strength shown for it — `score`'s band, changed only once the
    /// score is clearly past a boundary, so the label does not flicker.
    var confidence: ConfidenceLevel
    /// Consecutive passes that have not seen it; zero while it is in view.
    var missedPasses = 0

    init(id: Int, type: PIIType, box: CGRect, score: Double) {
        self.id = id
        self.type = type
        self.box = box
        self.score = score
        self.confidence = ConfidenceLevel(score: score)
    }
}

// MARK: - LiveDetectionTracker

/// Matches each pass's findings to the ones already on screen, so a box keeps
/// its identity — and animates — instead of blinking out and back in whenever
/// OCR misreads a line for one frame.
nonisolated struct LiveDetectionTracker {

    /// How much two boxes must overlap to be the same finding.
    static let minimumOverlap: CGFloat = 0.3
    /// A box that mostly contains, or sits inside, the old one is the same finding
    /// read more or less completely.
    static let minimumContainment: CGFloat = 0.7

    /// Passes a finding stays on screen unseen before it is dropped.
    let maximumMissedPasses: Int
    /// The share of a new position taken on each pass; the rest is the old one.
    let smoothing: CGFloat

    private(set) var tracks: [LiveTrack] = []
    private var nextID = 0

    init(maximumMissedPasses: Int = 2, smoothing: CGFloat = 0.6) {
        self.maximumMissedPasses = maximumMissedPasses
        self.smoothing = smoothing
    }

    private struct Pair {
        let track: Int
        let detection: Int
        let score: CGFloat
    }

    mutating func update(with detections: [LiveDetection]) {
        // Greedy: the best-overlapping pairs of the same type claim each other first.
        var pairs: [Pair] = []
        for (trackIndex, track) in tracks.enumerated() {
            for (detectionIndex, detection) in detections.enumerated() where detection.type == track.type {
                let score = Self.matchScore(track.box, detection.boundingBox)
                if score > 0 { pairs.append(Pair(track: trackIndex, detection: detectionIndex, score: score)) }
            }
        }
        pairs.sort { $0.score > $1.score }

        var updated = tracks
        var matchedTracks = Set<Int>()
        var matchedDetections = Set<Int>()
        for pair in pairs where !matchedTracks.contains(pair.track) && !matchedDetections.contains(pair.detection) {
            matchedTracks.insert(pair.track)
            matchedDetections.insert(pair.detection)
            let detection = detections[pair.detection]
            var track = updated[pair.track]
            track.box = Self.blend(track.box, detection.boundingBox, by: smoothing)
            track.score += (detection.score - track.score) * smoothing
            track.confidence = Self.confidence(for: track.score, showing: track.confidence)
            track.missedPasses = 0
            updated[pair.track] = track
        }

        var next: [LiveTrack] = []
        for (index, var track) in updated.enumerated() {
            if !matchedTracks.contains(index) { track.missedPasses += 1 }
            if track.missedPasses <= maximumMissedPasses { next.append(track) }
        }
        for (index, detection) in detections.enumerated() where !matchedDetections.contains(index) {
            next.append(LiveTrack(id: nextID, type: detection.type, box: detection.boundingBox, score: detection.score))
            nextID += 1
        }
        tracks = next
    }

    /// Forget everything — the picture changed in a way motion cannot follow
    /// (rotation, zoom, a pause).
    mutating func removeAll() {
        tracks = []
    }

    /// Intersection over union when the boxes overlap enough, otherwise zero.
    static func matchScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let shared = intersection.width * intersection.height
        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        let overlap = shared / (lhsArea + rhsArea - shared)
        let containment = shared / min(lhsArea, rhsArea)
        return overlap >= minimumOverlap || containment >= minimumContainment ? overlap : 0
    }

    /// How far past a band boundary a score must move before the band shown changes.
    static let confidenceHysteresis = 0.03

    /// The band to show for `score` when `current` is on screen: `score`'s own
    /// band, unless it is within `confidenceHysteresis` of the boundary it crossed.
    static func confidence(for score: Double, showing current: ConfidenceLevel) -> ConfidenceLevel {
        let band = ConfidenceLevel(score: score)
        guard band != current else { return current }
        let settled = ConfidenceLevel(score: band > current ? score - confidenceHysteresis : score + confidenceHysteresis)
        return settled == current ? current : band
    }

    static func blend(_ from: CGRect, _ to: CGRect, by amount: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * amount,
            y: from.minY + (to.minY - from.minY) * amount,
            width: from.width + (to.width - from.width) * amount,
            height: from.height + (to.height - from.height) * amount
        )
    }
}

// MARK: - LiveMotion

/// How far the picture has slid since the session started, so boxes found a
/// moment ago can be drawn where their content is now.
nonisolated struct LiveMotion {
    /// Total displacement of the picture's content, normalised to the frame.
    private(set) var offset: CGVector = .zero
    /// Frame lengths per second, smoothed over the last few measurements.
    private(set) var speed: CGFloat = 0
    private var lastTime: TimeInterval?

    /// Adds the displacement measured between two frames, the later one at `time`.
    mutating func add(_ shift: CGVector, at time: TimeInterval) {
        offset.dx += shift.dx
        offset.dy += shift.dy
        if let lastTime, time > lastTime {
            let instant = hypot(shift.dx, shift.dy) / CGFloat(time - lastTime)
            speed = speed * 0.5 + instant * 0.5
        }
        lastTime = time
    }

    /// Continuity was lost (a pause, an interruption): keep the offset, which the
    /// boxes on screen are anchored to, but measure speed afresh.
    mutating func restart() {
        speed = 0
        lastTime = nil
    }
}

// MARK: - LiveAnalysisPacing

/// How often the viewfinder looks.
nonisolated enum LiveAnalysisPacing {
    /// Between the starts of two passes on a cool phone.
    static let baseInterval: TimeInterval = 0.35
    /// On a phone that is warming up (`.fair`), before analysis pauses at `.serious`.
    static let warmInterval: TimeInterval = 0.6
    /// Faster than this — in frame lengths per second — the frame is too blurred
    /// for OCR to read, and a pass would only make the boxes flicker.
    static let maximumAnalysisSpeed: CGFloat = 0.8

    /// The interval before the next pass may start.  A device slower than the
    /// base interval still gets a rest of half its pass time between passes, so
    /// the Neural Engine never runs back to back.
    static func interval(thermalState: ProcessInfo.ThermalState, lastPassDuration: TimeInterval) -> TimeInterval {
        let base = thermalState == .nominal ? baseInterval : warmInterval
        return max(base, lastPassDuration * 1.5)
    }

    /// Held still over the same picture, a pass only re-reads what is already
    /// boxed, so the viewfinder looks this often until the picture moves.
    static let settledInterval: TimeInterval = 1.2
    /// How far the picture must move after a pass started, as a fraction of the
    /// frame, for the next one to come at the full rate.
    static let settledDistance: CGFloat = 0.02

    /// `interval`, stretched to `settledInterval` while the picture has hardly
    /// moved since the last pass started; `moved` is `nil` before the first pass.
    static func interval(_ interval: TimeInterval, movedSinceLastPass moved: CGFloat?) -> TimeInterval {
        guard let moved, moved < settledDistance else { return interval }
        return max(interval, settledInterval)
    }

    /// Whether the thermal state calls for no analysis at all.
    static func isTooHot(_ thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState == .serious || thermalState == .critical
    }
}

// MARK: - LiveLabelLayout

/// Where each box's label goes, in view points.
nonisolated enum LiveLabelLayout {

    enum Placement: Equatable {
        /// A full label in this rect.
        case label(CGRect)
        /// No room for a label without covering another box or label: a symbol
        /// on the box's corner instead.
        case badge
    }

    struct Item {
        let id: Int
        let box: CGRect
        let labelSize: CGSize
    }

    /// Most labels shown at once; the rest get badges.
    static let maximumLabels = 8
    /// How far a label may overlap a box's padding before it counts as covering it.
    static let tolerance: CGFloat = 3

    /// `items` in priority order, most important first: a label goes above its
    /// box, else below, else after or before it on the same line.  It must stay
    /// in `bounds` and cover no other box or label, nor anything in `obstacles`
    /// (the viewfinder's controls); where it can, it also leaves `textLines`
    /// readable.
    static func place(
        _ items: [Item],
        in bounds: CGRect,
        avoiding obstacles: [CGRect] = [],
        textLines: [CGRect] = [],
        gap: CGFloat = 4
    ) -> [Int: Placement] {
        var placed: [CGRect] = []
        var result: [Int: Placement] = [:]
        for (index, item) in items.enumerated() {
            guard index < maximumLabels else {
                result[item.id] = .badge
                continue
            }
            let size = item.labelSize
            let x = min(max(item.box.minX, bounds.minX), bounds.maxX - size.width)
            let y = item.box.midY - size.height / 2
            let candidates = [
                CGRect(origin: CGPoint(x: x, y: item.box.minY - gap - size.height), size: size),
                CGRect(origin: CGPoint(x: x, y: item.box.maxY + gap), size: size),
                CGRect(origin: CGPoint(x: item.box.maxX + gap, y: y), size: size),
                CGRect(origin: CGPoint(x: item.box.minX - gap - size.width, y: y), size: size)
            ]
            let blocked = items.filter { $0.id != item.id }.map(\.box) + obstacles
            let allowed = candidates.filter { candidate in
                let probe = candidate.insetBy(dx: tolerance, dy: tolerance)
                return bounds.contains(candidate)
                    && !placed.contains { $0.intersects(candidate) }
                    && !blocked.contains { $0.intersects(probe) }
            }
            let fit = allowed.first { candidate in
                let probe = candidate.insetBy(dx: tolerance, dy: tolerance)
                return !textLines.contains { $0.intersects(probe) }
            } ?? allowed.first
            if let fit {
                placed.append(fit)
                result[item.id] = .label(fit)
            } else {
                result[item.id] = .badge
            }
        }
        return result
    }
}

// MARK: - LiveScanSummary

/// What is in view, by kind: the viewfinder's status line.
nonisolated struct LiveScanSummary: Equatable {
    struct Entry: Equatable {
        let type: PIIType
        let count: Int
    }

    /// Highest risk first, then the most frequent.
    let entries: [Entry]

    init(tracks: [LiveTrack]) {
        var counts: [PIIType: Int] = [:]
        for track in tracks { counts[track.type, default: 0] += 1 }
        entries = counts
            .map { Entry(type: $0.key, count: $0.value) }
            .sorted {
                if $0.type.riskLevel != $1.type.riskLevel { return $0.type.riskLevel > $1.type.riskLevel }
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.type.rawValue < $1.type.rawValue
            }
    }

    var isEmpty: Bool { entries.isEmpty }
    var highestRisk: RiskLevel? { entries.first?.type.riskLevel }
    var types: [PIIType] { entries.map(\.type) }
}
