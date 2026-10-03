import UIKit
import XCTest
@testable import PicStrip

// MARK: - Routing a library pick

final class LibrarySelectionTests: XCTestCase {

    private func route(_ picks: [(String, Bool)]) -> LibrarySelection<String>.Route {
        LibrarySelection(picks.map { (item: $0.0, isVideo: $0.1) }).route
    }

    func testEachPickGoesToItsFlow() {
        guard case .photo("a") = route([("a", false)]) else { return XCTFail("One photo: the editor.") }
        guard case .video("v") = route([("v", true)]) else { return XCTFail("One video: the video cleaner.") }
        guard case .photoBatch(let photos) = route([("a", false), ("b", false)]) else {
            return XCTFail("Several photos: the photo batch.")
        }
        XCTAssertEqual(photos, ["a", "b"])
    }

    func testVideosTogetherOrWithPhotosMakeOneBatch() {
        guard case .mixedBatch(let photos, let videos) = route([("v1", true), ("v2", true)]) else {
            return XCTFail("Several videos: one batch.")
        }
        XCTAssertEqual(photos, [])
        XCTAssertEqual(videos, ["v1", "v2"])

        guard case .mixedBatch(let mixedPhotos, let mixedVideos) = route([("a", false), ("v", true)]) else {
            return XCTFail("A photo and a video: one batch for both, not the single photo flow.")
        }
        XCTAssertEqual(mixedPhotos, ["a"])
        XCTAssertEqual(mixedVideos, ["v"])
    }

    func testPicksKeepTheirOrderWithinEachKind() {
        let selection = LibrarySelection([("b", false), ("v2", true), ("a", false), ("v1", true)].map { (item: $0.0, isVideo: $0.1) })
        XCTAssertEqual(selection.photos, ["b", "a"])
        XCTAssertEqual(selection.videos, ["v2", "v1"])
    }
}

// MARK: - A batch with videos

@MainActor
final class VideoBatchTests: XCTestCase {

    private func temporaryFile() throws -> URL {
        let url = try PrivateFileStore.exports.reserve(extension: "mov")
        try Data("movie".utf8).write(to: url)
        return url
    }

    private func report(faces: Int) -> AuditReport {
        AuditReport(
            scanDate: Date(), formatSelected: "MOV (HEVC)",
            visualRedactions: VideoBatchCleaner.redactions(faces: faces, groups: []),
            metadataStripped: [MetadataCategoryReport(category: "Location", strippedFields: [])]
        )
    }

    func testVideosFailClosedAndTheirFilesGo() async throws {
        let viewModel = ScrubberViewModel(scanImage: { _ in [] })
        let unreadable = VideoBatchSource(assetIdentifier: nil) { nil }
        let failing = try temporaryFile()
        let good = try temporaryFile()
        let cleanedCopy = try temporaryFile()
        let sources = [
            unreadable,
            VideoBatchSource(assetIdentifier: "fails") { failing },
            VideoBatchSource(assetIdentifier: "good") { good }
        ]
        let saved = SavedVideos()
        let expectedReport = report(faces: 2)

        await viewModel.runVideoBatch(sources: sources, config: BatchConfig()) { url, identifier, mode in
            await saved.append(identifier, mode: mode, exists: FileManager.default.fileExists(atPath: url.path))
            return .saved
        } clean: { url, covering, _, progress in
            XCTAssertTrue(covering, "Covering follows “Redact Sensitive Visual Data”.")
            progress(0.5)
            if url == failing { throw CancellationError() }
            return VideoBatchCleaner.Result(url: cleanedCopy, report: expectedReport)
        }

        XCTAssertEqual(viewModel.batchSucceededCount, 1)
        XCTAssertEqual(viewModel.batchFailedCount, 2, "Unreadable and failed videos are counted, never saved.")
        XCTAssertEqual(viewModel.batchErrorMessage, String(localized: "Some photos or videos could not be cleaned and were not saved."))
        XCTAssertTrue(viewModel.batchComplete)
        XCTAssertNil(viewModel.batchVideoFraction)
        XCTAssertEqual(viewModel.batchReports.first?.visualRedactions.first?.instanceCount, 2)
        let writes = await saved.all
        XCTAssertEqual(writes.map(\.identifier), ["good"])
        XCTAssertTrue(writes.first?.exists ?? false, "The cleaned copy exists when it is saved…")
        for url in [failing, good, cleanedCopy] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "…and every temporary file is gone after.")
        }
    }

    func testVideosFollowThePhotosInOneBatch() async throws {
        let viewModel = ScrubberViewModel(scanImage: { _ in [] })
        var config = BatchConfig()
        config.redactVisualPII = false
        let photo = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        await viewModel.runBatch(
            sources: [BatchSource(assetIdentifier: nil) { photo }],
            config: config, save: { _, _, _ in .saved }, total: 2, finishes: false
        )
        XCTAssertFalse(viewModel.batchComplete, "The videos are still to come.")
        XCTAssertTrue(viewModel.isBatchProcessing)
        XCTAssertEqual(viewModel.batchProgress.total, 2)

        let video = try temporaryFile()
        let copy = try temporaryFile()
        let expectedReport = report(faces: 0)
        var progress: [Int] = []
        await viewModel.runVideoBatch(
            sources: [VideoBatchSource(assetIdentifier: nil) { video }],
            config: config, offset: 1, total: 2
        ) { _, _, _ in
            .saved
        } clean: { _, covering, _, _ in
            XCTAssertFalse(covering)
            return VideoBatchCleaner.Result(url: copy, report: expectedReport)
        }
        progress.append(viewModel.batchProgress.current)

        XCTAssertEqual(progress, [2], "The video counts on from the photo.")
        XCTAssertEqual(viewModel.batchSucceededCount, 2, "Photo and video reports together.")
        XCTAssertTrue(viewModel.batchComplete)
        XCTAssertNil(viewModel.batchErrorMessage)
    }

    func testAReportListsFacesThenEachKindOfText() {
        let rows = VideoBatchCleaner.redactions(faces: 3, groups: [])
        XCTAssertEqual(rows.map(\.instanceCount), [3])
        XCTAssertTrue(VideoBatchCleaner.redactions(faces: 0, groups: []).isEmpty)
    }
}

private actor SavedVideos {
    struct Write {
        let identifier: String?
        let mode: BatchSaveMode
        let exists: Bool
    }

    private(set) var all: [Write] = []

    func append(_ identifier: String?, mode: BatchSaveMode, exists: Bool) {
        all.append(Write(identifier: identifier, mode: mode, exists: exists))
    }
}
