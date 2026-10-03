import AVFoundation
import XCTest
@testable import PicStrip

/// The video editor's model, driven as the screen drives it.
@MainActor
final class VideoEditorModelTests: XCTestCase {

    private var cleanup: [URL] = []
    private var models: [VideoCleanerModel] = []

    override func tearDown() async throws {
        models.forEach { $0.discard() }
        models = []
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanup = []
        try await super.tearDown()
    }

    /// The editor opened on `url`, past the scan.
    private func openEditor(on url: URL) async throws -> VideoCleanerModel {
        try skipUnlessVisionModelsRunHere()
        let model = VideoCleanerModel()
        models.append(model)
        await model.start(.file(url))
        XCTAssertEqual(model.stage, .review)
        return model
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testTheEditorOpensWithTheSoundsLevelsAndTheWholeFilmstrip() async throws {
        let movie = try await SoundMovie.make(seconds: 12)
        cleanup.append(movie)
        let model = try await openEditor(on: movie)
        XCTAssertTrue(model.hasAudio)
        XCTAssertEqual(model.audioLevels.count, VideoCleanerModel.levelCount(for: model.duration))
        XCTAssertGreaterThanOrEqual(model.filmstrip.count, 10, "A first look at the video, at least, as it opens.")
        // A frame about every second follows.
        let whole = VideoCleanerModel.filmstripCount(for: model.duration)
        XCTAssertGreaterThan(whole, 10)
        try await waitUntil { model.filmstrip.count == whole }
    }

    func testEachFaceHasAThumbnail() async throws {
        let movie = try await FaceMovie.make(face: "🧑🏽", fontSize: 220)
        cleanup.append(movie.url)
        let model = try await openEditor(on: movie.url)
        XCTAssertFalse(model.faces.isEmpty, "Vision found the face.")
        for face in model.faces {
            let thumbnail = try XCTUnwrap(model.faceThumbnails[face.id], "Face \(face.id)")
            let box = try XCTUnwrap(face.representativeSample).box
            XCTAssertEqual(thumbnail.size.width, FaceTracking.padded(box).width * movie.displaySize.width, accuracy: 4)
        }
        XCTAssertFalse(model.hasAudio, "No sound, no audio lane.")
        XCTAssertEqual(model.filmstrip.count, 10)
    }
}
