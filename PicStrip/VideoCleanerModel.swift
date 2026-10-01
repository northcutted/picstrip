import AVFoundation
import Observation
import PhotosUI
import SwiftUI

// MARK: - VideoSource

/// Where a video to clean comes from.
enum VideoSource {
    case picked(PhotosPickerItem)
    /// A file on disk — the UI tests' fixture (`PICSTRIP_VIDEO_FIXTURE`).
    case file(URL)
}

// MARK: - VideoCleanerModel

/// Drives the video screen: copies the video in, finds its faces, previews the
/// covers, and writes a copy with the faces covered and the hidden details gone.
@Observable
final class VideoCleanerModel {

    enum Stage: Equatable {
        case loading
        case scanning
        /// Faces were found: the user checks the covers before saving.
        case review
        case saving
        case cleaned
        case failed(String)
    }

    private(set) var stage = Stage.loading
    /// Seconds.
    private(set) var duration: Double = 0
    private(set) var scanProgress = VideoFaceScanner.Progress(fraction: 0, isCooling: false)
    private(set) var saveProgress: Double = 0
    private(set) var faces: [FaceTrack] = []
    private(set) var thumbnails: [Int: UIImage] = [:]
    /// A face's cover; faces not in here are blurred.
    private(set) var covers: [Int: FaceCover] = [:]
    /// Off to keep every face visible and only remove the hidden details.
    var coversFaces = true {
        didSet { if coversFaces != oldValue { refreshPreview() } }
    }
    let player = AVPlayer()
    /// The covered frame shown when the player cannot play the preview (the
    /// simulator cannot play any video composition).
    private(set) var previewStill: UIImage?
    private var stillTime: Double = 0

    /// Location, device and date findings from the original — all gone from the copy.
    private(set) var removed: [VideoFinding] = []
    /// Whether the original's other metadata is gone from the copy too.
    private(set) var removedOther = false
    /// How many faces the saved copy has covered.
    private(set) var coveredFaceCount = 0
    private(set) var output: URL?

    private var source: URL?
    private var found: [VideoFinding] = []
    private var scanTask: Task<[FaceTrack], Error>?
    private var saveTask: Task<Void, Never>?
    private(set) var skipsFaces = false
    private var previewGeneration = 0

    var isLong: Bool { duration >= VideoFaceScanner.longVideoDuration }

    func cover(for face: FaceTrack) -> FaceCover { covers[face.id] ?? .blur }

    // MARK: Flow

