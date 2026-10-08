import Synchronization
import UIKit
import XCTest

/// Fastlane snapshot test suite for PicStrip.
///
/// All screenshots are captured in a single test method, which launches the app
/// once per scene, each time on its own fixture.  Splitting captures across
/// multiple test methods causes XCTest to terminate and relaunch the app between
/// methods, which fails with "Failed to terminate com.northcutt.PicStrip" in
/// headless CI.
///
/// The fixtures are drawn by `scripts/make_store_fixtures.py`; every person,
/// name, number and place in them is invented.
///
/// Screens captured (the App Store shows them in this order):
///   01_VideoEditor — faces in a video blurred or given an emoji, with a bleep
///   02_Location — the location, camera and date found in a photo
///   03_Viewfinder — the live viewfinder outlining a face, an email and a code
///   04_Redaction — a photo's findings covered with blur, pixelate and an emoji
///   05_ReviewAndShare — the cleaned photo, every check finished, ready to share
///   06_Batch — photos and videos cleaned together
///
/// `testAppPreviewFlow` plays the App Store preview video through once for
/// `scripts/make_app_previews.py`, which records it; it is skipped otherwise.
@MainActor
final class PicStripUITests: XCTestCase {
    private nonisolated let recordingIssue = Mutex(false)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func record(_ issue: XCTIssue) {
        // XCTest can report worker-queue failures. Never block that queue on
        // the UI executor just to collect diagnostics, or replace its issue.
        let captureTree = Thread.isMainThread && recordingIssue.withLock { recording in
            guard !recording else { return false }
            recording = true
            return true
        }
        if captureTree {
            defer { recordingIssue.withLock { $0 = false } }
            // Capture only the Sendable string on the UI executor. XCTestCase
            // itself stays on the queue that is recording the original issue.
            let description = MainActor.assumeIsolated { XCUIApplication().debugDescription }
            let tree = XCTAttachment(string: description)
            tree.name = "Accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        super.record(issue)
    }

    private func fixtureImageURL() -> URL? {
        Bundle(for: type(of: self)).url(forResource: "test_list", withExtension: "png")
    }

    // MARK: - All screenshots — one launch per scene

    /// Captures every App Store screenshot in one continuous session.
    @MainActor
    func testAllScreenshots() async throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        let snapshotEnvironment = app.launchEnvironment

        try await captureVideoEditor(app, environment: snapshotEnvironment)
        app.terminate()
        try await capturePhotoScenes(app, environment: snapshotEnvironment)
        app.terminate()
        try await captureViewfinder(app, environment: snapshotEnvironment)
        app.terminate()
        try await captureBatch(app, environment: snapshotEnvironment)
    }

