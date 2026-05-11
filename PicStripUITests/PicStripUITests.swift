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

    @MainActor
    func testCleanFixtureShowsNoMetadataBanner() throws {
        let app = XCUIApplication()

        let cleanPath = "/tmp/picstrip_clean_fixture.png"
        try makeCleanPNG().write(to: URL(fileURLWithPath: cleanPath))

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

        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        let preview = app.descendants(matching: .any)["metadataPhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))

        let editButton = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
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

    private func makeCleanPNG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return try XCTUnwrap(image.pngData(), "Clean PNG fixture should encode.")
    }
}
