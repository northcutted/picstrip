import UIKit
import XCTest
@testable import PicStrip

// MARK: - The gate

final class ReviewPromptGateTests: XCTestCase {

    /// Records `events` in order on a fresh gate; what each one answered.
    private func answers(_ events: [ReviewPromptGate.Event]) -> [Bool] {
        var gate = ReviewPromptGate()
        return events.map { gate.record($0) }
    }

    func testAFirstSuccessAloneNeverAsks() {
        XCTAssertEqual(answers([.saved]), [false])
        XCTAssertEqual(answers([.scanned, .saved]), [false, false], "One photo, scanned and saved, is not enough.")
    }

    func testTheSecondCleanSuccessAsks() {
        XCTAssertEqual(answers([.saved, .saved]), [false, true])
        XCTAssertEqual(answers([.scanned, .saved, .scanned, .saved]), [false, false, false, true])
    }

    func testASuccessAfterASecondItemWasScannedAsks() {
        // A photo shared (which PicStrip cannot see finish), then another saved.
        XCTAssertEqual(answers([.scanned, .scanned, .saved]), [false, false, true])
    }

    func testScansAloneNeverAsk() {
        XCTAssertEqual(answers(Array(repeating: .scanned, count: 5)), Array(repeating: false, count: 5))
    }

    func testABatchThatSavedSeveralItemsAsks() {
        XCTAssertEqual(answers([.batchSaved(items: 2)]), [true])
        XCTAssertEqual(answers([.batchSaved(items: 1)]), [false])
        XCTAssertEqual(answers([.batchSaved(items: 0), .saved]), [false, false], "An empty batch is no success.")
    }

    func testNeverRightAfterASetback() {
        XCTAssertEqual(answers([.scanned, .scanned, .setback, .saved]), [false, false, false, false])
        XCTAssertEqual(answers([.saved, .setback, .saved]), [false, false, false])
        XCTAssertEqual(answers([.batchSaved(items: 1), .setback, .batchSaved(items: 1)]), [false, false, false])
    }

    func testASetbackStartsBothCountsAgain() {
        var gate = ReviewPromptGate()
        _ = gate.record(.scanned)
        _ = gate.record(.saved)
        _ = gate.record(.setback)
        XCTAssertEqual(gate.successes, 0)
        XCTAssertEqual(gate.items, 0)
        XCTAssertFalse(gate.record(.saved))
        XCTAssertTrue(gate.record(.saved), "Two fresh clean successes after it.")
    }

    func testOpensAtMostOncePerSession() {
        XCTAssertEqual(
            answers([.saved, .saved, .saved, .scanned, .scanned, .saved, .batchSaved(items: 5)]),
            [false, true, false, false, false, false, false]
        )
    }

    func testEveryLaunchStartsShut() {
        let gate = ReviewPromptGate()
        XCTAssertEqual(gate.successes, 0)
        XCTAssertEqual(gate.items, 0)
        XCTAssertFalse(gate.hasOpened)
    }
}

// MARK: - The session's request

@MainActor
final class ReviewPromptTests: XCTestCase {

    func testFallsDueOnceAndIsClearedWhenMade() {
        let prompt = ReviewPrompt()
        prompt.record(.saved)
        XCTAssertFalse(prompt.isDue)
        prompt.record(.saved)
        XCTAssertTrue(prompt.isDue)
        prompt.requested()
        XCTAssertFalse(prompt.isDue)
        prompt.record(.saved)
        prompt.record(.batchSaved(items: 3))
        XCTAssertFalse(prompt.isDue, "One request a session.")
    }
}
