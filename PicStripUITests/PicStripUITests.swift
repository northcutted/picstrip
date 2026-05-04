import XCTest

/// Fastlane snapshot test suite for PicStrip.
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
final class PicStripUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()
    }

    // MARK: - 01 Home screen

    /// Captures the home screen with the scanner hero animation in mid-sweep.
    /// We wait 1.2 s so the detection beam is clearly visible.
    @MainActor
    func testScreenshot01Home() throws {
        // The hero animation starts automatically; just wait for the first
        // detection pass to be clearly under way.
        Thread.sleep(forTimeInterval: 1.2)
        snapshot("01_Home")
    }

    // MARK: - 02 About sheet

    /// Taps the info button in the navigation bar and captures the About sheet.
    @MainActor
    func testScreenshot02About() throws {
        // Let the app settle.
        Thread.sleep(forTimeInterval: 0.6)

        // Tap the info / question-mark button.
        let infoButton = XCUIApplication().buttons["infoButton"]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 5))
        infoButton.tap()

        // Wait for the sheet to finish its presentation animation.
        Thread.sleep(forTimeInterval: 0.6)
        snapshot("02_About")
    }
}
