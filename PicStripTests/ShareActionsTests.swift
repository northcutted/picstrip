import UserNotifications
import XCTest
@testable import PicStrip

// MARK: - Notification

/// The "Ready to Edit" notification an extension posts after handing an item
/// to the app.  It can show on a locked screen, so it must say nothing about
/// the item.
final class EditHandoffNotificationTests: XCTestCase {

    private let expires = Date(timeIntervalSince1970: 1_800_000_000)

    func testThePhotoNotificationNamesNothingAboutThePhoto() {
        let content = EditHandoffNotification.content(isVideo: false, expires: expires)
        XCTAssertEqual(content.title, "Ready to Edit")
        XCTAssertEqual(content.body, "Tap to open your photo in PicStrip.")
        assertCarriesNothingButTheExpiry(content)
    }

    func testTheVideoNotificationNamesNothingAboutTheVideo() {
        let content = EditHandoffNotification.content(isVideo: true, expires: expires)
        XCTAssertEqual(content.title, "Ready to Edit")
        XCTAssertEqual(content.body, "Tap to open your video in PicStrip.")
        assertCarriesNothingButTheExpiry(content)
    }

    private func assertCarriesNothingButTheExpiry(_ content: UNMutableNotificationContent, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(content.attachments.isEmpty, "No thumbnail.", file: file, line: line)
        XCTAssertEqual(content.subtitle, "", file: file, line: line)
        XCTAssertEqual(content.threadIdentifier, "", file: file, line: line)
        XCTAssertNil(content.targetContentIdentifier, file: file, line: line)
        XCTAssertEqual(content.userInfo.count, 1, "Only when the handoff expires: no file name or path.", file: file, line: line)
        XCTAssertEqual(EditHandoffNotification.expiry(of: content.userInfo), expires, file: file, line: line)
    }

    /// The expiry tells a tap on a notification whose item has gone from one
    /// the app already opened.
    func testATapAfterTheHandoffExpiredIsRecognised() {
        XCTAssertFalse(EditHandoffNotification.hasExpired(expires, now: expires.addingTimeInterval(-1)))
        XCTAssertTrue(EditHandoffNotification.hasExpired(expires, now: expires))
        XCTAssertTrue(EditHandoffNotification.hasExpired(expires, now: expires.addingTimeInterval(60)))
        XCTAssertFalse(EditHandoffNotification.hasExpired(nil), "Without an expiry the app just looks for the handoff.")
        XCTAssertNil(EditHandoffNotification.expiry(of: [:]))
    }
}

// MARK: - Drain

/// The app takes what an extension left and keeps the notification from
/// outliving it.
final class EditHandoffDrainTests: XCTestCase {

    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    private func store(lifetime: TimeInterval = 900) -> PrivateFileStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return PrivateFileStore(directory: folder, lifetime: lifetime, maximumBytes: 1_024)
    }

    func testTakingAHandoffWithdrawsItsNotification() throws {
        let handoffs = store()
        let now = Date()
        _ = try handoffs.write(Data("photo".utf8), extension: "data", now: now)
        var withdrawals = 0

        let taken = EditHandoff.take(from: handoffs, movingVideosTo: store(lifetime: 3_600), now: now) { withdrawals += 1 }

        XCTAssertEqual(taken, .image(Data("photo".utf8)))
        XCTAssertEqual(withdrawals, 1)
        XCTAssertTrue(handoffs.isEmpty, "Consumed: nothing is left in the App Group.")
    }

    func testTheNotificationIsWithdrawnWhenNothingIsLeft() {
        var withdrawals = 0
        XCTAssertNil(EditHandoff.take(from: store(), now: Date()) { withdrawals += 1 })
        XCTAssertEqual(withdrawals, 1, "A notification for an item that is gone leads nowhere.")
    }

    func testAnExpiredHandoffTakesItsNotificationWithIt() throws {
        let handoffs = store(lifetime: 10)
        let now = Date()
        _ = try handoffs.write(Data("photo".utf8), extension: "data", now: now)
        var withdrawals = 0

        EditHandoff.removeExpired(from: handoffs, now: now.addingTimeInterval(5)) { withdrawals += 1 }
        XCTAssertEqual(withdrawals, 0, "Still waiting to be opened.")
        XCTAssertFalse(handoffs.isEmpty)

        EditHandoff.removeExpired(from: handoffs, now: now.addingTimeInterval(11)) { withdrawals += 1 }
        XCTAssertEqual(withdrawals, 1)
        XCTAssertTrue(handoffs.isEmpty)

        XCTAssertNil(EditHandoff.take(from: handoffs, now: now.addingTimeInterval(11)) { withdrawals += 1 })
        XCTAssertEqual(withdrawals, 2)
    }

    func testWithoutTheAppGroupNothingIsWithdrawn() {
        var withdrawals = 0
        XCTAssertNil(EditHandoff.take(from: nil) { withdrawals += 1 })
        EditHandoff.removeExpired(from: nil) { withdrawals += 1 }
        XCTAssertEqual(withdrawals, 0)
    }
}

// MARK: - Action extensions

/// "Strip Metadata" and "Edit in PicStrip": their own rows in the share
/// sheet's action list, checked in the bundles the app embeds.
final class ShareActionExtensionTests: XCTestCase {

