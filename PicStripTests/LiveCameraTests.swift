import CoreVideo
import XCTest
@testable import PicStrip

// MARK: - AnalysisThrottle

final class AnalysisThrottleTests: XCTestCase {

    func testOneFrameAtATime_andNoMoreOftenThanTheInterval() {
        var throttle = AnalysisThrottle(minimumInterval: 0.25)

        XCTAssertTrue(throttle.begin(at: 10.0), "The first frame is analysed.")
        XCTAssertFalse(throttle.begin(at: 10.5), "A frame is still being analysed.")

        throttle.end()
        XCTAssertFalse(throttle.begin(at: 10.2), "Too soon after the last analysis started.")
        XCTAssertTrue(throttle.begin(at: 10.25))

        throttle.end()
        XCTAssertTrue(throttle.begin(at: 11.0))
    }
}

// MARK: - LiveAnalysisPacing

final class LiveAnalysisPacingTests: XCTestCase {

    func testACoolFastPhoneUsesTheBaseInterval() {
        XCTAssertEqual(LiveAnalysisPacing.interval(thermalState: .nominal, lastPassDuration: 0.1), 0.35)
    }

    func testAWarmPhoneLooksLessOften() {
        XCTAssertEqual(LiveAnalysisPacing.interval(thermalState: .fair, lastPassDuration: 0.1), 0.6)
    }

    /// A pass slower than the interval must not be followed straight away by the next.
    func testASlowDeviceRestsBetweenPasses() {
        XCTAssertEqual(LiveAnalysisPacing.interval(thermalState: .nominal, lastPassDuration: 0.5), 0.75, accuracy: 0.0001)
    }

    func testAnalysisPausesOnlyWhenHot() {
        XCTAssertFalse(LiveAnalysisPacing.isTooHot(.nominal))
        XCTAssertFalse(LiveAnalysisPacing.isTooHot(.fair))
        XCTAssertTrue(LiveAnalysisPacing.isTooHot(.serious))
        XCTAssertTrue(LiveAnalysisPacing.isTooHot(.critical))
    }

    /// Held still, the viewfinder re-reads the same picture less often…
    func testAStillPictureIsLookedAtLessOften() {
        XCTAssertEqual(LiveAnalysisPacing.interval(0.35, movedSinceLastPass: 0.005), LiveAnalysisPacing.settledInterval)
        XCTAssertEqual(LiveAnalysisPacing.interval(2.0, movedSinceLastPass: 0), 2.0)
    }

    /// …and looks again at the full rate once it moves, or before its first pass.
    func testAMovedPictureIsLookedAtAtTheFullRate() {
        XCTAssertEqual(LiveAnalysisPacing.interval(0.35, movedSinceLastPass: 0.05), 0.35)
        XCTAssertEqual(LiveAnalysisPacing.interval(0.35, movedSinceLastPass: nil), 0.35)
    }
}

// MARK: - LiveOverlayGeometry

final class LiveOverlayGeometryTests: XCTestCase {

    func testPortraitVideoIsLetterboxedInATallerView() {
        let rect = LiveOverlayGeometry.videoRect(videoSize: CGSize(width: 1080, height: 1440), in: CGSize(width: 300, height: 600))
        XCTAssertEqual(rect, CGRect(x: 0, y: 100, width: 300, height: 400))
    }

    func testVideoIsPillarboxedInAWiderView() {
        let rect = LiveOverlayGeometry.videoRect(videoSize: CGSize(width: 1080, height: 1440), in: CGSize(width: 600, height: 400))
        XCTAssertEqual(rect, CGRect(x: 150, y: 0, width: 300, height: 400))
    }

    func testNoVideoYet_meansNoRect() {
        XCTAssertEqual(LiveOverlayGeometry.videoRect(videoSize: .zero, in: CGSize(width: 300, height: 600)), .zero)
    }

    /// A box must land on the letterboxed video, not on the view's black bars.
    func testBoxIsPlacedInsideTheVideoRect() {
        let video = CGRect(x: 0, y: 100, width: 300, height: 400)
        let rect = LiveOverlayGeometry.rect(for: CGRect(x: 0.5, y: 0.25, width: 0.2, height: 0.1), in: video)
        XCTAssertEqual(rect, CGRect(x: 150, y: 200, width: 60, height: 40))
    }
}

// MARK: - LiveDetectionTracker

final class LiveDetectionTrackerTests: XCTestCase {

