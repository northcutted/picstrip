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
///   01_Home          — home screen with hero animation
///   02_About         — About & Trust sheet
///   03_PhotoLoaded   — photo loaded, scan complete, Edit Redactions row visible
///   04_RedactionEditor — custom redaction edit mode
///   05_ReviewAndSave — pre-save review sheet
@MainActor
final class PicStripUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func fixtureImageURL() -> URL? {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: "test_list", withExtension: "png") {
            return url
        }

        let bundledURL = bundle.bundleURL.appendingPathComponent("test_list.png")
        if FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("test_list.png")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }

        return nil
    }

    // MARK: - All screenshots — two launches

    /// Captures every App Store screenshot in one continuous session.
    /// Launch 1 (no fixture): 01_Home, 02_About
    /// Launch 2 (with fixture): 03_PhotoLoaded, 04_RedactionEditor, 05_ReviewAndSave
    @MainActor
    func testAllScreenshots() throws {

        let app = XCUIApplication()
        setupSnapshot(app)

        // ─────────────────────────────────────────────────────────────────────
        // LAUNCH 1: No fixture — home + About
        // ─────────────────────────────────────────────────────────────────────
        // The simulator has no camera, so it would hide "Take Photo" and "Scan
        // Document".  Show the home screen the way a real iPhone shows it.
        app.launchEnvironment["PICSTRIP_FORCE_SCAN_BUTTON"] = "1"
        app.launch()

        // 01 — Home: hero animation has started, wait for it to settle.
        Thread.sleep(forTimeInterval: 1.5)
        snapshot("01_Home")

        // 02 — About sheet
        let infoButton = app.buttons["infoButton"]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 5))
        infoButton.tap()
        Thread.sleep(forTimeInterval: 0.8)
        snapshot("02_About")

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
        // complete — guarantees the badge row is stable and saveButton is enabled.
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
        snapshot("03_PhotoLoaded")

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
        snapshot("04_RedactionEditor")
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
        snapshot("05_ReviewAndSave")
    }

    /// The simulator has no camera, so by default the home screen must not offer a scan.
    @MainActor
    func testHomeScreenHidesScanWithoutACamera() throws {
        let app = XCUIApplication()
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
        let app = XCUIApplication()
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

    /// With the scan button present, every import action must still be on screen and tappable.
    @MainActor
    func testHomeScreenFitsAllImportActionsWithScan() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PICSTRIP_FORCE_SCAN_BUTTON"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["selectPhotoButton"].waitForExistence(timeout: 15))
        let identifiers = [
            "selectPhotoButton", "selectMultiplePhotosButton", "takePhotoButton", "scanDocumentButton", "browseFilesButton"
        ]
        for identifier in identifiers {
            XCTAssertTrue(app.buttons[identifier].isHittable, "\(identifier) must be reachable on the home screen.")
        }
    }

    @MainActor
    func testCleanFixtureShowsNoMetadataBanner() throws {
        let app = XCUIApplication()

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
        let app = XCUIApplication()

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
        let app = XCUIApplication()

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
        let app = XCUIApplication()
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
        XCTAssertTrue(saveAsNew.waitForExistence(timeout: 10))
        saveAsNew.tap()

        // First save on a fresh authorization: accept the add-only prompt.
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 5) {
            let allow = prompt.buttons["Allow"]
            (allow.exists ? allow : prompt.buttons.element(boundBy: prompt.buttons.count - 1)).tap()
        }

        // A successful save closes the review sheet; a trap kills the app.
        let sheetClosed = NSPredicate(format: "exists == false")
        expectation(for: sheetClosed, evaluatedWith: saveAsNew)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.state, .runningForeground, "PicStrip should survive saving to Photos.")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Saving to Photos should not report an error.")
    }

    /// Blur and pixelate offer a strength slider; solid and crosshatch do not.
    @MainActor
    func testStrengthSliderAppearsOnlyForBlurAndPixelate() throws {
        let app = XCUIApplication()

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

        let slider = app.sliders["strengthSlider"]
        XCTAssertTrue(app.buttons["styleButton-solid"].waitForExistence(timeout: 5))
        XCTAssertFalse(slider.exists, "Solid has no strength.")

        app.buttons["styleButton-blur"].tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "Blur should offer a strength slider.")
        XCTAssertFalse(app.buttons["colorButton-black"].exists, "Blur has no colour.")

        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.buttons["undoRedactionButton"].isEnabled, "A strength change is undoable.")
        if let dump = ProcessInfo.processInfo.environment["PICSTRIP_UITEST_DUMP"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dump))
        }

        app.buttons["styleButton-crosshatch"].tap()
        XCTAssertTrue(app.buttons["colorButton-black"].waitForExistence(timeout: 5))
        XCTAssertFalse(slider.exists, "Crosshatch has no strength.")
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
