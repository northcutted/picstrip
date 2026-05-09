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
///   02_PrivacyImpact — aggregate removed-data analysis sheet
///   03_About         — About & Trust sheet
///   04_PhotoLoaded   — photo loaded, scan complete, badge row and sensitive data section visible
///   05_RedactionEditor — custom redaction edit mode
///   06_SensitiveData — Sensitive Data review sheet open
///   07_ReviewAndSave — pre-save review sheet
@MainActor
final class PicStripUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - All screenshots — two launches

    /// Captures every App Store screenshot in one continuous session.
    /// Launch 1 (no fixture): 01_Home, 02_PrivacyImpact, 03_About
    /// Launch 2 (with fixture): 04_PhotoLoaded, 05_RedactionEditor, 06_SensitiveData, 07_ReviewAndSave
    @MainActor
    func testAllScreenshots() throws {

        let app = XCUIApplication()
        setupSnapshot(app)

        // ─────────────────────────────────────────────────────────────────────
        // LAUNCH 1: No fixture — home + aggregate stats + About
        // ─────────────────────────────────────────────────────────────────────
        app.launchEnvironment["PICSTRIP_SEED_STATS"] = "1"
        app.launch()

        // 01 — Home: hero animation has started, wait for it to settle.
        Thread.sleep(forTimeInterval: 1.5)
        snapshot("01_Home")

        // 02 — Aggregate privacy impact sheet
        let privacyStatsButton = app.descendants(matching: .any)["privacyStatsButton"]
        XCTAssertTrue(privacyStatsButton.waitForExistence(timeout: 5))
        privacyStatsButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["privacyImpactSummary"].waitForExistence(timeout: 5),
            "Privacy impact sheet should appear after tapping the home stats badge."
        )
        Thread.sleep(forTimeInterval: 0.5)
        snapshot("02_PrivacyImpact")
        app.buttons["privacyImpactDoneButton"].tap()

        // 03 — About sheet
        Thread.sleep(forTimeInterval: 0.4)
        let infoButton = app.buttons["infoButton"]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 5))
        infoButton.tap()
        Thread.sleep(forTimeInterval: 0.8)
        snapshot("03_About")

        // ─────────────────────────────────────────────────────────────────────
        // LAUNCH 2: With fixture — photo loaded screens
        // ─────────────────────────────────────────────────────────────────────
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "PICSTRIP_SEED_STATS")

        // Write fixture bytes to the simulator's /tmp so the app can read them.
        let fixtureURL = Bundle(for: type(of: self))
            .url(forResource: "test_list", withExtension: "png")
        XCTAssertNotNil(fixtureURL, "test_list.png must be in the UITest bundle")

        let tmpPath = "/tmp/picstrip_fixture.png"
        if let srcURL = fixtureURL,
           let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }

        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        // 04 — Photo loaded: wait for the dismiss button (photo fully loaded), then
        // wait for reviewSensitiveDataButton which only appears once the PII scan is
        // complete — guarantees the badge row is stable and saveButton is enabled.
        let dismissButton = app.buttons["dismissPhotoButton"]
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 15),
                      "Dismiss button should appear after fixture image loads")

        let reviewSensitiveDataButton = app.descendants(matching: .any)["reviewSensitiveDataButton"]
        XCTAssertTrue(
            reviewSensitiveDataButton.waitForExistence(timeout: 20),
            "Review Sensitive Data button should appear once the PII scan finishes."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["metadataPhotoPreview"].exists,
            "Loaded-photo screen should expose a zoomable/pannable image preview."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["sensitiveDataSection"].exists,
            "Loaded-photo screen should show visual sensitive data separately from metadata."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["piiPill"].exists,
            "Visual detections should no longer be surfaced as the old PII pill."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["metadataFoundLabel"].exists,
            "Metadata should remain its own section when visual sensitive data is present."
        )
        snapshot("04_PhotoLoaded")

        // 05 — Redaction editor: create one manual redaction on top of detected regions.
        let editRedactionsButton = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(editRedactionsButton.waitForExistence(timeout: 5))
        editRedactionsButton.tap()

        let addRedactionButton = app.descendants(matching: .any)["addRedactionButton"]
        XCTAssertTrue(addRedactionButton.waitForExistence(timeout: 5))
        addRedactionButton.tap()

        let preview = app.descendants(matching: .any)["metadataPhotoPreview"]
        let start = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.30))
        let end = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.5)
        snapshot("05_RedactionEditor")
        app.descendants(matching: .any)["doneEditingRedactionsButton"].tap()
        Thread.sleep(forTimeInterval: 0.3)

        // 06 — Sensitive Data sheet: tap the review button, wait for the sheet.
        reviewSensitiveDataButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["sensitiveDataReview"].waitForExistence(timeout: 5),
            "Sensitive Data sheet should appear after tapping the review button."
        )
        Thread.sleep(forTimeInterval: 0.5)
        snapshot("06_SensitiveData")

        // Dismiss the sheet via the Done button in the nav bar.
        app.buttons["sensitiveDataDoneButton"].tap()
        Thread.sleep(forTimeInterval: 0.5)

        // 07 — Review & save sheet: tap Save to Photos.
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
        snapshot("07_ReviewAndSave")
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
    func testPrivacyStatsButtonOpensAggregateAnalysis() throws {
        let app = XCUIApplication()
        app.launchEnvironment["PICSTRIP_SEED_STATS"] = "1"
        app.launch()

        let statsButton = app.descendants(matching: .any)["privacyStatsButton"]
        XCTAssertTrue(statsButton.waitForExistence(timeout: 5))
        statsButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["privacyImpactSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Removed Data"].exists)
    }

    @MainActor
    func testManualRedactionEditorCanCreateCustomRegion() throws {
        let app = XCUIApplication()

        let fixtureURL = Bundle(for: type(of: self))
            .url(forResource: "test_list", withExtension: "png")
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

    @MainActor
    func testSensitiveDataReviewFocusesDetection() throws {
        let app = XCUIApplication()

        let fixtureURL = Bundle(for: type(of: self))
            .url(forResource: "test_list", withExtension: "png")
        let tmpPath = "/tmp/picstrip_sensitive_fixture.png"
        if let srcURL = fixtureURL,
           let data = try? Data(contentsOf: srcURL) {
            try? data.write(to: URL(fileURLWithPath: tmpPath))
        }

        app.launchEnvironment["PICSTRIP_FIXTURE"] = tmpPath
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["sensitiveDataSection"].waitForExistence(timeout: 20),
            "Fixture should surface the dedicated sensitive data section."
        )

        let reviewButton = app.descendants(matching: .any)["reviewSensitiveDataButton"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5))
        reviewButton.tap()

        XCTAssertTrue(app.navigationBars["Sensitive Data"].waitForExistence(timeout: 5))

        let emailRow = app.descendants(matching: .any)["sensitiveDataRow_email"]
        XCTAssertTrue(emailRow.waitForExistence(timeout: 10))
        emailRow.tap()

        XCTAssertTrue(emailRow.exists)

        let redactAllButton = app.buttons["Redact All"].firstMatch
        XCTAssertTrue(redactAllButton.exists || app.buttons["Deselect All"].firstMatch.exists)
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
