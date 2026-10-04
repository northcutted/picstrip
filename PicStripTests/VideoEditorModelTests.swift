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

    func testTheTimelinesClipsFollowTheCovers() async throws {
        let movie = try await FaceMovie.make(face: "🧑🏽", fontSize: 220)
        cleanup.append(movie.url)
        let model = try await openEditor(on: movie.url)
        let face = try XCTUnwrap(model.faces.first, "Vision found the face.")
        func clip(_ id: String) -> EditorTimeline.Clip? { model.timelineClips.first { $0.id == id } }

        XCTAssertEqual(clip("face-\(face.id)")?.range, model.range(of: face))
        XCTAssertEqual(clip("face-\(face.id)")?.lane, .faces)
        model.setRange(0.5...1.2, for: face)
        XCTAssertEqual(clip("face-\(face.id)")?.range, 0.5...1.2, "A new timing moves the clip.")
        model.setVisible(true, for: face)
        XCTAssertNil(clip("face-\(face.id)"), "A face left visible has no clip.")
        model.setVisible(false, for: face)
        model.coversFaces = false
        XCTAssertNil(clip("face-\(face.id)"), "Nor do faces when none are covered.")
        model.coversFaces = true
        XCTAssertNotNil(clip("face-\(face.id)"))

        model.addAudioEdit(.mute, over: 0.2...0.6)
        let edit = try XCTUnwrap(model.audioEdits.first)
        XCTAssertEqual(clip("audio-\(edit.id)")?.range, 0.2...0.6)
        model.setKind(.bleep, of: edit)
        XCTAssertEqual(clip("audio-\(edit.id)")?.label, String(localized: "Bleep"))
        model.deleteAudioEdit(edit)
        XCTAssertNil(clip("audio-\(edit.id)"))
    }

    func testThePlayheadIsWhereThePreviewWasMoved() async throws {
        let movie = try await SoundMovie.make(seconds: 2)
        cleanup.append(movie)
        let model = try await openEditor(on: movie)
        model.scrub(to: 1.2)
        XCTAssertEqual(model.playhead.time, 1.2)
        XCTAssertEqual(model.currentTime, 1.2)
        model.scrub(to: 9)
        XCTAssertEqual(model.currentTime, model.duration, accuracy: 0.001, "Within the video.")

        // Dragged: the playhead stays under the finger, and the preview lands
        // exactly where it is let go.
        try await waitUntil { model.player.currentItem?.status == .readyToPlay }
        for step in 1...10 { model.scrub(to: Double(step) * 0.15, dragging: true) }
        XCTAssertEqual(model.currentTime, 1.5, accuracy: 1e-9)
        model.finishScrubbing()
        try await waitUntil { abs(model.player.currentTime().seconds - 1.5) < 0.001 }
        XCTAssertEqual(model.currentTime, 1.5, accuracy: 1e-9)
    }

    /// The tone files in the protected store.
    private func toneFiles() -> Set<URL> {
        let directory = PrivateFileStore.exports.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".caf") }.map { directory.appendingPathComponent($0) })
    }

    func testDraggingABleepsEndWritesNoToneUntilItIsLetGo() async throws {
        let movie = try await SoundMovie.make(seconds: 3)
        cleanup.append(movie)
        let model = try await openEditor(on: movie)
        let before = toneFiles()

        model.addAudioEdit(.bleep, over: 0.5...1.0)
        try await waitUntil { self.toneFiles().subtracting(before).count == 1 }
        let first = toneFiles().subtracting(before)
        let edit = try XCTUnwrap(model.audioEdits.first)

        // An end dragged across twenty places: the clip follows, the preview waits.
        for step in 1...20 {
            model.setRange(0.5...(1.0 + Double(step) * 0.05), of: edit, live: true)
        }
        XCTAssertEqual(model.timelineClips.first { $0.id == "audio-\(edit.id)" }?.range, 0.5...2.0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(toneFiles().subtracting(before), first, "No tone written while the end moves.")

        // Let go: one tone for the new length, and the old one gone.
        model.finishTrimming()
        try await waitUntil {
            let now = self.toneFiles().subtracting(before)
            return now.count == 1 && now != first
        }

        // A mute needs no tone at all.
        model.setKind(.mute, of: edit)
        try await waitUntil { self.toneFiles().subtracting(before).isEmpty }
    }
}
