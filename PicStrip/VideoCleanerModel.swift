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

/// Drives the video screen: copies the video in, finds its faces, text and
/// codes, previews the covers, and writes a copy with them covered and the
/// hidden details gone.
@Observable
final class VideoCleanerModel {

    enum Stage: Equatable {
        case loading
        case scanning
        /// Something to cover was found: the user checks the covers before saving.
        case review
        case saving
        case cleaned
        case failed(String)
    }

    private(set) var stage = Stage.loading
    /// How far opening the video has got, 0 … 1, or `nil` while unknown.
    private(set) var loadProgress: Double?
    /// Seconds.
    private(set) var duration: Double = 0
    private(set) var scanProgress = VideoScanner.Progress(fraction: 0, isCooling: false)
    /// The latest look at the frame being scanned, kept between glimpses.
    private(set) var glimpse: VideoScanner.Glimpse?
    private(set) var saveProgress: Double = 0

    private(set) var faces: [FaceTrack] = []
    /// A face's cover; faces not in here are blurred.
    private(set) var covers: [Int: FaceCover] = [:]
    /// Faces the user chose to leave showing.
    private(set) var visibleFaces: Set<Int> = []
    /// Off to keep every face visible.
    var coversFaces = true {
        didSet { if coversFaces != oldValue { refreshPreview() } }
    }

    /// Sensitive text and codes, one row per distinct reading.
    private(set) var findingGroups: [FindingGroup] = []
    /// Groups the user chose to leave showing.
    private(set) var uncoveredGroups: Set<String> = []
    /// How text and codes are covered: `.solid`, `.pixelate` or `.blur`.
    var textStyle = RedactionStyle.solid {
        didSet { if textStyle != oldValue { refreshPreview() } }
    }

    /// How each face (by track id) and group (by group id) looks in the list.
    private(set) var faceThumbnails: [Int: UIImage] = [:]
    private(set) var findingThumbnails: [String: UIImage] = [:]

    let player = AVPlayer()
    /// The covered frame shown when the player cannot play the preview (the
    /// simulator cannot play any video composition).
    private(set) var previewStill: UIImage?
    private var stillTime: Double = 0

    /// Location, device and date findings from the original — all gone from the copy.
    private(set) var removed: [VideoFinding] = []
    /// Whether the original's other metadata is gone from the copy too.
    private(set) var removedOther = false
    /// What the saved copy covers.
    private(set) var coveredFaceCount = 0
    private(set) var coveredFindingCount = 0
    private(set) var output: URL?

    private var source: URL?
    private var found: [VideoFinding] = []
    private var path = CameraPath()
    private var scanTask: Task<VideoScan, Error>?
    private var saveTask: Task<Void, Never>?
    private(set) var skipsCovering = false
    private var previewGeneration = 0

    var isLong: Bool { duration >= VideoScanner.longVideoDuration }
    var hasSomethingToCover: Bool { !faces.isEmpty || !findingGroups.isEmpty }

    func cover(for face: FaceTrack) -> FaceCover { covers[face.id] ?? .blur }
    func isVisible(_ face: FaceTrack) -> Bool { visibleFaces.contains(face.id) }
    func isCovered(_ group: FindingGroup) -> Bool { !uncoveredGroups.contains(group.id) }

    // MARK: Flow