    private let email = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.05)

    func testAFindingKeepsItsIdentityAsItMoves() throws {
        var tracker = LiveDetectionTracker(smoothing: 1)
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.9)])
        let id = try XCTUnwrap(tracker.tracks.first?.id)

        let moved = email.offsetBy(dx: 0.02, dy: 0.01)
        tracker.update(with: [LiveDetection(type: .email, boundingBox: moved, score: 0.9)])

        XCTAssertEqual(tracker.tracks.map(\.id), [id], "The same email, a little further along, is the same finding.")
        XCTAssertEqual(tracker.tracks.first?.box, moved)
    }

    func testANewPositionIsEasedInto() throws {
        var tracker = LiveDetectionTracker(smoothing: 0.5)
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.9)])
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email.offsetBy(dx: 0.02, dy: 0), score: 0.9)])

        let box = try XCTUnwrap(tracker.tracks.first?.box)
        XCTAssertEqual(box.minX, email.minX + 0.01, accuracy: 0.0001)
    }

    /// OCR misses a line now and then; the box should not blink out for it.
    func testAMissedPassFadesAFindingInsteadOfDroppingIt() {
        var tracker = LiveDetectionTracker(maximumMissedPasses: 2)
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.9)])

        tracker.update(with: [])
        XCTAssertEqual(tracker.tracks.map(\.missedPasses), [1])
        tracker.update(with: [])
        XCTAssertEqual(tracker.tracks.map(\.missedPasses), [2])
        tracker.update(with: [])
        XCTAssertTrue(tracker.tracks.isEmpty, "Gone after more than two passes without it.")
    }

    func testFindingItAgainRevivesIt() throws {
        var tracker = LiveDetectionTracker()
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.9)])
        let id = try XCTUnwrap(tracker.tracks.first?.id)
        tracker.update(with: [])
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.9)])

        XCTAssertEqual(tracker.tracks.map(\.id), [id])
        XCTAssertEqual(tracker.tracks.map(\.missedPasses), [0])
    }

    func testDifferentKindsInTheSamePlaceAreDifferentFindings() {
        var tracker = LiveDetectionTracker()
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.9)])
        tracker.update(with: [LiveDetection(type: .link, boundingBox: email, score: 0.9)])

        XCTAssertEqual(tracker.tracks.map(\.type), [.email, .link])
        XCTAssertEqual(tracker.tracks.map(\.missedPasses), [1, 0])
    }

    /// Two phone numbers on consecutive lines must not swap identities.
    func testEachDetectionClaimsItsBestMatch() throws {
        let first = CGRect(x: 0.1, y: 0.30, width: 0.3, height: 0.04)
        let second = CGRect(x: 0.1, y: 0.36, width: 0.3, height: 0.04)
        var tracker = LiveDetectionTracker(smoothing: 1)
        tracker.update(with: [
            LiveDetection(type: .phoneNumber, boundingBox: first, score: 0.9),
            LiveDetection(type: .phoneNumber, boundingBox: second, score: 0.9)
        ])
        let ids = tracker.tracks.map(\.id)

        tracker.update(with: [
            LiveDetection(type: .phoneNumber, boundingBox: second.offsetBy(dx: 0, dy: 0.005), score: 0.9),
            LiveDetection(type: .phoneNumber, boundingBox: first.offsetBy(dx: 0, dy: 0.005), score: 0.9)
        ])

        let byID = Dictionary(uniqueKeysWithValues: tracker.tracks.map { ($0.id, $0.box) })
        XCTAssertEqual(try XCTUnwrap(byID[ids[0]]).minY, first.minY + 0.005, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(byID[ids[1]]).minY, second.minY + 0.005, accuracy: 0.0001)
    }

    /// A line read in part, then in full, is still the same finding.
    func testALongerReadingOfTheSameTextMatches() {
        let partial = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.05)
        XCTAssertGreaterThan(LiveDetectionTracker.matchScore(partial, email), 0)
        XCTAssertEqual(LiveDetectionTracker.matchScore(email, email.offsetBy(dx: 0, dy: 0.2)), 0)
    }

    /// A finding's match strength follows the passes that see it, smoothed.
    func testTheScoreIsSmoothedAcrossPasses() throws {
        var tracker = LiveDetectionTracker(smoothing: 0.5)
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.9)])
        tracker.update(with: [LiveDetection(type: .email, boundingBox: email, score: 0.5)])

        let track = try XCTUnwrap(tracker.tracks.first)
        XCTAssertEqual(track.score, 0.7, accuracy: 0.0001)
        XCTAssertEqual(track.confidence, .medium)
    }

    /// A score hovering on a band boundary must not flip the label every pass.
    func testTheBandChangesOnlyOnceClearlyPastABoundary() {
        XCTAssertEqual(LiveDetectionTracker.confidence(for: 0.79, showing: .high), .high, "Just under the line: still strong.")
        XCTAssertEqual(LiveDetectionTracker.confidence(for: 0.76, showing: .high), .medium)
        XCTAssertEqual(LiveDetectionTracker.confidence(for: 0.81, showing: .medium), .medium, "Just over the line: still possible.")
        XCTAssertEqual(LiveDetectionTracker.confidence(for: 0.84, showing: .medium), .high)
        XCTAssertEqual(LiveDetectionTracker.confidence(for: 0.95, showing: .low), .high, "A jump across two bands is not held back.")
        XCTAssertEqual(LiveDetectionTracker.confidence(for: 0.6, showing: .medium), .medium)
    }

    func testANewFindingShowsItsOwnBand() {
        var tracker = LiveDetectionTracker()
        tracker.update(with: [LiveDetection(type: .link, boundingBox: email, score: 0.45)])
        XCTAssertEqual(tracker.tracks.first?.confidence, .low)
    }

    func testRemoveAllForgetsEverything() {
        var tracker = LiveDetectionTracker()
        tracker.update(with: [LiveDetection(type: .face, boundingBox: email, score: 0.9)])
        tracker.removeAll()
        XCTAssertTrue(tracker.tracks.isEmpty)
    }
}

