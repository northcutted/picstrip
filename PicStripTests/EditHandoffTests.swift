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
