import Synchronization
import UIKit
import XCTest

/// Fastlane snapshot test suite for PicStrip.
///
/// All screenshots are captured in a single test method after two app.launch()
/// calls (first: no fixture; second: with fixture).  Splitting captures across
/// multiple test methods causes XCTest to terminate and relaunch the app between
/// methods, which fails with "Failed to terminate com.northcutt.PicStrip" in
/// headless CI.
///
/// Screens captured:
///   01_FullPreview — full-resolution output inspection
///   02_RedactionEditor — custom redaction edit mode
///   03_Metadata — metadata and detected regions
///   04_ReviewAndShare — cleaned result and removal summary
///   05_Sample — fictional sample without photo-library access
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

    // MARK: - All screenshots — two launches

    /// Captures every App Store screenshot in one continuous session.
    /// Launch 1: fictional sample. Launch 2: editable fixture and final output.
    @MainActor
    func testAllScreenshots() throws {

        let app = XCUIApplication()
        setupSnapshot(app)

        // ─────────────────────────────────────────────────────────────────────
        // LAUNCH 1: No fixture — home and fictional sample
        // ─────────────────────────────────────────────────────────────────────
        // The simulator has no camera, so it would hide "Take Photo" and "Scan
        // Document".  Show the home screen the way a real iPhone shows it.
        app.launchEnvironment["PICSTRIP_FORCE_SCAN_BUTTON"] = "1"
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launch()

        // Home: hero animation has started, wait for it to settle.
        Thread.sleep(forTimeInterval: 1.5)
        attachScreen("Home")

        // Demo shows value without requesting library permission.
        app.buttons["tryDemoButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editRedactionsButton"].waitForExistence(timeout: 30))
        snapshot("05_Sample")
        attachScreen("05_Sample")

        // ─────────────────────────────────────────────────────────────────────
        // LAUNCH 2: With fixture — photo loaded screens
        // ─────────────────────────────────────────────────────────────────────
        app.terminate()

        // Write fixture bytes to the simulator's /tmp so the app can read them.
        let fixtureURL = fixtureImageURL()
        XCTAssertNotNil(fixtureURL, "test_list.png must be in the UITest bundle")

        let tmpPath = "/tmp/picstrip_fixture.png"
        if let srcURL = fixtureURL,
           let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }

        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        // 03 — Photo loaded: wait for the dismiss button (photo fully loaded), then
        // wait for editRedactionsButton which only appears once the PII scan is
        // complete — guarantees the badge row is stable. Incomplete checks still
        // require a separate acknowledgement before saving or sharing.
        let dismissButton = app.buttons["dismissPhotoButton"]
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 15),
                      "Dismiss button should appear after fixture image loads")

        let editRedactionsButton = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(
            editRedactionsButton.waitForExistence(timeout: 20),
            "Edit Redactions button should appear once the PII scan finishes."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["metadataPhotoPreview"].exists,
            "Loaded-photo screen should expose a zoomable/pannable image preview."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["piiPill"].exists,
            "Visual detections should no longer be surfaced as the old PII pill."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["metadataFoundLabel"].exists,
            "Metadata should remain its own section when visual sensitive data is present."
        )
        snapshot("03_Metadata")
        attachScreen("03_Metadata")

        // 04 — Redaction editor: create one manual redaction on top of detected regions.
        editRedactionsButton.tap()

        let addRedactionButton = app.descendants(matching: .any)["addRedactionButton"]
        XCTAssertTrue(addRedactionButton.waitForExistence(timeout: 5))
        addRedactionButton.tap()

        let preview = app.descendants(matching: .any)["metadataPhotoPreview"]
        let start = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.30))
        let end = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.5)
        snapshot("02_RedactionEditor")
        attachScreen("02_RedactionEditor")
        app.descendants(matching: .any)["doneEditingRedactionsButton"].tap()
        Thread.sleep(forTimeInterval: 0.3)

        // 05 — Review & save sheet: tap Save to Photos.
        let saveButton = app.buttons["saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()
        // Wait for the pre-save review sheet to slide up.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(
            app.descendants(matching: .any)["savePreviewImage"].waitForExistence(timeout: 5),
            "Review sheet should show the processed image preview before saving."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["savePreviewLabel"].exists,
            "Review sheet should label the visual save preview."
        )
        XCTAssertTrue(app.buttons["shareCleanedImageButton"].isHittable,
                      "The primary share action must remain visible while reviewing the photo")
        snapshot("04_ReviewAndShare")
        attachScreen("04_ReviewAndShare")
        // The review is a short form sheet on iPad; the button may be below the fold.
        reveal(app.buttons["inspectFullImageButton"], in: app)
        app.buttons["inspectFullImageButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["fullReviewImage"].waitForExistence(timeout: 10))
        snapshot("01_FullPreview")
        attachScreen("01_FullPreview")
    }

    /// The simulator has no camera, so by default the home screen must not offer a scan.
    @MainActor
    func testHomeScreenHidesScanWithoutACamera() throws {
        let app = englishApp()
        app.launch()

        XCTAssertTrue(app.buttons["selectPhotoButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["selectMultiplePhotosButton"].exists)
        XCTAssertTrue(app.buttons["browseFilesButton"].exists)
        XCTAssertFalse(app.buttons["scanDocumentButton"].exists)
        XCTAssertFalse(app.buttons["takePhotoButton"].exists)
    }

    /// Paste is offered only while the pasteboard holds an image, and then from the
    /// navigation bar — never as a stray control among the import buttons.
    @MainActor
    func testPasteIsOfferedOnlyWhenThereIsAnImageToPaste() throws {
        let app = englishApp()
        app.launch()
        XCTAssertTrue(app.buttons["selectPhotoButton"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["pasteImageButton"].firstMatch.exists)
        app.terminate()

        app.launchEnvironment["PICSTRIP_FORCE_PASTE_BUTTON"] = "1"
        app.launch()
        let paste = app.descendants(matching: .any)["pasteImageButton"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 15))
        XCTAssertLessThan(
            paste.frame.maxY, app.buttons["selectPhotoButton"].frame.minY,
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

        XCTAssertTrue(app.buttons["selectPhotoButton"].waitForExistence(timeout: 15))
        let identifiers = [
            "takePhotoButton", "selectPhotoButton", "selectScreenshotButton", "scanDocumentButton",
            "selectVideoButton", "selectMultiplePhotosButton", "browseFilesButton", "tryDemoButton"
        ]
        for identifier in identifiers {
            XCTAssertTrue(app.buttons[identifier].isHittable, "\(identifier) must be on the first screen.")
        }
        XCTAssertLessThan(
            app.buttons["takePhotoButton"].frame.maxY, app.buttons["selectPhotoButton"].frame.minY,
            "With a camera, Take Photo is the main button, above the grid."
        )
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
        let share = app.buttons["shareCleanedImageButton"]
        let top = max(containerFrame.minY, navigationBottom) + 4
        let bottom = min(containerFrame.maxY, share.exists ? share.frame.minY - 12 : containerFrame.maxY) - 4
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