// MARK: - LiveMotion

final class LiveMotionTests: XCTestCase {

    func testShiftsAccumulateIntoTheOffset() {
        var motion = LiveMotion()
        motion.add(CGVector(dx: 0.01, dy: 0), at: 1.0)
        motion.add(CGVector(dx: 0.02, dy: -0.01), at: 1.1)

        XCTAssertEqual(motion.offset.dx, 0.03, accuracy: 0.0001)
        XCTAssertEqual(motion.offset.dy, -0.01, accuracy: 0.0001)
    }

    func testSpeedIsFrameLengthsPerSecond() {
        var motion = LiveMotion()
        motion.add(.zero, at: 1.0)
        for step in 1...20 {
            motion.add(CGVector(dx: 0.1, dy: 0), at: 1.0 + Double(step) * 0.1)
        }
        XCTAssertEqual(motion.speed, 1.0, accuracy: 0.01)
    }

    func testRestartKeepsTheOffsetButForgetsTheSpeed() {
        var motion = LiveMotion()
        motion.add(.zero, at: 1.0)
        motion.add(CGVector(dx: 0.2, dy: 0), at: 1.1)
        motion.restart()

        XCTAssertEqual(motion.speed, 0)
        XCTAssertEqual(motion.offset.dx, 0.2, accuracy: 0.0001)
    }
}

// MARK: - LiveLabelLayout

