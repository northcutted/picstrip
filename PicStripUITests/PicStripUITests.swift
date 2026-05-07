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
        snapshot("05_ReviewAndSave")
    }
}
