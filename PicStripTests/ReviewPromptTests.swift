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

    // MARK: Wiring in the view model

    private func photo() throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private var metadataOnly: BatchConfig {
        var config = BatchConfig()
        config.redactVisualPII = false
        return config
    }

    func testABatchThatSavedEverythingAsks() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        let photo = try photo()
        await model.runBatch(
            sources: [BatchSource(assetIdentifier: nil) { photo }, BatchSource(assetIdentifier: nil) { photo }],
            config: metadataOnly
        ) { _, _, _ in .saved }

        XCTAssertNil(model.batchErrorMessage)
        XCTAssertTrue(model.reviewPrompt.isDue)
    }

    func testABatchThatLostAnItemNeverAsks() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        let photo = try photo()
        model.reviewPrompt.record(.scanned)
        model.reviewPrompt.record(.scanned)
        await model.runBatch(
            sources: [BatchSource(assetIdentifier: nil) { photo }, BatchSource(assetIdentifier: nil) { nil }],
            config: metadataOnly
        ) { _, _, _ in .saved }

        XCTAssertNotNil(model.batchErrorMessage)
        XCTAssertFalse(model.reviewPrompt.isDue)
        XCTAssertEqual(model.reviewPrompt.gate.items, 0, "The failure starts the count again.")
    }

    func testAPhotoScannedInFullCountsButTheSampleDoesNot() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        await model.loadData(try photo())
        try await settle { model.inputImage != nil && !model.isScanningPII }
        XCTAssertEqual(model.reviewPrompt.gate.items, 1)

        await model.loadDemo()
        try await settle { model.isDemo && model.inputImage != nil && !model.isScanningPII }
        XCTAssertEqual(model.reviewPrompt.gate.items, 1, "The fictional sample is not a photo worked on.")
    }

    func testAnIncompleteScanIsASetback() async throws {
        var partial = ScanCoverage.complete
        partial[.faces] = .failed
        let coverage = partial
        let model = ScrubberViewModel(scan: { _, _, _ in ScanOutput(results: [], lines: [], coverage: coverage) })
        model.reviewPrompt.record(.scanned)
        model.reviewPrompt.record(.saved)
        await model.loadData(try photo())
        try await settle { model.inputImage != nil && !model.isScanningPII }

        XCTAssertEqual(model.reviewPrompt.gate.items, 0)
        XCTAssertEqual(model.reviewPrompt.gate.successes, 0)
    }

    func testAnErrorIsASetback() {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        model.reviewPrompt.record(.scanned)
        model.reviewPrompt.record(.saved)
        model.errorMessage = "Could not save to Photos."
        XCTAssertEqual(model.reviewPrompt.gate.successes, 0)
        XCTAssertEqual(model.reviewPrompt.gate.items, 0)
        model.errorMessage = nil
        XCTAssertEqual(model.reviewPrompt.gate.items, 0, "Clearing the message is not an event.")
    }

    func testASavedConfirmationIsASuccessUnlessTheScanWasIncomplete() {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        // No scan has run, so its required checks are incomplete: saving past
        // that is a warning, not a clean success.
        XCTAssertTrue(model.scanCoverage.requiresManualReview)
        model.reviewPrompt.record(.saved)
        model.savedConfirmation = .init(summary: .init(), replacedOriginal: false)
        XCTAssertEqual(model.reviewPrompt.gate.successes, 0)
        XCTAssertFalse(model.reviewPrompt.isDue)
    }

    func testASavedPhotoAfterAFullScanIsASuccess() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        await model.loadData(try photo())
        try await settle { model.inputImage != nil && !model.isScanningPII }
        model.savedConfirmation = .init(summary: .init(), replacedOriginal: false)
        XCTAssertEqual(model.reviewPrompt.gate.successes, 1)
        XCTAssertFalse(model.reviewPrompt.isDue, "One photo scanned and saved is not enough.")

        await model.loadData(try photo())
        try await settle { model.inputImage != nil && !model.isScanningPII }
        model.savedConfirmation = .init(summary: .init(), replacedOriginal: false)
        XCTAssertTrue(model.reviewPrompt.isDue)
    }
}