final class LiveLabelLayoutTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let labelSize = CGSize(width: 100, height: 20)

    func testALabelGoesAboveItsBox() {
        let box = CGRect(x: 50, y: 300, width: 200, height: 30)
        let placements = LiveLabelLayout.place([.init(id: 1, box: box, labelSize: labelSize)], in: bounds)
        XCTAssertEqual(placements[1], .label(CGRect(x: 50, y: 276, width: 100, height: 20)))
    }

    func testALabelGoesBelowABoxAtTheTopEdge() {
        let box = CGRect(x: 50, y: 5, width: 200, height: 30)
        let placements = LiveLabelLayout.place([.init(id: 1, box: box, labelSize: labelSize)], in: bounds)
        XCTAssertEqual(placements[1], .label(CGRect(x: 50, y: 39, width: 100, height: 20)))
    }

    func testALabelIsPulledInsideTheTrailingEdge() {
        let box = CGRect(x: 360, y: 300, width: 30, height: 30)
        let placements = LiveLabelLayout.place([.init(id: 1, box: box, labelSize: labelSize)], in: bounds)
        XCTAssertEqual(placements[1], .label(CGRect(x: 300, y: 276, width: 100, height: 20)))
    }

    /// Two findings on consecutive lines: the second label would cover the first
    /// box, so it goes below its own box instead.
    func testALabelNeverCoversAnotherFinding() {
        let upper = CGRect(x: 50, y: 300, width: 200, height: 20)
        let lower = CGRect(x: 50, y: 330, width: 200, height: 20)
        let placements = LiveLabelLayout.place([
            .init(id: 1, box: upper, labelSize: labelSize),
            .init(id: 2, box: lower, labelSize: labelSize)
        ], in: bounds)

        XCTAssertEqual(placements[1], .label(CGRect(x: 50, y: 276, width: 100, height: 20)))
        XCTAssertEqual(placements[2], .label(CGRect(x: 50, y: 354, width: 100, height: 20)))
    }

    /// Above covers the first box and below the third, but the line has room after the text.
    func testASqueezedLabelGoesBesideItsBox() {
        let boxes = [300, 322, 344].map { CGRect(x: 50, y: CGFloat($0), width: 200, height: 20) }
        let placements = LiveLabelLayout.place(
            boxes.enumerated().map { .init(id: $0.offset, box: $0.element, labelSize: labelSize) },
            in: bounds
        )
        XCTAssertEqual(placements[1], .label(CGRect(x: 254, y: 322, width: 100, height: 20)))
    }

    func testWithNoRoomLeftAFindingGetsABadge() {
        let boxes = [300, 322, 344].map { CGRect(x: 5, y: CGFloat($0), width: 390, height: 20) }
        let placements = LiveLabelLayout.place(
            boxes.enumerated().map { .init(id: $0.offset, box: $0.element, labelSize: labelSize) },
            in: bounds
        )
        XCTAssertEqual(placements[1], .badge, "Above and below cover the other boxes; the sides are off the screen.")
    }

    /// Grazing the next box's padding is not covering it.
    func testTouchingABoxEdgeIsAllowed() {
        let upper = CGRect(x: 50, y: 300, width: 100, height: 20)
        let lower = CGRect(x: 50, y: 320, width: 200, height: 20)
        let placements = LiveLabelLayout.place([
            .init(id: 1, box: upper, labelSize: CGSize(width: 100, height: 22)),
            .init(id: 2, box: lower, labelSize: labelSize)
        ], in: CGRect(x: 0, y: 290, width: 400, height: 60))

        XCTAssertEqual(placements[1], .label(CGRect(x: 154, y: 299, width: 100, height: 22)),
                       "Beside the upper box, a point into the lower box's padding.")
    }

    /// Where there is a choice, a label goes where it hides no text.
    func testALabelPrefersASpotThatLeavesTextReadable() {
        let box = CGRect(x: 50, y: 300, width: 100, height: 20)
        let lines = [CGRect(x: 0, y: 270, width: 400, height: 20), CGRect(x: 0, y: 330, width: 400, height: 20)]
        let placements = LiveLabelLayout.place([.init(id: 1, box: box, labelSize: labelSize)], in: bounds, textLines: lines)
        XCTAssertEqual(placements[1], .label(CGRect(x: 154, y: 300, width: 100, height: 20)))
    }

    func testLabelsStayOffTheControls() {
        let box = CGRect(x: 50, y: 300, width: 100, height: 20)
        let controls = CGRect(x: 0, y: 260, width: 400, height: 30)
        let placements = LiveLabelLayout.place([.init(id: 1, box: box, labelSize: labelSize)], in: bounds, avoiding: [controls])
        XCTAssertEqual(placements[1], .label(CGRect(x: 50, y: 324, width: 100, height: 20)))
    }

    func testOnlyTheFirstFewFindingsAreLabelled() {
        let items = (0..<10).map { index in
            LiveLabelLayout.Item(id: index, box: CGRect(x: 10, y: CGFloat(index) * 80 + 30, width: 50, height: 10), labelSize: labelSize)
        }
        let placements = LiveLabelLayout.place(items, in: bounds)
        XCTAssertEqual(placements[LiveLabelLayout.maximumLabels], .badge)
    }
}

// MARK: - LiveScanSummary

final class LiveScanSummaryTests: XCTestCase {

    func testKindsAreListedByRiskThenCount() {
        let box = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let summary = LiveScanSummary(tracks: [
            LiveTrack(id: 0, type: .email, box: box, score: 0.9),
            LiveTrack(id: 1, type: .phoneNumber, box: box, score: 0.9),
            LiveTrack(id: 2, type: .phoneNumber, box: box, score: 0.9),
            LiveTrack(id: 3, type: .creditCard, box: box, score: 0.9),
            LiveTrack(id: 4, type: .link, box: box, score: 0.9)
        ])

        XCTAssertEqual(summary.types, [.creditCard, .phoneNumber, .email, .link])
        XCTAssertEqual(summary.entries.map(\.count), [1, 2, 1, 1])
        XCTAssertEqual(summary.highestRisk, .critical)
    }

    func testNothingInView() {
        let summary = LiveScanSummary(tracks: [])
        XCTAssertTrue(summary.isEmpty)
        XCTAssertNil(summary.highestRisk)
    }
}

