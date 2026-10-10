import UIKit
import XCTest

/// Xcode's accessibility audits on PicStrip's main screens — the evidence
/// behind the VoiceOver and Larger Text App Store labels; see
/// docs/releases/1.7.1-accessibility.md, which also lists what only a person
/// with VoiceOver on a device can check.
///
/// At the largest accessibility text size (in dark) every audit type runs.
/// At the default size (in light) the audits that depend on size there — hit
/// regions, labels, traits, text left out of the accessibility tree — run;
/// Dynamic Type and clipping are measured at the largest size, where they
/// show.  Contrast findings are attached, not failed: PicStrip does not claim
/// Sufficient Contrast, and its secondary text and Liquid Glass are the
/// system's.  Anything else fails unless it is a reviewed exception
/// (`acceptedReason`).
///
/// CI audits the screens of the common tasks, sharing launches, in about three
/// minutes.  Every main screen at both sizes runs with
/// `TEST_RUNNER_PICSTRIP_AUDIT_EVERY_SCREEN=1` in xcodebuild's environment, or
/// when /tmp/picstrip-audit-every-screen exists.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    private static let auditsEveryScreen = ProcessInfo.processInfo.environment["PICSTRIP_AUDIT_EVERY_SCREEN"] == "1"
        || FileManager.default.fileExists(atPath: "/tmp/picstrip-audit-every-screen")

    private var contrastFindings: [String] = []
    /// The launch's text size, as it is named in failures and screenshots.
    private var textSize = ""
    /// The launch's appearance: dark at the largest size, light at the default.
    private var appearance = XCUIDevice.Appearance.light
    private var isLargestText = false
    /// The navigation bars' frames on the screen being audited, looked up once.
    private var navigationBarFrames: [CGRect]?

    override func setUpWithError() throws {
        // One screen's findings must not hide the next screen's.
        continueAfterFailure = true
    }

    override func tearDown() {
        if !contrastFindings.isEmpty {
            let report = XCTAttachment(string: contrastFindings.joined(separator: "\n"))
            report.name = "Contrast findings (not failed)"
            report.lifetime = .keepAlways
            add(report)
        }
        super.tearDown()
    }

    // MARK: - Tests

    /// The photo, its metadata, the editor and the review.
    func testPhotoScreensAtDefaultTextSize() throws {
        let app = try launch(largestText: false) { app in
            app.launchEnvironment["PICSTRIP_FIXTURE"] = try self.stagedFixture("store_cafe", "jpg")
        }
        try auditPhotoFlow(app)
    }

    /// The photo, the editor and its style sheet, and the review — and with
    /// every screen, the metadata, Position & size, the full-size preview,
    /// home, About and Always Cover.
    func testPhotoScreensAtLargestTextSize() throws {
        let app = try launch(largestText: true) { app in
            app.launchEnvironment["PICSTRIP_FIXTURE"] = try self.stagedFixture("store_cafe", "jpg")
        }
        try auditPhotoFlow(app)
    }

    /// Video mode and a recording in the video editor at the largest size —
    /// and with every screen, the viewfinder, the rest of the editor and a
    /// batch, then the same at the default size with Cover an Object.
    func testCameraAndVideoScreens() async throws {
        let movie = "/tmp/picstrip_a11y_movie.mov"
        try await writeFaceMovie(to: URL(fileURLWithPath: movie))
        let sizes = Self.auditsEveryScreen ? [true, false] : [true]
        for largestText in sizes {
            let app = try launchCamera(largestText: largestText, movie: movie)
            try auditCameraAndVideo(app)
            app.terminate()
        }
        guard Self.auditsEveryScreen else { return }
        let batch = try launch(largestText: true) { app in
            let files = [try self.stagedFixture("store_cafe", "jpg"), try self.stagedFixture("store_street", "mov")]
            app.launchEnvironment["PICSTRIP_BATCH_FIXTURE"] = files.joined(separator: "\n")
        }
        XCTAssertTrue(batch.descendants(matching: .any)["videoBatchNote"].waitForExistence(timeout: 20), "The batch opens.")
        audit("Batch", in: batch)
    }

    // MARK: - Flows

    private func auditPhotoFlow(_ app: XCUIApplication) throws {
        let everyScreen = Self.auditsEveryScreen
        let edit = app.descendants(matching: .any)["editRedactionsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30), "The scan finishes.")
        let preview = app.descendants(matching: .any)["metadataPhotoPreview"].value as? String ?? ""
        XCTAssertTrue(preview.hasSuffix("highlighted") && !preview.contains("^["), "VoiceOver hears the count, not markup: “\(preview)”.")
        audit("Photo", in: app)

        if everyScreen || !isLargestText {
            let location = app.buttons["badge_GPS"]
            XCTAssertTrue(reveal(location, in: app), "The photo's location badge can be reached.")
            location.tap()
            let closeLocation = app.buttons["Close Location details"]
            XCTAssertTrue(closeLocation.waitForExistence(timeout: 5), "The location's details open.")
            audit("Metadata panel", in: app)
            closeLocation.tap()
        }

        XCTAssertTrue(reveal(edit, in: app))
        edit.tap()
        let firstRegion = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'regionRow-'")).firstMatch
        XCTAssertTrue(firstRegion.waitForExistence(timeout: 5), "The editor lists the findings.")
        reveal(firstRegion, in: app)
        firstRegion.tap()
        audit("Editor", in: app)

        if everyScreen || isLargestText {
            let style = app.buttons["editRegionStyleButton"]
            reveal(style, in: app)
            style.tap()
            XCTAssertTrue(app.buttons["doneStyleButton"].waitForExistence(timeout: 5), "The style sheet opens.")
            audit("Style sheet", in: app)
            app.buttons["doneStyleButton"].tap()
        }

        if everyScreen {
            let position = app.buttons["regionPositionButton"]
            reveal(position, in: app)
            position.tap()
            XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 5), "Position & size opens.")
            audit("Position & size", in: app)
            app.navigationBars["Position & size"].buttons["Done"].tap()
        }

        app.buttons["doneEditingRedactionsButton"].tap()
        let review = app.buttons["saveButton"]
        XCTAssertTrue(reveal(review, in: app))
        review.tap()
        let inspect = app.buttons["inspectFullImageButton"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 15), "The review opens.")
        XCTAssertTrue(app.buttons["shareCleanedImageButton"].waitForEnabled(timeout: 20), "The cleaned copy is ready.")
        audit("Review & Share", in: app)
        guard everyScreen else { return }
        if isLargestText {
            // Its lower half at this size: the save actions and what was removed.
            let list = app.collectionViews.firstMatch
            list.swipeUp()
            audit("Review & Share, scrolled", in: app)
            // XCTest calls a control behind the tall Share footer hittable, and
            // a tap there lands on Share: bring Inspect out from under it.
            let footer = app.buttons["shareCleanedImageButton"].frame.minY
            // Scrolled away, a lazy row is gone: drag down, toward it.
            for _ in 0..<6 where !inspect.exists || inspect.frame.maxY >= footer || inspect.frame.minY < list.frame.minY + 60 {
                let downwards = !inspect.exists || inspect.frame.minY < list.frame.minY + 60
                let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: downwards ? 0.25 : 0.5))
                from.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: downwards ? 0.45 : 0.3)),
                           withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            XCTAssertLessThan(inspect.frame.maxY, footer, "Inspect is above the footer.")
            inspect.tap()
            XCTAssertTrue(app.descendants(matching: .any)["fullReviewImage"].waitForExistence(timeout: 10))
            audit("Full preview", in: app)
            app.navigationBars["Final preview"].buttons["Done"].tap()
        }
        app.navigationBars["Review & Share"].buttons["Cancel"].tap()

        let dismiss = app.buttons["dismissPhotoButton"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertTrue(app.buttons["libraryButton"].waitForExistence(timeout: 10), "Back on the home screen.")
        audit("Home", in: app)

        app.buttons["infoButton"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        audit("About", in: app)
        app.navigationBars["About"].buttons["Done"].tap()

        app.buttons["alwaysCoverButton"].tap()
        XCTAssertTrue(app.textFields["alwaysCoverField"].waitForExistence(timeout: 5))
        audit("Always Cover", in: app)
    }

    /// Video mode, then — auditing every screen, at the largest size — the
    /// viewfinder; then a recording opened in the video editor, and with every
    /// screen the rest of the editor and, at the default size, Cover an Object.
    private func auditCameraAndVideo(_ app: XCUIApplication) throws {
        let everyScreen = Self.auditsEveryScreen
        let record = app.buttons["videoRecordButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 15), "The camera opens in Video mode.")
        audit("Video mode", in: app)

        if everyScreen, isLargestText {
            app.buttons["cameraMode-photo"].tap()
            let status = app.descendants(matching: .any)["liveCameraStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 15), "The viewfinder opens on the fixture.")
            let found = expectation(for: NSPredicate(format: "label CONTAINS 'Sensitive details in view'"), evaluatedWith: status)
            wait(for: [found], timeout: 20)
            XCTAssertTrue(app.descendants(matching: .any)["viewfinder"].exists, "VoiceOver can reach the viewfinder to zoom it.")
            audit("Viewfinder", in: app)
            app.buttons["cameraMode-video"].tap()
            XCTAssertTrue(record.waitForExistence(timeout: 15))
        }

        record.tap()
        XCTAssertTrue(app.descendants(matching: .any)["videoRecordingTimer"].waitForExistence(timeout: 5), "Recording starts.")
        Thread.sleep(forTimeInterval: 1)
        record.tap()
        let timeline = app.descendants(matching: .any)["coverTimelineTrack"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 90), "The recording opens in the video editor.")
        audit("Video editor", in: app)
        guard everyScreen else { return }

        let add = app.buttons["addCoverButton"]
        XCTAssertTrue(reveal(add, in: app), "Cover an Object can be reached.")
        audit("Video editor, scrolled", in: app)
        if !isLargestText {
            add.tap()
            XCTAssertTrue(app.descendants(matching: .any)["drawingArea"].waitForExistence(timeout: 60), "The paused frame appears.")
            app.buttons["addCenteredCoverButton"].tap()
            XCTAssertTrue(app.buttons["coverPositionButton"].waitForExistence(timeout: 5))
            audit("Cover an object", in: app)
        }
    }

    // MARK: - Launching

    /// Default size in light; the largest accessibility size in dark.
    private func launch(largestText: Bool, configure: (XCUIApplication) throws -> Void) rethrows -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largestText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
            ]
        }
        app.launchEnvironment["PICSTRIP_DISABLE_NAME_DETECTION"] = "1"
        try configure(app)
        appearance = largestText ? .dark : .light
        XCUIDevice.shared.appearance = appearance
        textSize = largestText ? "largest text" : "default text"
        isLargestText = largestText
        app.launch()
        return app
    }

    /// The camera on stand-ins: a still for Photo mode, a movie with a face,
    /// an email and sound for Video mode — and so for the recording.
    private func launchCamera(largestText: Bool, movie: String) throws -> XCUIApplication {
        let still = try stagedFixture("store_badge", "jpg")
        return launch(largestText: largestText) { app in
            app.launchEnvironment["PICSTRIP_LIVE_CAMERA_FIXTURE"] = still
            app.launchEnvironment["PICSTRIP_VIDEO_CAMERA_FIXTURE"] = movie
        }
    }

    // MARK: - Auditing

    /// Audits the screen in the launch's appearance — and, auditing every
    /// screen, in the other one too, so both sizes are seen in light and dark.
    private func audit(_ screen: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let other: XCUIDevice.Appearance = appearance == .dark ? .light : .dark
        for current in Self.auditsEveryScreen ? [appearance, other] : [appearance] {
            XCUIDevice.shared.appearance = current
            audit(screen, in: app, appearance: current, file: file, line: line)
        }
        XCUIDevice.shared.appearance = appearance
    }

    private func audit(
        _ screen: String, in app: XCUIApplication, appearance: XCUIDevice.Appearance, file: StaticString, line: UInt
    ) {
        // Let transitions finish: a control caught mid-animation reads as clipped.
        Thread.sleep(forTimeInterval: 0.6)
        let name = "\(screen) (\(textSize), \(appearance == .dark ? "dark" : "light"))"
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let types: XCUIAccessibilityAuditType = isLargestText ? .all : .all.subtracting([.dynamicType, .textClipped])
        navigationBarFrames = nil
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                if issue.auditType == .contrast {
                    // Recorded, not resolved: looking each element up costs more than the audit.
                    self.contrastFindings.append("\(name): \(issue.compactDescription)")
                    return true
                }
                // One snapshot per issue: each property of a live element is a query of its own.
                let element = try? issue.element?.snapshot()
                let description = Self.describe(issue, element)
                if let reason = self.acceptedReason(for: issue, element, on: screen, in: app) {
                    XCTContext.runActivity(named: "Accepted on \(name): \(description) — \(reason)") { _ in }
                } else {
                    XCTFail("\(name): \(description)", file: file, line: line)
                }
                return true
            }
        } catch {
            XCTFail("\(name): the audit could not run: \(error)", file: file, line: line)
        }
    }

    private static func describe(_ issue: XCUIAccessibilityAuditIssue, _ element: (any XCUIElementSnapshot)?) -> String {
        var text = "\(issue.compactDescription) [\(issue.detailedDescription)]"
        if let element {
            text += " — \(element.elementType) “\(element.label)”"
            if !element.identifier.isEmpty { text += " #\(element.identifier)" }
            text += " \(element.frame.integral)"
        }
        return text
    }

    /// Words over the photo that say how to use it: capped at Extra Extra Extra
    /// Large so they never cover it; VoiceOver reads them from the photo's hint.
    private static let photoHints: Set<String> = [
        "Pinch to zoom", "Double tap to reset", "Drag boxes to adjust", "Drag to redact", "Drag to redact, or tap an object"
    ]

    private static let cameraScreens: Set<String> = ["Viewfinder", "Video mode"]

    /// Screens presented as sheets, which on iPad float over the screen they
    /// came from.
    private static let sheetScreens: Set<String> = [
        "Style sheet", "Position & size", "Review & Share", "Review & Share, scrolled", "Cover an object"
    ]

    /// Reviewed findings that are not defects, each with why.  Everything else fails.
    private func acceptedReason(
        for issue: XCUIAccessibilityAuditIssue, _ element: (any XCUIElementSnapshot)?, on screen: String, in app: XCUIApplication
    ) -> String? {
        let isPartial = issue.compactDescription.localizedCaseInsensitiveContains("partially")
        switch issue.auditType {
        case .dynamicType where Self.cameraScreens.contains(screen):
            return "Camera controls keep their size, as in the Camera app, and show the Large Content Viewer; "
                + "the notes on the picture grow to Accessibility 1."
        case .dynamicType where isPartial && element.map({ isNavigationBarButton($0, in: app) }) == true:
            return "System bar buttons stop growing and show the Large Content Viewer on touch and hold."
        case .dynamicType where isPartial && Self.photoHints.contains(element?.label ?? ""):
            return "The gesture hint over the photo is capped so it never hides the photo; VoiceOver reads the photo's own hint."
        case .dynamicType where isPartial && element.map(Self.isCaptionVerifiedToGrow) == true:
            return "Caption 2 text the audit calls partly scaled; at this size it is drawn at Accessibility 5 (see the screenshot)."
        case .textClipped where element?.elementType == .textField:
            return "A single-line field scrolls what is typed sideways; its placeholder fits (see the screenshot)."
        case .textClipped where screen == "Viewfinder":
            return "Labels on the live picture are capped at 18 pt and 240 pt so they never cover what they mark; "
                + "the status names every finding in full, and VoiceOver announces it."
        case .textClipped where element.map({ isUnderNavigationBar($0, in: app) }) == true:
            return "Scrolled partly under the navigation bar; the audit counts the covered part as clipped."
        case .elementDetection where element == nil && UIDevice.current.userInterfaceIdiom == .pad
            && Self.sheetScreens.contains(screen):
            return "On iPad the sheet floats over the dimmed screen it came from; the audit reads that screen's text, "
                + "which VoiceOver rightly leaves out while the sheet is open."
        default:
            break
        }
        let isUIKitTitle = [.dynamicType, .textClipped].contains(issue.auditType) && element == nil
            && screen.hasPrefix("Review & Share") && !issue.detailedDescription.contains("SwiftUI")
        if isUIKitTitle {
            return "UIKit's navigation bar title, which keeps its size like every bar title (see the screenshot)."
        }
        return nil
    }

    /// Caption 2 text that the screenshots show growing to full size, though the
    /// audit reports it as partly scaled: the style names, and the count in the
    /// metadata panel's header.
    private static func isCaptionVerifiedToGrow(_ element: any XCUIElementSnapshot) -> Bool {
        let styles: Set<String> = ["Solid", "Crosshatch", "Pixelate", "Blur", "Emoji"]
        return element.elementType == .staticText
            && element.frame.height >= 26
            && (styles.contains(element.label) || element.label.hasSuffix(" found"))
    }

    private func isNavigationBarButton(_ element: any XCUIElementSnapshot, in app: XCUIApplication) -> Bool {
        guard element.elementType == .button else { return false }
        return barFrames(in: app).contains { $0.contains(element.frame) }
    }

    /// Content whose top has scrolled beneath a navigation bar.
    private func isUnderNavigationBar(_ element: any XCUIElementSnapshot, in app: XCUIApplication) -> Bool {
        barFrames(in: app).contains { bar in
            bar.intersects(element.frame) && element.frame.minY < bar.maxY && element.frame.maxY > bar.maxY
        }
    }

    private func barFrames(in app: XCUIApplication) -> [CGRect] {
        let bars = navigationBarFrames ?? app.navigationBars.allElementsBoundByIndex.map(\.frame)
        navigationBarFrames = bars
        return bars
    }

    // MARK: - Helpers

    /// Scrolls the scroll view or list holding `element` until it can be tapped.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<10 {
            if element.exists, element.isHittable { return true }
            let identifier = element.exists ? element.identifier : ""
            let containers = identifier.isEmpty ? [] : [
                app.scrollViews.containing(.any, identifier: identifier).firstMatch,
                app.collectionViews.containing(.any, identifier: identifier).firstMatch
            ]
            let container = containers.first { $0.exists } ?? app.collectionViews.firstMatch
            let scroller = container.exists ? container : app
            let isAbove = element.exists && element.frame.maxY < scroller.frame.midY
            // Along the trailing edge: the middle of the video editor's list is
            // its timeline, whose own drags would take the swipe.  Not too low
            // either: at the largest size a list's fixed footer button is tall.
            let low = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.6))
            let high = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.15))
            if isAbove {
                high.press(forDuration: 0.05, thenDragTo: low)
            } else {
                low.press(forDuration: 0.05, thenDragTo: high)
            }
        }
        return element.exists && element.isHittable
    }

    /// Copies a bundled fixture to the simulator's /tmp, where the app can read it.
    private func stagedFixture(_ name: String, _ ext: String) throws -> String {
        let source = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: ext), "\(name).\(ext) must be in the UI test bundle"
        )
        let path = "/tmp/picstrip_a11y_\(name).\(ext)"
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: path))
        return path
    }
}

private extension XCUIElement {
    /// Waits for a control to become enabled; `false` if it does not in time.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return exists && isEnabled
    }
}
