import os
@testable import PicStrip
import UIKit
import XCTest

/// The scan's progress bar is only honest if it is built from work that has
/// actually finished, and if nothing that could run alongside the scan waits
/// behind it.
@MainActor
final class ScanProgressTests: XCTestCase {

    // MARK: - ScanProgress

    func testProgressOnlyMovesForwardAndNeverCountsAStepTwice() {
        var progress = ScanProgress.started
        progress.record(.analysed(.faces))
        let afterFaces = progress.fraction
        XCTAssertGreaterThan(afterFaces, ScanProgress.started.fraction)

        progress.record(.analysed(.faces))
        XCTAssertEqual(progress.fraction, afterFaces, "The fast-text fallback repeats a step; it must not count twice.")

        progress.record(.analysed(.barcodes))
        progress.record(.analysed(.documentEdges))
        progress.record(.analysed(.text))
        XCTAssertEqual(progress.stage, .analysing)
        XCTAssertGreaterThan(progress.fraction, afterFaces)
        XCTAssertLessThan(progress.fraction, ScanProgress.matchingFraction, "Vision alone never reaches the matching mark.")

        progress.record(.matchingPatterns)
        XCTAssertEqual(progress.stage, .matching)
        XCTAssertEqual(progress.fraction, ScanProgress.matchingFraction)
        XCTAssertLessThan(progress.fraction, ScanProgress.finished.fraction, "Only a published scan is complete.")
    }

    func testEveryVisionRequestFitsBelowTheMatchingMark() {
        let vision = ScanStep.Subject.allCases.map(ScanProgress.weight(of:)).reduce(0, +)
        XCTAssertLessThanOrEqual(ScanProgress.started.fraction + vision, ScanProgress.matchingFraction)
        XCTAssertGreaterThan(
            ScanProgress.weight(of: .text), 0.5,
            "Reading text is most of the wait, so it should be most of the bar."
        )
    }

    // MARK: - Scanner

    /// The real scanner reports each Vision request once — whether it found
    /// anything, or failed, as face and barcode detection do on the simulator —
    /// and says when it moves on to pattern matching.
    func testScannerReportsEachRequestOnceThenPatternMatching() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let steps = OSAllocatedUnfairLock(initialState: [ScanStep]())

        _ = try await PIIScanner().scan(data: try Data(contentsOf: url)) { step in
            steps.withLock { $0.append(step) }
        }

        let reported = steps.withLock { $0 }
        XCTAssertEqual(reported.last, .matchingPatterns)
        XCTAssertTrue(reported.contains(.analysed(.text)))
        let analysed = reported.filter { $0 != .matchingPatterns }
        XCTAssertEqual(analysed.count, ScanStep.Subject.allCases.count, "\(reported)")
        XCTAssertEqual(Set(analysed.map(String.init(describing:))).count, analysed.count, "A request was reported twice: \(reported)")
    }

    // MARK: - View model

    /// Metadata is cheap to read and the scan is not: the badges must be there
    /// while the scan is still running, with the bar showing what has finished.
    func testMetadataIsPublishedAndProgressAdvancesWhileTheScanIsStillRunning() async throws {
        let gate = Gate()
        let viewModel = ScrubberViewModel(
            scan: { _, _, progress in
                progress?(.analysed(.faces))
                progress?(.analysed(.text))
                await gate.wait()
                progress?(.matchingPatterns)
                return ScanOutput(results: [], lines: [])
            },
            semantic: .unavailable,
            objectSelection: .unsupported
        )

        await viewModel.loadData(try XCTUnwrap(sampleImage().jpegData(compressionQuality: 0.8)))
        XCTAssertTrue(viewModel.isScanningPII)
        XCTAssertFalse(viewModel.isProcessing, "The photo is on screen; only the scan is outstanding.")
        XCTAssertNotNil(viewModel.sourceUIImage)
        XCTAssertNotNil(viewModel.allSourceMetadata, "Metadata must not wait for the scan.")

        let expected = ScanProgress.started.fraction
            + ScanProgress.weight(of: .faces) + ScanProgress.weight(of: .text)
        try await waitUntil { abs(viewModel.scanProgress.fraction - expected) < 0.0001 }
        XCTAssertEqual(viewModel.scanProgress.stage, .analysing)

        await gate.open()
        try await waitUntil { !viewModel.isScanningPII }
        XCTAssertEqual(viewModel.scanProgress, .finished)
    }

    /// A new photo starts a new bar, and a late report from the scan it replaced
    /// must not move it.
    func testLoadingAnotherPhotoRestartsTheProgress() async throws {
        let gate = Gate()
        let reporters = OSAllocatedUnfairLock(initialState: [ScanProgressHandler]())
        let viewModel = ScrubberViewModel(
            scan: { _, _, progress in
                if let progress { reporters.withLock { $0.append(progress) } }
                await gate.wait()
                return ScanOutput(results: [], lines: [])
            },
            semantic: .unavailable,
            objectSelection: .unsupported
        )
        let data = try XCTUnwrap(sampleImage().jpegData(compressionQuality: 0.8))

        await viewModel.loadData(data)
        let first = try XCTUnwrap(reporters.withLock { $0.first })
        first(.analysed(.text))
        try await waitUntil { viewModel.scanProgress.fraction > 0.5 }

        await viewModel.loadData(data)
        XCTAssertEqual(viewModel.scanProgress, .started)
        first(.analysed(.faces))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.scanProgress, .started, "The replaced scan reported into the new photo's bar.")

        await gate.open()
        try await waitUntil { !viewModel.isScanningPII }
    }

    /// Names arrive after the scan is published; the UI says so only while the
    /// model is actually working, and only when there is a model.
    func testFindingNamesIsFlaggedOnlyWhileTheModelIsWorking() async throws {
        let gate = Gate()
        let line = ScannedLine(text: "Call bob", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1), confidence: 1)
        let viewModel = ScrubberViewModel(
            scan: { _, _, _ in ScanOutput(results: [], lines: [line]) },
            semantic: SemanticPII(findNames: { _ in
                await gate.wait()
                return []
            }),
            objectSelection: .unsupported
        )
        let data = try XCTUnwrap(sampleImage().jpegData(compressionQuality: 0.8))

        await viewModel.loadData(data)
        try await waitUntil { !viewModel.isScanningPII }
        XCTAssertTrue(viewModel.isFindingNames)
        await gate.open()
        try await waitUntil { !viewModel.isFindingNames }

        let withoutModel = ScrubberViewModel(
            scan: { _, _, _ in ScanOutput(results: [], lines: [line]) },
            semantic: .unavailable,
            objectSelection: .unsupported
        )
        await withoutModel.loadData(data)
        try await waitUntil { !withoutModel.isScanningPII }
        XCTAssertFalse(withoutModel.isFindingNames, "No model, no \"Looking for names\".")
    }

    // MARK: - Helpers

    private func sampleImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for the view model.")
    }
}

/// Holds an injected scan or model back until the test lets it through.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