    private func plugIn(_ name: String) throws -> Bundle {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        return try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent("\(name).appex")), "The app should embed \(name).")
    }

    private func extensionInfo(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try plugIn(name).infoDictionary?["NSExtension"] as? [String: Any])
    }

    private func activationRule(_ name: String) throws -> NSPredicate {
        let attributes = try XCTUnwrap(try extensionInfo(name)["NSExtensionAttributes"] as? [String: Any])
        return NSPredicate(format: try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String))
    }

    private func offered(by name: String, _ attachments: [[String]], itemsEach: Bool = false) throws -> Bool {
        let wrapped = attachments.map { ["registeredTypeIdentifiers": $0] }
        let items: [[String: Any]] = itemsEach ? wrapped.map { ["attachments": [$0]] } : [["attachments": wrapped]]
        return try activationRule(name).evaluate(with: ["extensionItems": items])
    }

    private let livePhoto = ["public.heic", "com.apple.quicktime-movie", "com.apple.live-photo"]
    private let movie = ["com.apple.quicktime-movie"]

    func testBothActionsAreEmbeddedAsActionExtensions() throws {
        for (name, identifier, title) in [
            ("StripMetadataAction", "com.northcutt.PicStrip.StripMetadata", "Strip Metadata"),
            ("EditInPicStripAction", "com.northcutt.PicStrip.EditInPicStrip", "Edit in PicStrip")
        ] {
            let bundle = try plugIn(name)
            XCTAssertEqual(bundle.bundleIdentifier, identifier)
            XCTAssertEqual(bundle.infoDictionary?["CFBundleDisplayName"] as? String, title)
            XCTAssertEqual(bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                           Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, "Versions follow the app.")
            let info = try extensionInfo(name)
            XCTAssertEqual(info["NSExtensionPointIdentifier"] as? String, "com.apple.ui-services", "An action, listed apart from share targets.")
            XCTAssertEqual(info["NSExtensionPrincipalClass"] as? String, "\(name).ActionViewController")

            let privacyURL = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
            let privacy = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: privacyURL), format: nil) as? [String: Any])
            XCTAssertEqual(privacy["NSPrivacyTracking"] as? Bool, false)
            XCTAssertNotNil(privacy["NSPrivacyAccessedAPITypes"], "The release check requires the declared API reasons.")
        }
    }

    /// Only Strip Metadata saves to Photos, so only it asks.
    func testOnlyStripMetadataAsksToAddToPhotos() throws {
        let share = try plugIn("PicStripShareExtension").infoDictionary?["NSPhotoLibraryAddUsageDescription"] as? String
        XCTAssertNotNil(share)
        XCTAssertEqual(try plugIn("StripMetadataAction").infoDictionary?["NSPhotoLibraryAddUsageDescription"] as? String, share)
        XCTAssertNil(try plugIn("EditInPicStripAction").infoDictionary?["NSPhotoLibraryAddUsageDescription"])
    }

    /// The share extension's limits: any number of photos, ten videos, Live
    /// Photos counted as photos.
    func testStripMetadataTakesWhatTheShareExtensionTakes() throws {
        let name = "StripMetadataAction"
        XCTAssertTrue(try offered(by: name, [["public.jpeg"]]))
        XCTAssertTrue(try offered(by: name, Array(repeating: ["public.heic"], count: 40)))
        XCTAssertTrue(try offered(by: name, [["public.heic"], ["public.mpeg-4"]]))
        XCTAssertTrue(try offered(by: name, Array(repeating: movie, count: 10)))
        XCTAssertFalse(try offered(by: name, Array(repeating: movie, count: 11)))
        XCTAssertTrue(try offered(by: name, Array(repeating: movie, count: 10), itemsEach: true))
        XCTAssertFalse(try offered(by: name, Array(repeating: movie, count: 11), itemsEach: true))
        XCTAssertTrue(try offered(by: name, Array(repeating: livePhoto, count: 20)))
        XCTAssertFalse(try offered(by: name, [["public.url"]]))
        XCTAssertFalse(try offered(by: name, [["public.plain-text"], ["com.adobe.pdf"]]))
    }

    /// The editor and the video cleaner open one item, so the action is only
    /// offered for exactly one photo or video, however the host groups them.
    func testEditInPicStripTakesExactlyOnePhotoOrVideo() throws {
        let name = "EditInPicStripAction"
        XCTAssertTrue(try offered(by: name, [["public.jpeg"]]))
        XCTAssertTrue(try offered(by: name, [movie]))
        XCTAssertTrue(try offered(by: name, [livePhoto]), "A Live Photo is one photo.")
        XCTAssertTrue(try offered(by: name, [["public.heic"], ["public.url"]]), "Other attachments are not photos or videos.")
        XCTAssertFalse(try offered(by: name, [["public.heic"], ["public.jpeg"]]))
        XCTAssertFalse(try offered(by: name, [["public.heic"], movie]))
        XCTAssertFalse(try offered(by: name, [["public.heic"], ["public.jpeg"]], itemsEach: true))
        XCTAssertFalse(try offered(by: name, [movie, movie], itemsEach: true))
        XCTAssertFalse(try offered(by: name, [["public.url"]]))
        XCTAssertFalse(try offered(by: name, []))
    }
}