    func start(_ videoSource: VideoSource) async {
        do {
            let url = try await load(videoSource)
            source = url
            duration = try await AVURLAsset(url: url).load(.duration).seconds
            found = try await VideoCleaner.findings(in: url)

            stage = .scanning
            let terms = AlwaysCoverList.shared.terms
            let scanning = Task {
                try await VideoScanner.scan(url, alwaysCover: terms) { [weak self] progress in
                    Task { @MainActor in self?.receive(progress) }
                }
            }
            scanTask = scanning
            var scan = VideoScan()
            do {
                scan = try await withTaskCancellationHandler {
                    try await scanning.value
                } onCancel: {
                    scanning.cancel()
                }
            } catch where skipsCovering {
                scan = VideoScan()
            }
            scanTask = nil
            glimpse = nil
            try Task.checkCancellation()
            // Skip tapped just as the scan finished.
            if skipsCovering { scan = VideoScan() }

            faces = scan.faces
            findingGroups = FindingGroup.groups(of: scan.findings)
            path = scan.path
            guard hasSomethingToCover else {
                // Nothing to cover: straight to the cleaned copy, frames untouched.
                await save()
                return
            }
            await makeThumbnails(from: url)
            stillTime = faces.first?.representativeSample?.time
                ?? findingGroups.first?.tracks.first?.representativeSample?.time ?? 0
            refreshPreview()
            stage = .review
        } catch is CancellationError {
            // The screen closed.
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func receive(_ progress: VideoScanner.Progress) {
        guard stage == .scanning else { return }
        scanProgress = progress
        if let fresh = progress.glimpse { glimpse = fresh }
    }

    /// Stops looking and saves a copy with only the hidden details removed.
    func skipCovering() {
        skipsCovering = true
        scanTask?.cancel()
    }

    func setCover(_ cover: FaceCover, for face: FaceTrack) {
        covers[face.id] = cover
        visibleFaces.remove(face.id)
        refreshPreview()
    }

    func setCoverForEveryFace(_ cover: FaceCover) {
        for face in faces { covers[face.id] = cover }
        refreshPreview()
    }

    func setVisible(_ visible: Bool, for face: FaceTrack) {
        if visible { visibleFaces.insert(face.id) } else { visibleFaces.remove(face.id) }
        refreshPreview()
    }

    func setCovered(_ covered: Bool, for group: FindingGroup) {
        if covered { uncoveredGroups.remove(group.id) } else { uncoveredGroups.insert(group.id) }
        refreshPreview()
    }

    /// Starts writing the cleaned copy; closing the screen stops it.
    func makeCopy() {
        saveTask?.cancel()
        saveTask = Task { await save() }
    }

    /// Writes the cleaned copy with what is chosen covered.
    private func save() async {
        guard let source else { return }
        stage = .saving
        saveProgress = 0
        player.pause()
        var reserved: URL?
        do {
            let plan = currentPlan
            let composition = plan.isEmpty
                ? nil
                : try await VideoRedactor.composition(for: AVURLAsset(url: source), plan: plan)
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
            coveredFaceCount = plan.faces.count
            coveredFindingCount = findingGroups.filter(isCovered).count
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

    /// Back from the cleaned copy to the list, to change a cover.
    func changeCovers() {
        PrivateFileStore.exports.remove(output)
        output = nil
        refreshPreview()
        stage = .review
    }

    func seek(to face: FaceTrack) {
        seek(start: face.start - FaceTracking.hold, showing: face.representativeSample?.time)
    }

    func seek(to group: FindingGroup) {
        seek(start: group.start - FindingTracking.hold, showing: group.tracks.first?.representativeSample?.time)
    }

    private func seek(start: Double, showing time: Double?) {
        player.seek(to: CMTime(seconds: max(0, start), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if previewStill != nil, let time {
            stillTime = time
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

    private var currentPlan: VideoRedactor.Plan {
        var plan = VideoRedactor.Plan(path: path)
        if coversFaces {
            plan.faces = faces.filter { !isVisible($0) }.map { VideoRedactor.FaceCoverage(track: $0, style: cover(for: $0)) }
        }
        plan.findings = findingGroups.filter(isCovered).flatMap { group in
            group.tracks.map { VideoRedactor.FindingCoverage(track: $0, style: textStyle) }
        }
        return plan
    }

    /// Plays the original with the current covers drawn through the same
    /// composition the saved copy is made with.
    private func refreshPreview() {
        guard let source else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let plan = currentPlan
        Task {
            let item = player.currentItem.flatMap { ($0.asset as? AVURLAsset)?.url == source ? $0 : nil }
                ?? AVPlayerItem(url: source)
            let composition = plan.isEmpty
                ? nil
                : try? await VideoRedactor.composition(for: item.asset, plan: plan)
            // Covers that cannot be drawn are never replaced by the bare video.
            guard generation == previewGeneration, stage == .review, plan.isEmpty || composition != nil else { return }
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
            return try await loadPicked(item)
        case .file(let url):
            return try PrivateFileStore.exports.copy(url, extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        }
    }

    /// The picked video, reporting how far the system has got handing it over —
    /// downloading it from iCloud, or copying it out of the library.
    private func loadPicked(_ item: PhotosPickerItem) async throws -> URL {
        let box = ProgressBox()
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                if let fraction = box.fraction { self?.loadProgress = fraction }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { watcher.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let progress = item.loadTransferable(type: IncomingVideo.self) { result in
                    switch result {
                    case .success(let video?): continuation.resume(returning: video.url)
                    case .success(nil): continuation.resume(throwing: VideoCleaner.Failure.cannotExport)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                box.progress = progress
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Each face and each group as it looks in the middle of its first track.
    private func makeThumbnails(from url: URL) async {
        let faceCrops = faces.compactMap { face in
            face.representativeSample.map { (time: $0.time, box: FaceTracking.padded($0.box)) }
        }
        let groupCrops = findingGroups.compactMap { group in
            group.tracks.first?.representativeSample.map { (time: $0.time, box: FindingTracking.padded($0.box)) }
        }
        let images = await Self.crops(faceCrops + groupCrops, from: url)
        var faceImages: [Int: UIImage] = [:]
        for (index, face) in faces.enumerated() { faceImages[face.id] = images[index] }
        var groupImages: [String: UIImage] = [:]
        for (index, group) in findingGroups.enumerated() { groupImages[group.id] = images[faces.count + index] }
        faceThumbnails = faceImages
        findingThumbnails = groupImages
    }

    /// The frame at each `time`, cropped to `box` (normalised, top-left origin).
    nonisolated private static func crops(_ items: [(time: Double, box: CGRect)], from url: URL) async -> [Int: UIImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        var images: [Int: UIImage] = [:]
        for (index, item) in items.enumerated() {
            guard let frame = try? await generator.image(at: CMTime(seconds: item.time, preferredTimescale: 600)).image else { continue }
            let box = item.box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let crop = CGRect(
                x: box.minX * CGFloat(frame.width), y: box.minY * CGFloat(frame.height),
                width: box.width * CGFloat(frame.width), height: box.height * CGFloat(frame.height)
            ).integral
            if let cropped = frame.cropping(to: crop) { images[index] = UIImage(cgImage: cropped) }
        }
        return images
    }
}

/// The system's progress handing over a picked video, read from the main actor
/// while the hand-over runs elsewhere.
nonisolated private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Progress?

    var progress: Progress? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var fraction: Double? {
        guard let progress, progress.totalUnitCount > 0 else { return nil }
        return progress.fractionCompleted
    }

    func cancel() { progress?.cancel() }
}