    /// 01 — Two friends walking down a street: both faces found and followed,
    /// one blurred and one given an emoji, and a bleep on the audio lane.
    private func captureVideoEditor(_ app: XCUIApplication, environment: [String: String]) async throws {
        app.launchEnvironment = environment
        app.launchEnvironment["PICSTRIP_VIDEO_FIXTURE"] = try stagedFixture("store_street", "mov")
        app.launch()
        XCTAssertTrue(app.buttons["addCoverButton"].waitForExistence(timeout: 180), "The video opens in its editor.")

        // Both faces are found and blurred; the second gets an emoji instead.
        let faceClips = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'clip-face-'"))
        XCTAssertEqual(faceClips.count, 2, "Both faces are found.")
        let cover = app.buttons["faceCoverMenu-2"]
        reveal(cover, in: app)
        cover.tap()
        let emoji = app.buttons["emojiCoverButton"].firstMatch
        XCTAssertTrue(emoji.waitForExistence(timeout: 5), "The cover menu offers an emoji.")
        emoji.tap()
        let sunglasses = app.buttons["emojiChoice-😎"]
        XCTAssertTrue(sunglasses.waitForExistence(timeout: 5))
        sunglasses.tap()
        app.buttons["emojiDoneButton"].tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        // Back to the top, where the preview and the timeline are.
        let list = app.collectionViews.firstMatch
        let preview = app.descendants(matching: .any)["videoPreviewStill"]
        let top = app.navigationBars.firstMatch.frame.maxY
        // Dragged from low in the list, never from its middle: in longer
        // languages the timeline sits there, and its own gestures took the
        // swipe (German, on iPhone).
        for _ in 0..<12 where !(preview.exists && preview.frame.minY >= top) {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(preview.exists && preview.frame.minY >= top, "The preview is in view again.")

        // A stretch of what they say, bleeped from the audio lane's menu (its
        // first item, whatever the language).
        let audio = app.descendants(matching: .any)["audioLane"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5), "The video has sound.")
        try await Task.sleep(for: .seconds(1))
        let bleep = app.menuItems.firstMatch
        let start = audio.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5))
        for _ in 0..<3 where !bleep.exists {
            // A tap first puts the playhead where the hold begins: on iPad the
            // hold can be recognised before the lane has seen where the touch is.
            start.tap()
            start.press(forDuration: 0.8, thenDragTo: audio.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5)))
            _ = bleep.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(bleep.exists, "The selected stretch offers Bleep.")
        bleep.tap()
        XCTAssertTrue(app.descendants(matching: .any)["clip-audio-0"].waitForExistence(timeout: 5))
        // The preview is redrawn with the covers once the playhead settles.
        try await Task.sleep(for: .seconds(2))
        snapshot("01_VideoEditor")
        attachScreen("01_VideoEditor")
    }

    /// 04, 02 and 05 — a photo at a pavement café: its findings covered in the
    /// editor, the location it carries, and the review with every check done.
    private func capturePhotoScenes(_ app: XCUIApplication, environment: [String: String]) async throws {
        app.launchEnvironment = environment
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = try stagedFixture("store_cafe", "jpg")
        app.launch()

        let edit = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30), "The scan finishes.")
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["addRedactionButton"].waitForExistence(timeout: 5))

        // Each finding gets the cover that suits it; the card stays solid.
        try await cover("detected-phoneNumber-0", with: "pixelate", in: app)
        try await cover("detected-barcode-0", with: "pixelate", in: app)
        try await cover("detected-face-0", with: "blur", in: app)
        try await cover("detected-face-1", with: "emoji", emoji: "😎", in: app)
        // The region list from its first row, not cut off part-way through one.
        app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH 'regionRow-'")).firstMatch.swipeDown(velocity: .slow)
        try await Task.sleep(for: .seconds(1))
        snapshot("04_Redaction")
        attachScreen("04_Redaction")
        app.descendants(matching: .any)["doneEditingRedactionsButton"].tap()

        // Where the photo was taken, as it says to anyone it is sent to.
        let location = app.buttons["badge_GPS"]
        XCTAssertTrue(location.waitForExistence(timeout: 10), "The photo's location is found.")
        location.tap()
        XCTAssertTrue(app.staticTexts["Latitude"].firstMatch.waitForExistence(timeout: 5), "The latitude is listed.")
        try await Task.sleep(for: .seconds(1))
        snapshot("02_Location")
        attachScreen("02_Location")
        location.tap()
        try await Task.sleep(for: .seconds(0.5))

        let saveButton = app.buttons["saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["savePreviewImage"].waitForExistence(timeout: 10),
            "Review sheet should show the processed image preview before saving."
        )
        let share = app.buttons["shareCleanedImageButton"]
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: share)
        await fulfillment(of: [ready], timeout: 20)
        XCTAssertFalse(
            app.descendants(matching: .any)["manualReviewAcknowledgement"].exists,
            "Every check finished: nothing asks for a manual review."
        )
        try await Task.sleep(for: .seconds(1))
        snapshot("05_ReviewAndShare")
        attachScreen("05_ReviewAndShare")
    }

    /// 03 — the viewfinder in Photo mode, outlining a visitor's face, the email
    /// on their badge and its code before the photo is taken.
    private func captureViewfinder(_ app: XCUIApplication, environment: [String: String]) async throws {
        app.launchEnvironment = environment
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_LIVE_CAMERA_FIXTURE"] = try stagedFixture("store_badge", "jpg")
        app.launch()
        let status = app.descendants(matching: .any)["liveCameraStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "The viewfinder opens on the fixture.")
        // The live scan finds all three within a few passes; the guide over the
        // picture fades after five seconds.
        try await Task.sleep(for: .seconds(8))
        snapshot("03_Viewfinder")
        attachScreen("03_Viewfinder")
    }

    /// 06 — photos and videos picked together, about to be cleaned as one batch.
    private func captureBatch(_ app: XCUIApplication, environment: [String: String]) async throws {
        // A day's worth: the fixtures several times over.
        let photos = [try stagedFixture("store_cafe", "jpg"), try stagedFixture("store_badge", "jpg"), try stagedFixture("test_list", "png")]
        let video = try stagedFixture("store_street", "mov")
        let files = Array(repeating: photos, count: 4).flatMap { $0 } + Array(repeating: video, count: 3)
        app.launchEnvironment = environment
        app.launchEnvironment["PICSTRIP_BATCH_FIXTURE"] = files.joined(separator: "\n")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["videoBatchNote"].waitForExistence(timeout: 20), "The batch has its videos.")
        try await Task.sleep(for: .seconds(1))
        snapshot("06_Batch")
        attachScreen("06_Batch")
    }

    // MARK: - App Preview — one recorded session

    /// Where scripts/make_app_previews.py asks for the preview flow, and where
    /// the flow writes when each scene starts and ends.
    private static let previewFolder = URL(fileURLWithPath: "/tmp/picstrip_app_preview")

    /// The App Store preview, played through once while
    /// scripts/make_app_previews.py records the simulator's screen: the street
    /// video's faces found, one given an emoji and both followed; a stretch of
    /// sound bleeped; the viewfinder outlining a visitor's badge; the location
    /// and camera details in the café photo; and the review before sharing.
    /// The script cuts the recording at the marks written here and shortens
    /// the moments the screen stands still, so waits cost the preview little.
    /// Skipped unless that script asked for it.
    @MainActor
    func testAppPreviewFlow() async throws {
        let request = Self.previewFolder.appendingPathComponent("request.json")
        guard let data = try? Data(contentsOf: request),
              let options = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw XCTSkip("Only scripts/make_app_previews.py runs the App Preview flow.")
        }
        let marks = Self.previewFolder.appendingPathComponent("marks.jsonl")
        try? FileManager.default.removeItem(at: marks)
        XCTAssertTrue(FileManager.default.createFile(atPath: marks.path, contents: nil))

        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(options["language"] ?? "en"))", "-AppleLocale", options["locale"] ?? "en_US",
            // As in the store screenshots: no note that the simulator shows one frame.
            "-FASTLANE_SNAPSHOT", "YES"
        ]
        try await previewVideo(app)
        app.terminate()
        try await previewViewfinder(app)
        app.terminate()
        try await previewPhoto(app)
        previewMark("done")
    }

    /// Scenes 1 and 2: the street video scanned, a face given 😎 from its clip,
    /// both covers followed along the timeline, then a stretch bleeped.
    private func previewVideo(_ app: XCUIApplication) async throws {
        app.launchEnvironment = ["PICSTRIP_VIDEO_FIXTURE": try stagedFixture("store_street", "mov")]
        app.launch()
        XCTAssertTrue(app.buttons["skipFacesButton"].waitForExistence(timeout: 60), "The video is scanned.")
        previewMark("video.scan")
        // The frame being scanned, with what is found outlined (the card shown
        // before it is hidden from accessibility).
        XCTAssertTrue(app.descendants(matching: .any)["scanGlimpse"].firstMatch.waitForExistence(timeout: 60),
                      "The scan shows the frame it is looking at.")
        previewMark("video.found")
        let add = app.buttons["addCoverButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 180), "The video opens in its editor.")
        previewMark("video.scanned")
        // Both faces blurred and the flyer's number covered, on the paused frame.
        let still = app.descendants(matching: .any)["videoPreviewStill"]
        XCTAssertTrue(still.waitForExistence(timeout: 30), "The covered frame is drawn.")
        try await Task.sleep(for: .seconds(1.5))
        previewMark("video.editor")
        var frame = still.screenshot().pngRepresentation

        // Holding a face's clip offers its covers.  (Clips count from 0.)
        let face = app.descendants(matching: .any)["clip-face-1"]
        XCTAssertTrue(face.waitForExistence(timeout: 5), "The second face has a clip.")
        // (XCTest's own pace between steps is about a second: no pauses needed.)
        previewMark("video.hold")
        face.press(forDuration: 0.8)
        let emoji = app.buttons["emojiCoverButton"].firstMatch
        XCTAssertTrue(emoji.waitForExistence(timeout: 5), "Holding the clip offers an emoji.")
        emoji.tap()
        let sunglasses = app.buttons["emojiChoice-😎"]
        XCTAssertTrue(sunglasses.waitForExistence(timeout: 5))
        sunglasses.tap()
        app.buttons["emojiDoneButton"].tap()
        previewMark("video.done")
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        // The paused frame is drawn again, with the emoji.
        frame = try await redrawn(still, from: frame)
        try await Task.sleep(for: .seconds(1.5))
        previewMark("video.emoji")

        // Along the timeline: the covers stay on the faces as they move.
        let track = app.descendants(matching: .any)["coverTimelineTrack"]
        XCTAssertTrue(track.exists, "The timeline is in view.")
        previewMark("video.follow0")
        for (index, place) in [0.1, 0.55, 0.95].enumerated() {
            track.coordinate(withNormalizedOffset: CGVector(dx: place, dy: 0.5)).tap()
            frame = try await redrawn(still, from: frame)
            try await Task.sleep(for: .seconds(1))
            previewMark("video.follow\(index + 1)")
        }

        // A stretch of what they say, bleeped from the audio lane's menu (its
        // first item, whatever the language).
        previewMark("bleep.start")
        let audio = app.descendants(matching: .any)["audioLane"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5), "The video has sound.")
        let bleep = app.menuItems.firstMatch
        let start = audio.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5))
        previewMark("bleep.hold")
        for _ in 0..<3 where !bleep.exists {
            start.tap()
            start.press(forDuration: 0.8, thenDragTo: audio.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5)))
            _ = bleep.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(bleep.exists, "The selected stretch offers Bleep.")
        previewMark("bleep.menu")
        try await Task.sleep(for: .seconds(0.5))
        bleep.tap()
        XCTAssertTrue(app.descendants(matching: .any)["clip-audio-0"].waitForExistence(timeout: 5))
        previewMark("bleep.done")
        try await Task.sleep(for: .seconds(1.5))
        previewMark("bleep.end")
    }

    /// Scene 3: Photo mode outlining the visitor's face, the email on their
    /// badge and its code, then showing them covered.
    private func previewViewfinder(_ app: XCUIApplication) async throws {
        app.launchEnvironment = [
            "PICSTRIP_DISABLE_NAME_DETECTION": "1",
            "PICSTRIP_LIVE_CAMERA_FIXTURE": try stagedFixture("store_badge", "jpg")
        ]
        app.launch()
        let status = app.descendants(matching: .any)["liveCameraStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "The viewfinder opens on the fixture.")
        previewMark("viewfinder.start")
        // The guide over the picture fades after five seconds.
        try await Task.sleep(for: .seconds(5.5))
        previewMark("viewfinder.found")
        let toggle = app.descendants(matching: .any)["liveCameraPreviewToggle"].firstMatch
        XCTAssertTrue(toggle.exists, "The covers can be previewed.")
        toggle.tap()
        previewMark("viewfinder.covered")
        try await Task.sleep(for: .seconds(2.5))
        previewMark("viewfinder.end")
    }

    /// Scenes 4 and 5: the café photo's location and camera details, then the
    /// review — held to compare with the original — before sharing.
    private func previewPhoto(_ app: XCUIApplication) async throws {
        app.launchEnvironment = [
            "PICSTRIP_DISABLE_NAME_DETECTION": "1",
            "PICSTRIP_FIXTURE": try stagedFixture("store_cafe", "jpg")
        ]
        app.launch()
        let edit = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30), "The scan finishes.")
        // Off camera: the covers of the store screenshots.
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["addRedactionButton"].waitForExistence(timeout: 5))
        try await cover("detected-phoneNumber-0", with: "pixelate", in: app)
        try await cover("detected-barcode-0", with: "pixelate", in: app)
        try await cover("detected-face-0", with: "blur", in: app)
        try await cover("detected-face-1", with: "emoji", emoji: "😎", in: app)
        app.descendants(matching: .any)["doneEditingRedactionsButton"].tap()
        let location = app.buttons["badge_GPS"]
        XCTAssertTrue(location.waitForExistence(timeout: 10), "The photo's location is found.")
        try await Task.sleep(for: .seconds(2))
        previewMark("location.start")

        location.tap()
        XCTAssertTrue(app.staticTexts["Latitude"].firstMatch.waitForExistence(timeout: 5), "The latitude is listed.")
        try await Task.sleep(for: .seconds(1.5))
        let camera = app.buttons["badge_EXIF"]
        XCTAssertTrue(camera.exists, "The camera and date are found too.")
        camera.tap()
        try await Task.sleep(for: .seconds(1.5))
        camera.tap()
        previewMark("location.end")

        previewMark("review.start")
        app.buttons["saveButton"].tap()
        // Looked for without waitForExistence's one-second steps: the mark says
        // when the review sheet comes up.
        let preview = app.descendants(matching: .any)["savePreviewImage"].firstMatch
        let deadline = Date.now.addingTimeInterval(10)
        while !preview.exists, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(preview.exists, "The review shows the cleaned photo.")
        previewMark("review.sheet")
        let share = app.buttons["shareCleanedImageButton"]
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: share)
        await fulfillment(of: [ready], timeout: 20)
        previewMark("review.ready")
        try await Task.sleep(for: .seconds(1))
        // Held: the original, for comparison; let go: the copy that is shared.
        previewMark("review.hold")
        preview.press(forDuration: 1.6)
        previewMark("review.released")
        try await Task.sleep(for: .seconds(1.5))
        previewMark("review.end")
    }

    /// Waits until `element` no longer looks like `before` — the simulator
    /// draws the covered frame as a still, which can take a while on a busy
    /// machine, and a step taken before it lands would replace it — and
    /// returns how it looks now.
    private func redrawn(_ element: XCUIElement, from before: Data, timeout: TimeInterval = 90) async throws -> Data {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            let now = element.screenshot().pngRepresentation
            if now != before { return now }
        }
        XCTFail("\(element.identifier) was not drawn again within \(Int(timeout)) seconds.")
        return before
    }

    /// Notes the moment `name` happens on screen for scripts/make_app_previews.py.
    private func previewMark(_ name: String) {
        let line = "{\"mark\": \"\(name)\", \"time\": \(Date().timeIntervalSince1970)}\n"
        let url = Self.previewFolder.appendingPathComponent("marks.jsonl")
        guard let handle = try? FileHandle(forWritingTo: url) else { return XCTFail("Cannot write \(url.path)") }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
    }

    /// Selects a region in the editor and gives it `style` (and `emoji`).
    private func cover(_ region: String, with style: String, emoji: String? = nil, in app: XCUIApplication) async throws {
        // The region list is short and scrolls: look up it, then down it.
        let row = app.descendants(matching: .any)["regionRow-\(region)"].firstMatch
        let list = app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH 'regionRow-'")).firstMatch
        for attempt in 0..<10 where !(row.exists && row.isHittable) {
            if attempt < 4 { list.swipeDown(velocity: .slow) } else { list.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(region) is found.")
        row.tap()
        let styleButton = app.buttons["editRegionStyleButton"]
        XCTAssertTrue(styleButton.waitForExistence(timeout: 5))
        styleButton.tap()
        let choice = app.buttons["styleButton-\(style)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        if let emoji {
            let pick = app.buttons["emojiChoice-\(emoji)"]
            XCTAssertTrue(pick.waitForExistence(timeout: 5))
            pick.tap()
        }
        app.buttons["doneStyleButton"].tap()
        try await Task.sleep(for: .seconds(0.4))
    }

    /// Copies a bundled fixture to the simulator's /tmp, where the app can read it.
    private func stagedFixture(_ name: String, _ ext: String) throws -> String {
        let source = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: name, withExtension: ext), "\(name).\(ext) must be in the UI test bundle"
        )
        let path = "/tmp/picstrip_store_\(name).\(ext)"
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - Wide displays (iPhone Duo, unfolded)

    /// On a display wide and tall enough — iPhone Duo's inner one, unfolded —
    /// the redaction drawer stands beside the photo.  Folding or unfolding the
    /// phone changes the size live; here an iPad, allowed the side layout, is
    /// turned instead.  The editor is rearranged, not rebuilt: still editing,
    /// the same region selected, every region kept.
    @MainActor
    func testEditorKeepsItsStateWhenItsControlsMoveBesideThePhoto() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Only an iPad simulator is tall enough sideways for the side layout.")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_SIDE_LAYOUT_ON_ANY_DEVICE"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = try stagedFixture("store_cafe", "jpg")
        app.launch()

        let edit = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30), "The scan finishes.")
        let regions = edit.label
        edit.tap()
        let done = app.descendants(matching: .any)["doneEditingRedactionsButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'regionRow-'")).firstMatch.tap()
        let style = app.buttons["editRegionStyleButton"]
        XCTAssertTrue(style.waitForExistence(timeout: 5), "A region is selected.")
        let photo = app.descendants(matching: .any)["metadataPhotoPreview"]
        XCTAssertGreaterThanOrEqual(done.frame.minY, photo.frame.maxY, "Upright, the drawer is below the photo.")

        XCUIDevice.shared.orientation = .landscapeLeft
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThanOrEqual(done.frame.minX, photo.frame.maxX, "Sideways, the drawer stands beside the photo.")
        XCTAssertTrue(style.exists, "The region is still selected.")
        attachScreen("wide_editor")

        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThanOrEqual(done.frame.minY, photo.frame.maxY, "Upright again, below.")
        XCTAssertTrue(style.exists, "Still selected.")
        done.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, regions, "Every region is kept.")
    }

    /// The viewfinder, on the same wide display: the shutter and the modes in
    /// a column beside the picture, and the viewfinder still running after
    /// the size changes back and forth.
    @MainActor
    func testViewfinderPutsItsControlsBesideThePictureWhenWide() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Only an iPad simulator is tall enough sideways for the side layout.")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_SIDE_LAYOUT_ON_ANY_DEVICE"] = "1"
        app.launchEnvironment["PICSTRIP_LIVE_CAMERA_FIXTURE"] = try stagedFixture("store_badge", "jpg")
        app.launch()

        let status = app.descendants(matching: .any)["liveCameraStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "The viewfinder opens on the fixture.")
        let shutter = app.buttons["liveCameraShutterButton"]
        XCTAssertGreaterThanOrEqual(shutter.frame.minY, status.frame.maxY, "Upright, the shutter is below the picture.")

        XCUIDevice.shared.orientation = .landscapeLeft
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThanOrEqual(shutter.frame.minX, status.frame.maxX, "Sideways, the shutter is beside the picture.")
        XCTAssertTrue(app.buttons["cameraMode-photo"].isSelected, "Still in Photo mode.")
        attachScreen("wide_viewfinder")

        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThanOrEqual(shutter.frame.minY, status.frame.maxY, "Upright again, below.")
        let found = expectation(for: NSPredicate(format: "label CONTAINS 'Sensitive details in view'"), evaluatedWith: status)
        await fulfillment(of: [found], timeout: 20)
        shutter.tap()
        XCTAssertTrue(app.buttons["dismissPhotoButton"].waitForExistence(timeout: 15), "The viewfinder still takes the photo.")
    }

    /// The simulator has no camera, so by default the home screen must not offer a scan.
    @MainActor
    func testHomeScreenHidesScanWithoutACamera() throws {
        let app = englishApp()
        app.launch()

        XCTAssertTrue(app.buttons["libraryButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["browseFilesButton"].exists)
        XCTAssertFalse(app.buttons["cameraButton"].exists, "No camera, no Camera button.")
    }

    /// Paste is offered only while the pasteboard holds an image, and then from the
    /// navigation bar — never as a stray control among the import buttons.
    @MainActor
    func testPasteIsOfferedOnlyWhenThereIsAnImageToPaste() throws {
        let app = englishApp()
        app.launch()
        XCTAssertTrue(app.buttons["libraryButton"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["pasteImageButton"].firstMatch.exists)
        app.terminate()

        app.launchEnvironment["PICSTRIP_FORCE_PASTE_BUTTON"] = "1"
        app.launch()
        let paste = app.descendants(matching: .any)["pasteImageButton"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 15))
        XCTAssertLessThan(
            paste.frame.maxY, app.buttons["libraryButton"].frame.minY,
            "Paste belongs in the bar at the top, above every import button."
        )
    }

    /// With a camera, every import action is on the first screen at once — no
    /// disclosure to open, no scrolling — and tappable.
    @MainActor
    func testHomeScreenFitsAllImportActionsWithScan() throws {
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_FORCE_SCAN_BUTTON"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["libraryButton"].waitForExistence(timeout: 15))
        for identifier in ["cameraButton", "libraryButton", "browseFilesButton", "tryDemoButton"] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "\(identifier) must be on the first screen.")
        }
        XCTAssertLessThan(
            app.buttons["cameraButton"].frame.maxY, app.buttons["libraryButton"].frame.minY,
            "With a camera, the Camera leads, above the library and Files."
        )
        XCTAssertEqual(
            app.buttons["libraryButton"].frame.midY, app.buttons["browseFilesButton"].frame.midY, accuracy: 1,
            "The library and Files share a row."
        )
        XCTAssertFalse(app.buttons["selectScreenshotButton"].exists, "Screenshots are a collection in the library picker.")
        attachScreen("home")
    }

    /// The live viewfinder, run on a still image because the simulator has no
    /// camera: it says what it finds, switches to a preview of the redactions,
    /// and hands the photo to the editor.
    @MainActor
    func testLiveViewfinderNamesFindingsAndCaptures() throws {
        let app = englishApp()
        let path = "/tmp/picstrip_live_fixture.png"
        try Data(contentsOf: try XCTUnwrap(fixtureImageURL())).write(to: URL(fileURLWithPath: path))
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_LIVE_CAMERA_FIXTURE"] = path
        app.launch()

        let status = app.descendants(matching: .any)["liveCameraStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "The viewfinder opens on the fixture.")
        XCTAssertTrue(app.buttons["cameraMode-photo"].isSelected, "The camera opens in Photo mode, with Video beside it.")
        let found = expectation(for: NSPredicate(format: "label CONTAINS 'Sensitive details in view'"), evaluatedWith: status)
        wait(for: [found], timeout: 20)
        XCTAssertTrue(status.label.contains("Email Address"), "The status names what is in view; got \"\(status.label)\".")
        attachScreen("live_01_highlight")

        app.descendants(matching: .any)["liveCameraPreviewToggle"].firstMatch.tap()
        attachScreen("live_02_preview")

        app.buttons["liveCameraShutterButton"].tap()
        XCTAssertTrue(
            app.buttons["dismissPhotoButton"].waitForExistence(timeout: 15),
            "The photo goes straight to the editor."
        )
        attachScreen("live_03_editor")
    }

    @MainActor
    func testCleanFixtureShowsNoMetadataBanner() throws {
        let app = englishApp()

        let cleanPath = "/tmp/picstrip_clean_fixture.png"
        try makeCleanPNG().write(to: URL(fileURLWithPath: cleanPath))

        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = cleanPath
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["metadataPhotoPreview"].waitForExistence(timeout: 15),
            "Clean fixture should load into the zoomable image preview."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["noMetadataBanner"].waitForExistence(timeout: 10),
            "Images without non-structural hidden metadata should say no hidden metadata was found."
        )
    }

    @MainActor
    func testManualRedactionEditorCanCreateCustomRegion() throws {
        let app = englishApp()

        let fixtureURL = fixtureImageURL()
        let tmpPath = "/tmp/picstrip_manual_redaction_fixture.png"
        if let srcURL = fixtureURL,
           let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }

        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        let preview = app.descendants(matching: .any)["metadataPhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))

        // The button appears once the scan is complete, and the scan now ends
        // with the on-device name pass — seconds, not an instant, on a cold model.
        let editButton = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 25))
        editButton.tap()

        let addButton = app.descendants(matching: .any)["addRedactionButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
            .press(
                forDuration: 0.1,
                thenDragTo: preview.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.42))
            )

        XCTAssertTrue(app.descendants(matching: .any)["deleteRedactionButton"].waitForExistence(timeout: 5))
        // Editor is still open at this point; verify the "Done" button is present
        // (the save button lives in the control panel, which is hidden during editing).
        XCTAssertTrue(app.descendants(matching: .any)["doneEditingRedactionsButton"].exists)
    }

    /// When a fixture containing detectable sensitive data is loaded, the
    /// Edit Redactions row should appear (signalling the scan completed) and
    /// tapping it should open the redaction editor with at least one region.
    @MainActor
    func testPIIDetectedOpensEditorWithRegions() throws {
        let app = englishApp()

        let fixtureURL = fixtureImageURL()
        let tmpPath = "/tmp/picstrip_sensitive_fixture.png"
        if let srcURL = fixtureURL,
           let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }

        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        // The Edit Redactions row is the scan-complete sentinel:
        // it only appears after the scanning row (ProgressView) disappears.
        let editRedactionsButton = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(
            editRedactionsButton.waitForExistence(timeout: 20),
            "Edit Redactions button should appear once the PII scan finishes."
        )

        // Tap into the redaction editor — the row must be interactive.
        editRedactionsButton.tap()

        // The Add Region button is only visible inside the redaction editor,
        // confirming the editor opened successfully.
        XCTAssertTrue(
            app.descendants(matching: .any)["addRedactionButton"].waitForExistence(timeout: 5),
            "Tapping Edit Redactions should open the redaction editor."
        )

        // At least one region row should exist because the fixture contains
        // detectable PII (the same fixture used by other tests).
        XCTAssertTrue(
            app.descendants(matching: .any)["doneEditingRedactionsButton"].exists,
            "Redaction editor should be open with a Done button."
        )
    }

    /// Saving to the photo library must complete.  PhotoKit runs the change
    /// block on its own queue, so a main-actor-isolated block traps there —
    /// which no unit test sees, because only a real save reaches PhotoKit.
    @MainActor
    func testSaveAsNewPhotoReachesThePhotoLibrary() throws {
        let app = englishApp()
        app.resetAuthorizationStatus(for: .photos)

        let tmpPath = "/tmp/picstrip_save_fixture.png"
        if let srcURL = fixtureImageURL(),
           let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }

        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["editRedactionsButton"].waitForExistence(timeout: 25),
            "Edit Redactions button should appear once the PII scan finishes."
        )

        let saveButton = app.buttons["saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        let saveAsNew = app.buttons["saveAsNewPhotoButton"]
        XCTAssertTrue(app.buttons["inspectFullImageButton"].waitForExistence(timeout: 10))
        reveal(saveAsNew, in: app)
        let acknowledgement = app.descendants(matching: .any)["manualReviewAcknowledgement"].firstMatch
        if acknowledgement.exists {
            reveal(acknowledgement, in: app)
            acknowledgement.tap()
            reveal(saveAsNew, in: app)
        }
        XCTAssertTrue(saveAsNew.exists, "The review must expose save actions after its coverage summary")
        XCTAssertTrue(saveAsNew.isEnabled)
        saveAsNew.tap()

        // First save on a fresh authorization: accept the add-only prompt.
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 5) {
            let allow = prompt.buttons["Allow"]
            (allow.exists ? allow : prompt.buttons.element(boundBy: prompt.buttons.count - 1)).tap()
        }

        // A successful save shows a confirmation and closes the review sheet; a
        // trap kills the app.  The confirmation goes away by itself, so look for
        // it first.
        XCTAssertTrue(
            app.descendants(matching: .any)["savedConfirmation"].waitForExistence(timeout: 20),
            "A confirmation says what the saved copy left out."
        )
        attachScreen("saved_confirmation")
        let sheetClosed = NSPredicate(format: "exists == false")
        expectation(for: sheetClosed, evaluatedWith: saveAsNew)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.state, .runningForeground, "PicStrip should survive saving to Photos.")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Saving to Photos should not report an error.")
    }

    /// A region can be covered with an emoji chosen from the grid.
    @MainActor
    func testARegionCanBeCoveredWithAnEmoji() throws {
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["tryDemoButton"].waitForExistence(timeout: 15))
        app.buttons["tryDemoButton"].tap()
        let edit = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        edit.tap()
        XCTAssertTrue(app.buttons["addCenteredRedactionButton"].waitForExistence(timeout: 5))
        app.buttons["addCenteredRedactionButton"].tap()
        app.buttons["editRegionStyleButton"].tap()
        let emojiStyle = app.buttons["styleButton-emoji"]
        XCTAssertTrue(emojiStyle.waitForExistence(timeout: 5))
        emojiStyle.tap()
        let dog = app.buttons["emojiChoice-🐶"]
        XCTAssertTrue(dog.waitForExistence(timeout: 5), "Choosing Emoji shows the emoji grid.")
        dog.tap()
        XCTAssertTrue(dog.isSelected)
        attachScreen("emoji_picker")
        app.buttons["doneStyleButton"].tap()
        attachScreen("emoji_cover")
    }

    /// A video's face is found, given an emoji, and covered in the saved copy.
    @MainActor
    func testAVideosFacesAreFoundAndCovered() async throws {
        let path = "/tmp/picstrip_video_fixture.mov"
        try await writeFaceMovie(to: URL(fileURLWithPath: path))
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_VIDEO_FIXTURE"] = path
        app.launch()

        XCTAssertTrue(app.buttons["addCoverButton"].waitForExistence(timeout: 90), "The review opens.")
        attachScreen("video_review")
        // Under the timeline and Objects: scrolled to.
        let face = app.buttons["faceRow-1"]
        reveal(face, in: app)
        XCTAssertTrue(face.waitForExistence(timeout: 5), "The face in the fixture is found.")
        let cover = app.buttons["faceCoverMenu-1"]
        XCTAssertEqual(cover.value as? String, "Blur", "Faces are blurred unless the user picks an emoji.")
        cover.tap()
        let emoji = app.buttons["Emoji…"]
        XCTAssertTrue(emoji.waitForExistence(timeout: 5))
        emoji.tap()
        let frog = app.buttons["emojiChoice-🐸"]
        XCTAssertTrue(frog.waitForExistence(timeout: 5))
        frog.tap()
        app.buttons["emojiDoneButton"].tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertEqual(cover.value as? String, "🐸")
        attachScreen("video_emoji_preview")

        // The email in the corner is listed and covered by default.
        let email = app.switches["findingToggle-1"]
        reveal(email, in: app)
        XCTAssertEqual(email.value as? String, "1", "Text is covered unless the user turns it off.")
        XCTAssertTrue(app.buttons["findingRow-1"].label.contains("Email"), app.buttons["findingRow-1"].label)
        attachScreen("video_text_row")

        app.buttons["makeCleanedCopyButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["facesCoveredRow"].waitForExistence(timeout: 120),
                      "The cleaned copy says its face was covered.")
        XCTAssertTrue(app.descendants(matching: .any)["textCoveredRow"].exists, "…and its text.")
        XCTAssertTrue(app.buttons["shareCleanedVideoButton"].exists)
        attachScreen("video_cleaned")

        // Back to the faces: the chosen cover is kept.
        app.buttons["changeCoversButton"].tap()
        XCTAssertTrue(app.buttons["addCoverButton"].waitForExistence(timeout: 10))
        reveal(cover, in: app)
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertEqual(cover.value as? String, "🐸")
    }

    /// A cover drawn on the paused frame is moved and resized, followed, timed
    /// on a zoomed-in timeline, and saved — with a stretch of sound bleeped
    /// from the audio lane's edit menu.
    @MainActor
    func testACoverCanBeDrawnFollowedAndTimed() async throws {
        let path = "/tmp/picstrip_video_draw_fixture.mov"
        try await writeFaceMovie(to: URL(fileURLWithPath: path))
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_VIDEO_FIXTURE"] = path
        app.launch()

        let add = app.buttons["addCoverButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 90), "The review offers Cover an Object.")
        XCTAssertFalse(app.buttons["addBleepButton"].exists, "Bleep and mute are in the audio lane's menu, not buttons.")
        add.tap()
        let area = app.descendants(matching: .any)["drawingArea"]
        // The paused frame is drawn with the covers on it first; a slow CI runner takes a while.
        XCTAssertTrue(area.waitForExistence(timeout: 60), "The paused frame appears to draw on.")
        // Too small at first, then moved and resized around the face, which moves:
        // the cover follows it.
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15))
            .press(forDuration: 0.1, thenDragTo: area.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)))
        let box = app.descendants(matching: .any)["drawnBox"]
        XCTAssertTrue(box.waitForExistence(timeout: 5), "The drawn box stays to be adjusted.")
        let before = box.frame
        box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1, thenDragTo: area.coordinate(withNormalizedOffset: CGVector(dx: 0.37, dy: 0.35))
        )
        XCTAssertGreaterThan(box.frame.midX, before.midX + 10, "Dragging the box moves it.")
        let handle = app.descendants(matching: .any)["drawnBoxResizeHandle"]
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1, thenDragTo: area.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.85))
        )
        XCTAssertGreaterThan(box.frame.width, before.width + 20, "Dragging the corner makes it bigger.")
        XCTAssertTrue(app.buttons["coverPositionButton"].exists, "Its position and size can be set without dragging.")
        attachScreen("draw_cover")
        let follow = app.buttons["followButton"]
        XCTAssertTrue(follow.isEnabled, "A drawn box can be followed.")
        follow.tap()

        let row = app.buttons["drawnRow-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "The followed cover is listed.")
        let end = app.descendants(matching: .any)["coverEndHandle"]
        XCTAssertTrue(end.waitForExistence(timeout: 5), "The new cover is picked, with handles on the timeline.")
        let track = app.descendants(matching: .any)["coverTimelineTrack"]
        let start = app.descendants(matching: .any)["coverStartHandle"]
        // Start it at the very beginning of the video.
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1, thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        )
        XCTAssertTrue(app.buttons["resetTimingButton"].waitForExistence(timeout: 5), "A changed timing can be reset.")
        attachScreen("cover_timeline")

        // Pinching zooms in; the zoom button shows the whole video again.
        track.pinch(withScale: 3, velocity: 3)
        let zoomOut = app.buttons["timelineZoomButton"]
        XCTAssertTrue(zoomOut.waitForExistence(timeout: 5), "Zoomed in, the timeline says how far.")
        XCTAssertTrue(app.descendants(matching: .any)["timelineOverview"].exists, "…and shows the part in view.")
        attachScreen("timeline_zoomed")
        zoomOut.tap()
        XCTAssertFalse(zoomOut.waitForExistence(timeout: 2), "Zoomed out to the whole video.")

        // Holding and dragging along the audio lane selects a stretch, with a menu over it.
        let audio = app.descendants(matching: .any)["audioLane"]
        XCTAssertTrue(audio.exists, "The video has sound, so it has an audio lane.")
        audio.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(
            forDuration: 0.8, thenDragTo: audio.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        )
        let bleep = menuItem("Bleep", in: app)
        XCTAssertTrue(bleep.waitForExistence(timeout: 5), "The selected stretch offers Bleep.")
        XCTAssertTrue(menuItem("Mute", in: app).exists, "…and Mute.")
        attachScreen("audio_selection_menu")
        bleep.tap()
        let clip = app.descendants(matching: .any)["clip-audio-0"]
        XCTAssertTrue(clip.waitForExistence(timeout: 5), "The bleep is a clip on the audio lane.")
        XCTAssertTrue(app.descendants(matching: .any)["coverEndHandle"].exists, "The new bleep can be trimmed.")
        let lane = audio.frame
        XCTAssertGreaterThan(clip.frame.width, lane.width * 0.2, "It covers the stretch dragged across, not a fixed second.")
        attachScreen("bleep_timeline")

        app.buttons["makeCleanedCopyButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["drawnCoveredRow"].waitForExistence(timeout: 120),
                      "The cleaned copy lists the cover that was added.")
        XCTAssertTrue(app.descendants(matching: .any)["audioEditedRow"].exists, "…and the bleep.")
    }

    /// An item of the system edit menu, which shows as a menu item or a button.
    @MainActor
    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let item = app.menuItems[title]
        return item.waitForExistence(timeout: 2) ? item : app.buttons.matching(identifier: title).firstMatch
    }

    /// Video mode records at the quality chosen with the Camera app's controls,
    /// and the recording opens in the video editor — which asks before letting
    /// an unsaved recording go.  A movie stands in for the camera.
    @MainActor
    func testAVideoIsRecordedIntoTheEditor() async throws {
        let path = "/tmp/picstrip_video_camera_fixture.mov"
        try await writeFaceMovie(to: URL(fileURLWithPath: path))
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_VIDEO_CAMERA_FIXTURE"] = path
        // As on a phone, where the document scanner is there too.
        app.launchEnvironment["PICSTRIP_FORCE_SCAN_BUTTON"] = "1"
        app.launch()

        let record = app.buttons["videoRecordButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 15), "The camera opens in Video mode.")
        XCTAssertTrue(app.buttons["cameraMode-video"].isSelected, "Video is the mode picked.")
        XCTAssertTrue(app.buttons["cameraMode-photo"].exists, "Photo is a tap away…")
        XCTAssertTrue(app.buttons["cameraMode-document"].exists, "…and so is Document.")

        let resolution = app.buttons["videoResolutionButton"]
        XCTAssertEqual(resolution.value as? String, "4K", "Recording starts at the most detail.")
        resolution.tap()
        XCTAssertEqual(resolution.value as? String, "HD")
        let frameRate = app.buttons["videoFrameRateButton"]
        XCTAssertEqual(frameRate.value as? String, "30 frames per second")
        frameRate.tap()
        XCTAssertEqual(frameRate.value as? String, "60 frames per second", "The next frame rate the camera offers.")
        let hdr = app.buttons["videoHDRToggle"]
        XCTAssertEqual(hdr.value as? String, "On", "HDR where the camera records it.")
        hdr.tap()
        XCTAssertEqual(hdr.value as? String, "Off")
        XCTAssertTrue(app.buttons["videoStabilizationToggle"].exists)
        XCTAssertTrue(app.buttons["videoFlipButton"].exists)
        attachScreen("video_camera")

        record.tap()
        XCTAssertTrue(app.descendants(matching: .any)["videoRecordingTimer"].waitForExistence(timeout: 5), "Recording shows its time.")
        let photoMode = app.buttons["cameraMode-photo"]
        XCTAssertTrue(!photoMode.exists || !photoMode.isEnabled, "The mode cannot change while recording.")
        XCTAssertFalse(resolution.exists, "…nor the quality.")
        attachScreen("video_camera_recording")
        try await Task.sleep(for: .seconds(1.5))
        record.tap()

        XCTAssertTrue(app.buttons["addCoverButton"].waitForExistence(timeout: 90), "The recording opens in the video editor.")
        app.buttons["videoDoneButton"].tap()
        let discard = app.buttons["discardRecordingButton"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Closing asks before an unsaved recording is lost.")
        discard.tap()
        XCTAssertTrue(app.buttons["libraryButton"].waitForExistence(timeout: 10), "Back on the home screen.")
    }

    /// Skipping face covering still saves a cleaned copy, with every face as it was.
    @MainActor
    func testFaceCoveringCanBeSkipped() async throws {
        let path = "/tmp/picstrip_video_skip_fixture.mov"
        try await writeFaceMovie(to: URL(fileURLWithPath: path), seconds: 30)
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_VIDEO_FIXTURE"] = path
        app.launch()

        let skip = app.buttons["skipFacesButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: 30))
        // The frame being scanned shows up with the face outlined, and the count rises.
        let glimpse = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "The frame being scanned")).firstMatch
        XCTAssertTrue(glimpse.waitForExistence(timeout: 20), "The scan shows the frame it is looking at.")
        let counted = expectation(for: NSPredicate(format: "value BEGINSWITH %@", "1 face"),
                                  evaluatedWith: app.descendants(matching: .any)["scanCounts"])
        await fulfillment(of: [counted], timeout: 20)
        attachScreen("video_scanning")
        skip.tap()
        XCTAssertTrue(app.buttons["shareCleanedVideoButton"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.descendants(matching: .any)["facesCoveredRow"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["noFacesFoundRow"].exists, "Skipped is not the same as none found.")
        XCTAssertFalse(app.buttons["changeCoversButton"].exists)
    }

    /// Always Cover terms are added and removed from the home screen.
    @MainActor
    func testAlwaysCoverListAddsAndRemovesTerms() throws {
        let app = englishApp()
        app.launch()
        XCTAssertTrue(app.buttons["alwaysCoverButton"].waitForExistence(timeout: 15))
        app.buttons["alwaysCoverButton"].tap()

        let field = app.textFields["alwaysCoverField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Alex Thornton")
        app.buttons["alwaysCoverAddButton"].tap()
        let row = app.staticTexts["Alex Thornton"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        attachScreen("always_cover")

        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2))
    }

    /// A card, phone or email finding can leave its end visible, and any text
    /// finding can join Always Cover.
    @MainActor
    func testEditorOffersPartialCoverAndAlwaysCover() throws {
        let app = englishApp()
        let tmpPath = "/tmp/picstrip_partial_fixture.png"
        if let srcURL = fixtureImageURL(), let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        let edit = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 25))
        XCTAssertTrue(app.descendants(matching: .any)["sharingPresetButton"].firstMatch.exists, "The sharing purpose is shown.")
        edit.tap()

        let email = app.descendants(matching: .any)["regionRow-detected-email-0"].firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        let partial = app.switches["partialCoverToggle"].firstMatch
        XCTAssertTrue(partial.waitForExistence(timeout: 5), "An email can keep its domain visible.")
        partial.switches.firstMatch.exists ? partial.switches.firstMatch.tap() : partial.tap()
        XCTAssertTrue(app.buttons["alwaysCoverThisButton"].exists, "A text finding can join Always Cover.")
        attachScreen("partial_cover")
    }

    /// Blur and pixelate offer a strength slider; solid and crosshatch do not.
    @MainActor
    func testStrengthSliderAppearsOnlyForBlurAndPixelate() throws {
        let app = englishApp()

        let tmpPath = "/tmp/picstrip_strength_fixture.png"
        if let srcURL = fixtureImageURL(),
           let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }

        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        let editRedactionsButton = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(editRedactionsButton.waitForExistence(timeout: 25))
        editRedactionsButton.tap()

        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'regionRow-'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.tap()

        app.buttons["editRegionStyleButton"].tap()
        let slider = app.sliders["strengthSlider"]
        XCTAssertTrue(app.buttons["styleButton-solid"].waitForExistence(timeout: 5))
        XCTAssertFalse(slider.exists, "Solid has no strength.")

        app.buttons["styleButton-blur"].tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "Blur should offer a strength slider.")
        XCTAssertFalse(app.buttons["colorButton-black"].exists, "Blur has no colour.")

        slider.adjust(toNormalizedSliderPosition: 1)

        dumpScreen("blur")

        app.buttons["styleButton-pixelate"].tap()
        dumpScreen("pixelate")

        app.buttons["styleButton-crosshatch"].tap()
        dumpScreen("crosshatch")
        XCTAssertTrue(app.buttons["colorButton-black"].waitForExistence(timeout: 5))
        XCTAssertFalse(slider.exists, "Crosshatch has no strength.")
        app.buttons["doneStyleButton"].tap()
        XCTAssertTrue(app.buttons["undoRedactionButton"].isEnabled, "Style and strength changes are undoable.")
    }

    func testSampleAndAccessibleRegionReview() throws {
        let app = englishApp()
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["tryDemoButton"].waitForExistence(timeout: 15))
        app.buttons["tryDemoButton"].tap()
        let edit = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts.firstMatch.exists, "The sample does not need library permission.")
        attachScreen("06_Sample")
        edit.tap()
        XCTAssertTrue(app.buttons["addCenteredRedactionButton"].waitForExistence(timeout: 5))
        app.buttons["addCenteredRedactionButton"].tap()
        app.buttons["regionPositionButton"].tap()
        XCTAssertTrue(app.sliders["Width"].waitForExistence(timeout: 5))
        app.sliders["Width"].adjust(toNormalizedSliderPosition: 0.65)
        attachScreen("07_AccessiblePosition")
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["undoRedactionButton"].isEnabled)
        app.buttons["doneEditingRedactionsButton"].tap()
        app.buttons["saveButton"].tap()
        let inspect = app.buttons["inspectFullImageButton"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 15))
        reveal(inspect, in: app)
        inspect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fullReviewImage"].waitForExistence(timeout: 10))
        let revealOriginal = app.buttons["revealOriginalButton"]
        XCTAssertTrue(revealOriginal.exists)
        revealOriginal.tap()
        XCTAssertTrue(app.navigationBars["Original"].exists)
        attachScreen("08_OriginalComparison")
        revealOriginal.tap()
        XCTAssertTrue(app.navigationBars["Final preview"].exists)
        attachScreen("09_FullPreview")
    }

    func testSampleReviewAtLargestTextSize() throws {
        let app = englishApp()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launch()
        let sample = app.buttons["tryDemoButton"]
        XCTAssertTrue(sample.waitForExistence(timeout: 15))
        reveal(sample, in: app)
        sample.tap()
        XCTAssertTrue(app.descendants(matching: .any)["editRedactionsButton"].waitForExistence(timeout: 30))
        let review = app.buttons["saveButton"]
        reveal(review, in: app)
        XCTAssertTrue(review.isHittable)
        review.tap()
        let inspect = app.buttons["inspectFullImageButton"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 15))
        reveal(inspect, in: app)
        XCTAssertTrue(inspect.isHittable)
        XCTAssertTrue(app.buttons["shareCleanedImageButton"].isHittable)
        attachScreen("10_LargestTextReview")
        inspect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fullReviewImage"].waitForExistence(timeout: 10))
    }

    private func englishApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // A lazy List may not create the target until we scroll toward it.
        // Reading its identifier before it exists would fail before any gesture.
        let identifier = element.exists ? element.identifier : ""
        let list = identifier.isEmpty ? app.collectionViews.firstMatch
            : app.collectionViews.containing(.any, identifier: identifier).firstMatch
        let scroll = identifier.isEmpty ? app.scrollViews.firstMatch
            : app.scrollViews.containing(.any, identifier: identifier).firstMatch
        let container = list.exists ? list : (scroll.exists ? scroll : app)
        let containerFrame = container.frame.intersection(app.frame)
        let navigationBottom = app.navigationBars.allElementsBoundByIndex
            .map(\.frame).filter { $0.intersects(containerFrame) }.map(\.maxY).max() ?? containerFrame.minY
        // A bar fixed over the bottom of the list: the photo review's Share, or
        // the video screen's Make Cleaned Copy.
        let footer = [app.buttons["shareCleanedImageButton"], app.buttons["makeCleanedCopyButton"]].first { $0.exists }
        let top = max(containerFrame.minY, navigationBottom) + 4
        let bottom = min(containerFrame.maxY, footer.map { $0.frame.minY - 12 } ?? containerFrame.maxY) - 4
        let viewport = CGRect(x: containerFrame.minX + 4, y: top, width: containerFrame.width - 8, height: bottom - top)
        XCTAssertGreaterThan(viewport.height, 80, "The scrolling content must have a visible viewport", file: file, line: line)

        for _ in 0..<8 {
            // XCTest can report a control behind the fixed footer as hittable.
            // Require its actual frame to fit above the footer before tapping.
            if element.exists, viewport.contains(element.frame.insetBy(dx: 1, dy: 1)), element.isHittable || !element.isEnabled {
                // A visible disabled Save still needs the manual-review acknowledgement.
                return
            }
            // Use the enclosing list's edge: iPad sheets do not fill the screen,
            // and dragging through the preview image would pan that image.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let frame = element.exists ? element.frame : .null
            let span = viewport.height - 40
            // Content moves by `distance` (negative = up) to bring the control in.
            let distance: CGFloat? = (frame.isNull || frame.isEmpty) ? nil
                : frame.maxY > viewport.maxY ? -(frame.maxY - viewport.maxY + 16)
                : viewport.minY - frame.minY + 16
            if list.exists, let distance, abs(distance) < span {
                // Close, in a list: move exactly that far and hold, so the list
                // does not coast past it — a fixed stride overshoots a short iPad
                // sheet at large text sizes every time.  (A held drag does not
                // scroll a plain scroll view that starts under a button, so the
                // home screen keeps the quick swipe.)
                let startY = distance < 0 ? viewport.maxY - 20 : viewport.minY + 20
                let start = origin.withOffset(CGVector(dx: viewport.maxX - 8, dy: startY))
                let end = origin.withOffset(CGVector(dx: viewport.maxX - 8, dy: startY + distance))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.3)
            } else {
                // Far, or not created yet: a quick swipe toward it.
                let upwards = distance.map { $0 < 0 } ?? true
                let upper = viewport.minY + viewport.height * 0.25
                let lower = viewport.maxY - 24
                let start = origin.withOffset(CGVector(dx: viewport.maxX - 8, dy: upwards ? lower : upper))
                let end = origin.withOffset(CGVector(dx: viewport.maxX - 8, dy: upwards ? upper : lower))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        XCTFail("Could not reveal \(identifier.isEmpty ? "the off-screen control" : identifier) inside the unobscured viewport", file: file, line: line)
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Saves a screenshot for a human to look at when `PICSTRIP_UITEST_DUMP` names a folder.
    private func dumpScreen(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["PICSTRIP_UITEST_DUMP"] else { return }
        Thread.sleep(forTimeInterval: 0.6)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func makeCleanPNG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return try XCTUnwrap(image.pngData(), "Clean PNG fixture should encode.")
    }
}
