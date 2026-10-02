import AVFoundation
import XCTest
@testable import PicStrip

// MARK: - Timing a cover

final class CoverTimingTests: XCTestCase {

    private let track = FaceTrack(id: 0, samples: [
        .init(time: 2.0, box: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)),
        .init(time: 3.0, box: CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.1))
    ])

    func testATrimmedRangeIsExactlyWhenTheCoverIsOn() throws {
        // Started early and ended late: held boxes outside the sightings.
        let longer = 0.5...5.0
        XCTAssertEqual(try XCTUnwrap(track.coverBox(at: 0.6, within: longer)), FaceTracking.padded(track.samples[0].box))
        XCTAssertEqual(try XCTUnwrap(track.coverBox(at: 4.9, within: longer)), FaceTracking.padded(track.samples[1].box))
        XCTAssertNil(track.coverBox(at: 0.4, within: longer))
        XCTAssertNil(track.coverBox(at: 5.1, within: longer))

        // Trimmed to the middle: off at the ends even where it was seen.
        let shorter = 2.4...2.6
        XCTAssertNil(track.coverBox(at: 2.0, within: shorter))
        XCTAssertNotNil(track.coverBox(at: 2.5, within: shorter))
    }

    func testWithoutARangeTheTrackKeepsItsOwnTiming() {
        XCTAssertEqual(track.automaticRange, (2.0 - FaceTracking.hold)...(3.0 + FaceTracking.hold))
        XCTAssertNotNil(track.coverBox(at: 2.0 - FaceTracking.hold + 0.01))
        XCTAssertNil(track.coverBox(at: 3.0 + FaceTracking.hold + 0.01))
    }

    func testADrawnCoverIsWhatWasDrawnPlusALittle() throws {
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)
        let drawn = FaceTrack(id: 1, samples: [.init(time: 1, box: box)], isDrawn: true)
        let cover = try XCTUnwrap(drawn.coverBox(at: 1))
        XCTAssertEqual(cover.width, 0.2 * 1.16, accuracy: 1e-9)
        XCTAssertEqual(cover.midY, box.midY, accuracy: 1e-9, "No extra room above, unlike a face.")
        XCTAssertEqual(drawn.automaticRange, 0.5...1.5, "Lost at once, it still covers a second around where it was drawn.")
        let followed = FaceTrack(id: 2, samples: [.init(time: 1, box: box), .init(time: 4, box: box)], isDrawn: true)
        XCTAssertEqual(followed.automaticRange, 1...4, "Followed: exactly where it was followed, no hold.")
    }
}

// MARK: - Zooming the timeline

final class TimelineZoomTests: XCTestCase {

    func testZoomKeepsTheTimeUnderTheFingers() {
        let whole = TimelineWindow(duration: 60)
        XCTAssertFalse(whole.isZoomed)
        XCTAssertEqual(whole.length, 60)
        // Pinched three quarters of the way across, at 45 s.
        let zoomed = whole.zoomed(to: 4, keeping: 0.75)
        XCTAssertEqual(zoomed.length, 15)
        XCTAssertEqual(zoomed.start + 0.75 * zoomed.length, 45, accuracy: 0.0001)
        XCTAssertTrue(zoomed.isZoomed)
    }

    func testZoomStaysWithinItsLimitsAndTheVideo() {
        let window = TimelineWindow(duration: 10)
        XCTAssertEqual(window.zoomed(to: 0.2, keeping: 0.5).zoom, 1, "No further out than the whole video.")
        XCTAssertEqual(window.zoomed(to: 100, keeping: 0.5).length, TimelineWindow.shortest, "No closer than two seconds.")
        XCTAssertEqual(window.zoomed(to: 4, keeping: 1).end, 10, accuracy: 0.0001, "Zoomed at the end, it ends with the video.")
        XCTAssertEqual(window.zoomed(to: 4, keeping: 0).moved(to: -3).start, 0, "It cannot be moved before the start.")
        XCTAssertEqual(window.zoomed(to: 4, keeping: 0).moved(to: 30).end, 10, accuracy: 0.0001, "…or past the end.")
        XCTAssertEqual(TimelineWindow.maximumZoom(for: 1), 1, "A video shorter than two seconds does not zoom.")
    }