    func start(_ videoSource: VideoSource) async {
        do {
            let url = try await load(videoSource)
            source = url
            duration = try await AVURLAsset(url: url).load(.duration).seconds
            found = try await VideoCleaner.findings(in: url)

            stage = .scanning
            let scan = Task {
                try await VideoFaceScanner.scan(url) { [weak self] progress in
                    Task { @MainActor in self?.scanProgress = progress }
                }
            }
            scanTask = scan
            do {
                faces = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
            } catch where skipsFaces {
                faces = []
            }
            scanTask = nil
            try Task.checkCancellation()
            // Skip tapped just as the scan finished.
            if skipsFaces { faces = [] }

            guard !faces.isEmpty else {
                // Nothing to cover: straight to the cleaned copy, frames untouched.
                await save()
                return
            }
            thumbnails = await Self.thumbnails(of: faces, in: url)
            stillTime = faces[0].representativeSample?.time ?? 0
            refreshPreview()
            stage = .review
        } catch is CancellationError {
            // The screen closed.
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Stops looking for faces and saves a copy with only the hidden details removed.
    func skipFaces() {
        skipsFaces = true
        scanTask?.cancel()
    }

    func setCover(_ cover: FaceCover, for face: FaceTrack) {
        covers[face.id] = cover
        refreshPreview()
    }

    func setCoverForEveryFace(_ cover: FaceCover) {
        for face in faces { covers[face.id] = cover }
        refreshPreview()
    }

    /// Starts writing the cleaned copy; closing the screen stops it.
    func makeCopy() {
        saveTask?.cancel()
        saveTask = Task { await save() }
    }

    /// Writes the cleaned copy, covering the faces unless that was turned off.
    private func save() async {
        guard let source else { return }
        stage = .saving
        saveProgress = 0
        player.pause()
        var reserved: URL?
        do {
            let covering = coversFaces && !faces.isEmpty
            let composition = covering
                ? try await VideoFaceRedactor.composition(for: AVURLAsset(url: source), covers: currentCovers)
                : nil
            let output = try PrivateFileStore.exports.reserve(extension: "mov")
            reserved = output
            try await VideoCleaner.clean(source, to: output, videoComposition: composition) { [weak self] fraction in
                Task { @MainActor in self?.saveProgress = fraction }
            }
            try Task.checkCancellation()
            // The copy carries one new random identifier; anything else is left over.
            let otherLeft = try await VideoCleaner.findings(in: output)
                .contains { $0.kind == .other && UUID(uuidString: $0.value) == nil }
            PrivateFileStore.exports.remove(self.output)
            self.output = output
            removed = found.filter { $0.kind != .other } + found.filter { $0.kind == .other }.prefix(1)
            removedOther = !otherLeft
            coveredFaceCount = covering ? faces.count : 0
            player.replaceCurrentItem(with: AVPlayerItem(url: output))
            stage = .cleaned
        } catch {
            // A cancelled or failed export can leave a partial file behind.
            PrivateFileStore.exports.remove(reserved)
            if !Task.isCancelled, !(error is CancellationError) {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    /// Back from the cleaned copy to the faces, to change a cover.
    func changeCovers() {
        PrivateFileStore.exports.remove(output)
        output = nil
        refreshPreview()
        stage = .review
    }

    func seek(to face: FaceTrack) {
        let start = max(0, face.start - FaceTracking.hold)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if previewStill != nil, let sample = face.representativeSample {
            stillTime = sample.time
            refreshPreview()
        }
    }

    /// Neither the copied original nor the cleaned copy outlives the screen.
    func discard() {
        scanTask?.cancel()
        saveTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        PrivateFileStore.exports.remove(source)
        PrivateFileStore.exports.remove(output)
    }

    // MARK: Helpers

    private var currentCovers: [VideoFaceRedactor.Cover] {
        faces.map { VideoFaceRedactor.Cover(track: $0, style: cover(for: $0)) }
    }

    /// Plays the original with the current covers drawn through the same
    /// composition the saved copy is made with.
    private func refreshPreview() {
        guard let source else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let covers = coversFaces ? currentCovers : []
        Task {
            let item = player.currentItem.flatMap { ($0.asset as? AVURLAsset)?.url == source ? $0 : nil }
                ?? AVPlayerItem(url: source)
            let composition = covers.isEmpty
                ? nil
                : try? await VideoFaceRedactor.composition(for: item.asset, covers: covers)
            // Covers that cannot be drawn are never replaced by the bare video.
            guard generation == previewGeneration, stage == .review, covers.isEmpty || composition != nil else { return }
            item.videoComposition = composition
            if player.currentItem !== item {
                player.replaceCurrentItem(with: item)
            } else if player.rate == 0 {
                // Redraw the paused frame with the new covers.
                _ = await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            }

            // A player that cannot compose the frames shows nothing at all, never
            // an uncovered face; fall back to a still drawn the same way.
            for _ in 0..<25 where item.status == .unknown {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard item.status == .failed, let composition, generation == previewGeneration else {
                if generation == previewGeneration { previewStill = nil }
                return
            }
            let still = await Self.still(of: source, at: stillTime, through: composition)
            guard generation == previewGeneration, stage == .review else { return }
            previewStill = still
            // A failed item cannot be reused: start the next refresh afresh.
            player.replaceCurrentItem(with: nil)
        }
    }

    nonisolated private static func still(of url: URL, at time: Double, through composition: AVVideoComposition) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        return image.map { UIImage(cgImage: $0) }
    }

    private func load(_ videoSource: VideoSource) async throws -> URL {
        switch videoSource {
        case .picked(let item):
            guard let video = try await item.loadTransferable(type: IncomingVideo.self) else {
                throw VideoCleaner.Failure.cannotExport
            }
            return video.url
        case .file(let url):
            return try PrivateFileStore.exports.copy(url, extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        }
    }

    /// Each face as it looks in the middle of its track, for the list.
    nonisolated private static func thumbnails(of faces: [FaceTrack], in url: URL) async -> [Int: UIImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        var thumbnails: [Int: UIImage] = [:]
        for face in faces {
            guard let sample = face.representativeSample,
                  let frame = try? await generator.image(at: CMTime(seconds: sample.time, preferredTimescale: 600)).image
            else { continue }
            let box = FaceTracking.padded(sample.box).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let crop = CGRect(
                x: box.minX * CGFloat(frame.width), y: box.minY * CGFloat(frame.height),
                width: box.width * CGFloat(frame.width), height: box.height * CGFloat(frame.height)
            ).integral
            if let cropped = frame.cropping(to: crop) { thumbnails[face.id] = UIImage(cgImage: cropped) }
        }
        return thumbnails
    }
}
