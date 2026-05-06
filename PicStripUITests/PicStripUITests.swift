import XCTest

/// Fastlane snapshot test suite for PicStrip.
///
/// All screenshots are captured in a single test method after one app.launch()
/// call. Splitting captures across multiple test methods causes XCTest to
/// terminate and relaunch the app between methods, which fails with
/// "Failed to terminate com.northcutt.PicStrip" in headless CI.
///
/// Screens captured (v1):
///   01_Home  — home screen with the two-pass hero animation visible
///   02_About — About & Trust sheet
///
/// Future screens (requires seeding a test image into the simulator photo
/// library via `xcrun simctl addmedia` in the CI job):
///   03_Photo     — photo loaded, metadata badge row visible
///   04_Review    — pre-save review / redaction list
///   05_PIIDetail — PII details sheet
@MainActor
final class PicStripUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - All screenshots — single launch

    /// Captures every App Store screenshot in one continuous session.
    /// One app.launch() → navigate → snapshot → navigate → snapshot …
    @MainActor
    func testAllScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()

        // ── 01 Home ────────────────────────────────────────────────────────
        // The hero animation starts automatically; wait for the first
        // detection pass to be clearly under way.
        Thread.sleep(forTimeInterval: 1.2)
        snapshot("01_Home")

        // ── 02 About sheet ─────────────────────────────────────────────────
        // Let the app settle, then tap the info button.
        Thread.sleep(forTimeInterval: 0.6)
        let infoButton = app.buttons["infoButton"]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 5))
        infoButton.tap()

        // Wait for the sheet to finish its presentation animation.
        Thread.sleep(forTimeInterval: 0.6)
        snapshot("02_About")
    }
}