// MARK: - Per-frame scan

final class LiveScanTests: XCTestCase {

    private func fixtureImage() throws -> (data: Data, image: CGImage) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let data = try Data(contentsOf: url)
        return (data, try XCTUnwrap(UIImage(data: data)?.cgImage))
    }

    /// The viewfinder's fast pass must find the same email the full scan finds
    /// in the fixture, say what it is, and place it in the same top-left
    /// normalised space.
    func testLiveScan_findsAndNamesThePIIInAFrame() async throws {
        let (data, image) = try fixtureImage()
        nonisolated(unsafe) let frame = try XCTUnwrap(LiveCameraFixture.pixelBuffer(from: image))

        let scan = await PIIScanner.liveScan(in: frame)
        let full = try await PIIScanner().scanImage(data: data)

        XCTAssertFalse(scan.detections.isEmpty, "The fixture's email and phone number should be found.")
        let unit = CGRect(x: -0.01, y: -0.01, width: 1.02, height: 1.02)
        for box in scan.detections.map(\.boundingBox) + scan.textLines {
            XCTAssertTrue(unit.contains(box), "\(box) is not normalised.")
        }
        let email = try XCTUnwrap(full.first { $0.type == .email }?.instances.first?.boundingBox)
        XCTAssertTrue(
            scan.detections.contains { $0.type == .email && abs($0.boundingBox.midY - email.midY) < 0.03 && $0.boundingBox.intersects(email) },
            "The live pass should label the email where the full scan finds it (\(email)); got \(scan.detections)."
        )
        XCTAssertTrue(
            scan.textLines.contains { $0.intersects(email) },
            "The line holding the email is one of the lines read."
        )
        XCTAssertGreaterThan(scan.textLines.count, scan.detections.count, "Every line read is reported, not just the sensitive ones.")
        for detection in scan.detections {
            XCTAssertTrue((0...1).contains(detection.score), "\(detection.type) has score \(detection.score).")
        }
    }

    /// The viewfinder never shows names: they are not redacted until the user
    /// switches them on, and the live pass does not run the language model.
    func testLiveScan_reportsOnlyWhatWouldBeRedactedByDefault() async throws {
        let (_, image) = try fixtureImage()
        nonisolated(unsafe) let frame = try XCTUnwrap(LiveCameraFixture.pixelBuffer(from: image))
        let scan = await PIIScanner.liveScan(in: frame)
        XCTAssertTrue(scan.detections.allSatisfy(\.type.isRedactedByDefault))
    }
}

// MARK: - FrameRegistration

final class FrameRegistrationTests: XCTestCase {

    /// `image` moved `offset` pixels right and down, on a white page the same size.
    private func shifted(_ image: CGImage, by offset: CGPoint) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Core Graphics' origin is at the bottom: down is negative y.
        context.draw(image, in: CGRect(x: offset.x, y: -offset.y, width: CGFloat(image.width), height: CGFloat(image.height)))
        return try XCTUnwrap(context.makeImage())
    }

    /// The boxes follow the content only if the sign of the measured motion is
    /// right on both axes.
    func testRegistrationMeasuresHowFarTheContentMoved() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(data: try Data(contentsOf: url))?.cgImage)
        let offset = CGPoint(x: 40, y: 30)
        nonisolated(unsafe) let before = try XCTUnwrap(LiveCameraFixture.pixelBuffer(from: try shifted(image, by: .zero)))
        nonisolated(unsafe) let after = try XCTUnwrap(LiveCameraFixture.pixelBuffer(from: try shifted(image, by: offset)))

        let registration = FrameRegistration()
        let first = await registration.shift(to: before)
        XCTAssertNil(first, "There is nothing to compare the first frame with.")
        let measured = await registration.shift(to: after)
        let shift = try XCTUnwrap(measured, "Vision could not register the frames.")

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        XCTAssertEqual(shift.dx, offset.x / width, accuracy: 4 / width, "Content moved right: dx is positive.")
        XCTAssertEqual(shift.dy, offset.y / height, accuracy: 4 / height, "Content moved down: dy is positive.")
    }

    func testARestartForgetsThePreviousFrame() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(data: try Data(contentsOf: url))?.cgImage)
        nonisolated(unsafe) let frame = try XCTUnwrap(LiveCameraFixture.pixelBuffer(from: image))

        let registration = FrameRegistration()
        _ = await registration.shift(to: frame)
        let restarted = await registration.shift(to: frame, restart: true)
        XCTAssertNil(restarted)
    }
}
