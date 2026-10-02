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

// MARK: - Following a drawn box

final class VideoObjectFollowerTests: XCTestCase {

    func testADrawnBoxIsFollowedForwardsAndBack() async throws {
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
