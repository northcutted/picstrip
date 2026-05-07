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
///   03_PhotoLoaded   — photo loaded, badge row visible
///   04_MetadataDetail — EXIF category detail panel open
///   05_ReviewAndSave — pre-save review sheet
@MainActor
final class PicStripUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - All screenshots — two launches

    /// Captures every App Store screenshot in one continuous session.
    /// Launch 1 (no fixture): 01_Home, 02_About
    /// Launch 2 (with fixture): 03_PhotoLoaded, 04_MetadataDetail, 05_ReviewAndSave
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
        Thread.sleep(forTimeInterval: 0.4)
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

        // 03 — Photo loaded: wait for the dismiss button to appear (proxy for
        // the photo being fully loaded and the badge row rendered).
        let dismissButton = app.buttons["Dismiss photo"]
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 15),
                      "Dismiss button should appear after fixture image loads")
        // Also wait for processing spinner to disappear.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(
            app.descendants(matching: .any)["metadataPhotoPreview"].exists,
            "Loaded-photo screen should expose a zoomable/pannable image preview."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["sensitiveDataSection"].waitForExistence(timeout: 15),
            "Loaded-photo screen should show visual sensitive data separately from metadata."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["piiPill"].exists,
            "Visual detections should no longer be surfaced as the old PII pill."
        )
        XCTAssertTrue(
            app.staticTexts["Metadata found in this photo"].exists,
            "Metadata should remain its own section when visual sensitive data is present."
        )
        snapshot("03_PhotoLoaded")

        // 04 — Metadata detail panel: tap the EXIF badge.
        let exifBadge = app.buttons["badge_EXIF"]
        XCTAssertTrue(exifBadge.waitForExistence(timeout: 5))
        exifBadge.tap()
        Thread.sleep(forTimeInterval: 0.6)
        snapshot("04_MetadataDetail")

        // Dismiss the panel by tapping the badge again.
        exifBadge.tap()
        Thread.sleep(forTimeInterval: 0.5)

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
            app.staticTexts["Preview with redactions"].exists || app.staticTexts["Preview"].exists,
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
