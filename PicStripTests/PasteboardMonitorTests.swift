import os
import XCTest
@testable import PicStrip

@MainActor
final class PasteboardMonitorTests: XCTestCase {

    func testStartsHiddenUntilFirstRefresh() async {
        let monitor = PasteboardMonitor(probe: { true })
        XCTAssertFalse(monitor.hasImage, "Nothing may be shown before the pasteboard has been checked.")
    }

    func testRefreshFollowsTheProbe() async {
        let holdsImage = OSAllocatedUnfairLock(initialState: false)
        let monitor = PasteboardMonitor(probe: { holdsImage.withLock { $0 } })

        await monitor.refresh()
        XCTAssertFalse(monitor.hasImage)

        holdsImage.withLock { $0 = true }
        await monitor.refresh()
        XCTAssertTrue(monitor.hasImage, "An image was copied — Paste must be offered.")

        holdsImage.withLock { $0 = false }
        await monitor.refresh()
        XCTAssertFalse(monitor.hasImage, "The image was replaced by something else — Paste must go away.")
    }
}