    func testTheWindowFollowsThePlayhead() {
        let window = TimelineWindow(duration: 60, zoom: 6, start: 0)
        XCTAssertEqual(window.revealing(5), window, "In view: it stays put.")
        let moved = window.revealing(30)
        XCTAssertTrue(moved.contains(30))
        XCTAssertEqual(moved.start, 29, accuracy: 0.0001, "The playhead sits a tenth of the way in.")
        let whole = TimelineWindow(duration: 60)
        XCTAssertEqual(whole.revealing(59), whole)
    }

    func testTimesAndPlacesMatchAcrossATrack() {
        let window = TimelineWindow(duration: 60, zoom: 4, start: 20)
        XCTAssertEqual(window.x(20, width: 300), 0)
        XCTAssertEqual(window.x(35, width: 300), 300)
        XCTAssertEqual(window.time(at: 150, width: 300), 27.5, accuracy: 0.0001)
        XCTAssertEqual(window.visiblePart(of: 10...25), 20...25)
        XCTAssertNil(window.visiblePart(of: 40...50))
    }

    func testASelectedStretchIsAtLeastATenthOfASecondWithinTheVideo() {
        XCTAssertEqual(EditorTimeline.selection(from: 4, to: 2, duration: 10), 2...4, "Dragged backwards.")
        XCTAssertEqual(EditorTimeline.selection(from: 3, to: 3, duration: 10).upperBound, 3.1, accuracy: 0.0001)
        XCTAssertEqual(EditorTimeline.selection(from: 9.5, to: 10.5, duration: 10), 9.5...10)
        let atEnd = EditorTimeline.selection(from: 10, to: 10, duration: 10)
        XCTAssertEqual(atEnd.upperBound, 10)
        XCTAssertEqual(atEnd.lowerBound, 9.9, accuracy: 0.0001)
    }

    func testZoomedInDetail() {
        XCTAssertEqual(VideoCleanerModel.filmstripCount(for: 4), 10)
        XCTAssertEqual(VideoCleanerModel.filmstripCount(for: 45), 45, "About a frame a second.")
        XCTAssertEqual(VideoCleanerModel.filmstripCount(for: 3_600), 120)
        XCTAssertEqual(VideoCleanerModel.levelCount(for: 30), 600, "Twenty readings a second.")
        XCTAssertEqual(VideoCleanerModel.levelCount(for: 3_600), 4_000)
        XCTAssertEqual(EditorTimeline.zoomLabel(2), "2×")
        XCTAssertEqual(EditorTimeline.zoomLabel(2.5), "2.5×")
    }
}

// MARK: - Following a drawn box

final class VideoObjectFollowerTests: XCTestCase {

    func testADrawnBoxIsFollowedForwardsAndBack() async throws {
        try skipUnlessVisionModelsRunHere()
        let movie = try await FaceMovie.make()
        defer { try? FileManager.default.removeItem(at: movie.url) }
        // Drawn around the face at one second.
        let center = movie.faceCenter(at: 1.0)
        let width = 150 / movie.displaySize.width
        let height = 150 / movie.displaySize.height
        let box = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)

        let progress = ProgressLog()
        let samples = try await VideoObjectFollower.follow(box, at: 1.0, in: movie.url) { progress.add($0) }

        XCTAssertEqual(samples.map(\.time), samples.map(\.time).sorted(), "In time order.")
        XCTAssertLessThan(try XCTUnwrap(samples.first).time, 0.5, "Followed back towards the start.")
        XCTAssertGreaterThan(try XCTUnwrap(samples.last).time, 1.5, "Followed on towards the end.")
        for sample in samples {
            let expected = movie.faceCenter(at: sample.time)
            XCTAssertEqual(sample.box.midX, expected.x, accuracy: 0.07, "at \(sample.time)")
            XCTAssertEqual(sample.box.midY, expected.y, accuracy: 0.07, "at \(sample.time)")
        }
        XCTAssertEqual(progress.last, 1, "Progress ends at done.")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double? { lock.withLock { values.last } }
}
