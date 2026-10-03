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
    /// Recorded with PicStrip's camera, already in its protected temporary
    /// store: used where it is, and deleted with the screen like any copy.
    case recorded(URL)

    var isRecording: Bool {
        if case .recorded = self { true } else { false }
    }
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

    /// Covers the user drew, each followed through the video (`isDrawn`).
    private(set) var drawnCovers: [FaceTrack] = []
    /// When a face or drawn cover is on, where set on the timeline (by track id).
    private(set) var ranges: [Int: ClosedRange<Double>] = [:]
    /// The row picked in the list, shown on the timeline.
    var selection: Selection?
    /// Where the preview is, in seconds.
    private(set) var currentTime: Double = 0
    /// How far following a drawn box has got, 0 … 1; `nil` when not following.
    private(set) var followProgress: Double?

    enum Selection: Hashable {
        case face(Int)
        case drawn(Int)
        case group(String)
        case audio(Int)
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
    private(set) var coveredDrawnCount = 0
    private(set) var editedAudioCount = 0

    /// Stretches of sound to bleep or mute.
    private(set) var audioEdits: [AudioEdit] = []
    /// Whether the video has sound at all.
    private(set) var hasAudio = false
    /// How loud the sound is along the video, 0 … 1, for the timeline.
    private(set) var audioLevels: [Float] = []
    /// Small frames spread along the video, for the timeline's top row.
    private(set) var filmstrip: [UIImage] = []
    private var nextAudioID = 0
    /// Tone files laid over bleeps; deleted with the screen.
    private var toneFiles: [URL] = []
    /// The audio edits the current preview item was built with.
    private var previewAudioEdits: [AudioEdit] = []
    private(set) var output: URL?

    private var source: URL?
    private var found: [VideoFinding] = []
    private var path = CameraPath()
    private var scanTask: Task<VideoScan, Error>?
    private var saveTask: Task<Void, Never>?
    private(set) var skipsCovering = false
    private var previewGeneration = 0
    private var timeObserver: Any?
    /// Pauses the preview at the end of a stretch being played.
    private var boundaryObserver: Any?
    private var filmstripTask: Task<Void, Never>?
    private var nextDrawnID = 1_000_000

    var isLong: Bool { duration >= VideoScanner.longVideoDuration }
    var hasSomethingToCover: Bool { !faces.isEmpty || !findingGroups.isEmpty || !drawnCovers.isEmpty }

    /// When `track` is covered: the user's range, or its own.
    func range(of track: FaceTrack) -> ClosedRange<Double> {
        ranges[track.id] ?? clamped(track.automaticRange)
    }

    func clamped(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        let end = max(duration, 0)
        let lower = min(max(range.lowerBound, 0), end)
        return lower...min(max(range.upperBound, lower), end)
    }

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
            guard !skipsCovering else {
                // Only the hidden details: straight to the cleaned copy, frames untouched.
                await save()
                return
            }
            // Even with nothing found the editor opens: objects can be covered
            // and sound bleeped by hand.
            await makeThumbnails(from: url)
            hasAudio = !((try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []).isEmpty
            // Enough detail for the timeline zoomed all the way in.
            if hasAudio { audioLevels = await VideoAudioEditor.levels(of: url, count: Self.levelCount(for: duration)) }
            filmstrip = await Self.filmstrip(of: url, duration: duration, count: 10)
            stillTime = faces.first?.representativeSample?.time
                ?? findingGroups.first?.tracks.first?.representativeSample?.time ?? 0
            usePlaybackAudio(true)
            observePlayhead()
            // A frame about every second, for the zoomed-in timeline, once the
            // editor is open.
            let duration = duration
            filmstripTask = Task { [weak self] in
                let frames = await Self.filmstrip(of: url, duration: duration, count: Self.filmstripCount(for: duration))
                guard !Task.isCancelled, !frames.isEmpty else { return }
                self?.filmstrip = frames
            }
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

    /// Follows what the user drew around at the playhead through the video, and
    /// adds it as a cover.  `box` is normalised, top-left origin, upright.
    func addDrawnCover(_ box: CGRect, at time: Double) async {
        guard let source else { return }
        followProgress = 0
        defer { followProgress = nil }
        do {
            let samples = try await VideoObjectFollower.follow(box, at: time, in: source) { [weak self] fraction in
                Task { @MainActor in
                    if self?.followProgress != nil { self?.followProgress = fraction }
                }
            }
            var cover = FaceTrack(id: nextDrawnID, samples: samples, isDrawn: true)
            nextDrawnID += 1
            if cover.samples.isEmpty { cover.samples = [FaceTrack.Sample(time: time, box: box)] }
            drawnCovers.append(cover)
            faceThumbnails[cover.id] = await Self.crops([(time: time, box: box)], from: source)[0]
            selection = .drawn(cover.id)
            refreshPreview()
        } catch {
            // Following was cancelled or could not read the video: nothing is added.
        }
    }

    func deleteDrawnCover(_ cover: FaceTrack) {
        drawnCovers.removeAll { $0.id == cover.id }
        ranges[cover.id] = nil
        if selection == .drawn(cover.id) { selection = nil }
        refreshPreview()
    }

    /// Sets when a face or drawn cover is on, from the timeline.
    func setRange(_ range: ClosedRange<Double>, for track: FaceTrack) {
        ranges[track.id] = clamped(range)
        refreshPreview()
    }

    func resetRange(for track: FaceTrack) {
        ranges[track.id] = nil
        refreshPreview()
    }

    /// The face or drawn cover with this id.
    func track(_ id: Int) -> FaceTrack? {
        faces.first { $0.id == id } ?? drawnCovers.first { $0.id == id }
    }

    /// Moves the preview to `time` — the timeline's playhead.
    func scrub(to time: Double) {
        let time = min(max(0, time), duration)
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if previewStill != nil {
            stillTime = time
            refreshPreview()
        }
    }

    /// The frame at the playhead with the current covers drawn on it — what the
    /// user draws a new cover on.
    func coveredFrame(at time: Double) async -> UIImage? {
        guard let source else { return nil }
        let plan = currentPlan
        if plan.isEmpty {
            return await Self.crops([(time: time, box: CGRect(x: 0, y: 0, width: 1, height: 1))], from: source)[0]
        }
        return await Self.still(of: source, at: time, plan: plan)
    }

    /// Adds a bleep or mute at the playhead, a second long, and selects it.
    func addAudioEdit(_ kind: AudioEdit.Kind) {
        let length = min(1, duration)
        let start = min(max(0, currentTime), max(0, duration - length))
        addAudioEdit(kind, over: start...(start + length))
    }

    /// Adds a bleep or mute over `range` — a stretch selected on the timeline —
    /// and selects it.
    func addAudioEdit(_ kind: AudioEdit.Kind, over range: ClosedRange<Double>) {
        player.pause()
        let edit = AudioEdit(id: nextAudioID, kind: kind, range: clamped(range))
        nextAudioID += 1
        audioEdits.append(edit)
        selection = .audio(edit.id)
        refreshPreview()
    }

    /// Plays `range` once from its start, with the edits so far, and stops at its end.
    func play(_ range: ClosedRange<Double>) {
        stopAtBoundary()
        let range = clamped(range)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: range.upperBound, preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.stopAtBoundary()
            }
        }
        currentTime = range.lowerBound
        Task {
            _ = await player.seek(
                to: CMTime(seconds: range.lowerBound, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
            )
            player.play()
        }
    }

    private func stopAtBoundary() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    /// The preview's sound plays with the Ring/Silent switch set to silent, as
    /// in any video player; music paused for it resumes when the screen closes.
    private func usePlaybackAudio(_ playing: Bool) {
        let session = AVAudioSession.sharedInstance()
        if playing {
            try? session.setCategory(.playback, mode: .moviePlayback)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.soloAmbient)
        }
    }

    func setKind(_ kind: AudioEdit.Kind, of edit: AudioEdit) {
        guard let index = audioEdits.firstIndex(where: { $0.id == edit.id }) else { return }
        audioEdits[index].kind = kind
        refreshPreview()
    }

    func setRange(_ range: ClosedRange<Double>, of edit: AudioEdit) {
        guard let index = audioEdits.firstIndex(where: { $0.id == edit.id }) else { return }
        audioEdits[index].range = clamped(range)
        refreshPreview()
    }

    func deleteAudioEdit(_ edit: AudioEdit) {
        audioEdits.removeAll { $0.id == edit.id }
        if selection == .audio(edit.id) { selection = nil }
        refreshPreview()
    }

    func audioEdit(_ id: Int) -> AudioEdit? {
        audioEdits.first { $0.id == id }
    }

    private func observePlayhead() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
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
            let edited = try await VideoAudioEditor.edited(source, edits: audioEdits)
            if let tone = edited.toneFile { toneFiles.append(tone) }
            let composition = plan.isEmpty
                ? nil
                : try await VideoRedactor.composition(for: edited.asset, plan: plan)
            let output = try PrivateFileStore.exports.reserve(extension: "mov")
            reserved = output
            try await VideoCleaner.clean(
                edited.asset, audioMix: edited.audioMix, to: output, videoComposition: composition
            ) { [weak self] fraction in
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
            coveredFaceCount = plan.faces.filter { !$0.track.isDrawn }.count
            coveredDrawnCount = drawnCovers.count
            coveredFindingCount = findingGroups.filter(isCovered).count
            editedAudioCount = audioEdits.count
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
        selection = face.isDrawn ? .drawn(face.id) : .face(face.id)
        seek(start: range(of: face).lowerBound, showing: face.representativeSample?.time)
    }

    func seek(to group: FindingGroup) {
        selection = .group(group.id)
        seek(start: group.start - FindingTracking.hold, showing: group.tracks.first?.representativeSample?.time)
    }

    private func seek(start: Double, showing time: Double?) {
        let start = max(0, start)
        currentTime = start
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if previewStill != nil, let time {
            stillTime = time
            currentTime = time
            refreshPreview()
        }
    }

    /// Neither the copied original nor the cleaned copy outlives the screen.
    func discard() {
        scanTask?.cancel()
        saveTask?.cancel()
        filmstripTask?.cancel()
        stopAtBoundary()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        usePlaybackAudio(false)
        PrivateFileStore.exports.remove(source)
        PrivateFileStore.exports.remove(output)
        toneFiles.forEach { PrivateFileStore.exports.remove($0) }
    }

    // MARK: Helpers

    private var currentPlan: VideoRedactor.Plan {
        var plan = VideoRedactor.Plan(path: path)
        if coversFaces {
            plan.faces = faces.filter { !isVisible($0) }.map {
                VideoRedactor.FaceCoverage(track: $0, style: cover(for: $0), range: ranges[$0.id])
            }
        }
        // What the user drew is covered whatever the face switch says.
        plan.faces += drawnCovers.map {
            VideoRedactor.FaceCoverage(track: $0, style: cover(for: $0), range: ranges[$0.id])
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
        let edits = audioEdits
        Task {
            // The item is kept while the sound edits are unchanged; covers are
            // swapped on it in place.
            var item = player.currentItem.flatMap { current -> AVPlayerItem? in
                guard edits == previewAudioEdits else { return nil }
                if edits.isEmpty { return (current.asset as? AVURLAsset)?.url == source ? current : nil }
                return current.asset is AVComposition ? current : nil
            }
            if item == nil {
                guard let edited = try? await VideoAudioEditor.edited(source, edits: edits) else { return }
                if let tone = edited.toneFile { toneFiles.append(tone) }
                let fresh = AVPlayerItem(asset: edited.asset)
                fresh.audioMix = edited.audioMix
                item = fresh
            }
            guard let item else { return }
            let composition = plan.isEmpty
                ? nil
                : try? await VideoRedactor.composition(for: item.asset, plan: plan)
            // Covers that cannot be drawn are never replaced by the bare video.
            guard generation == previewGeneration, stage == .review, plan.isEmpty || composition != nil else { return }
            previewAudioEdits = edits
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
            guard item.status == .failed, composition != nil, generation == previewGeneration else {
                if generation == previewGeneration { previewStill = nil }
                return
            }
            let still = await Self.still(of: source, at: stillTime, plan: plan)
            guard generation == previewGeneration, stage == .review else { return }
            previewStill = still
            currentTime = stillTime
            // A failed item cannot be reused: start the next refresh afresh.
            player.replaceCurrentItem(with: nil)
        }
    }

    /// The frame at `time` with `plan` drawn on it, from the image generator,
    /// which can compose frames where the player cannot.
    nonisolated private static func still(of url: URL, at time: Double, plan: VideoRedactor.Plan) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let composition = try? await VideoRedactor.composition(for: asset, plan: plan) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
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
        case .recorded(let url):
            return url
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

    /// About one frame a second, from 10 for a short video to 120 for a long one.
    nonisolated static func filmstripCount(for duration: Double) -> Int {
        min(120, max(10, Int(duration.rounded(.up))))
    }

    /// Twenty loudness readings a second, from 160 to 4,000.
    nonisolated static func levelCount(for duration: Double) -> Int {
        min(4_000, max(160, Int((duration * 20).rounded(.up))))
    }

    /// `count` small frames spread evenly along the video.
    nonisolated private static func filmstrip(of url: URL, duration: Double, count: Int) async -> [UIImage] {
        guard duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        var frames: [UIImage] = []
        for index in 0..<count {
            let time = duration * (Double(index) + 0.5) / Double(count)
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            frames.append(UIImage(cgImage: image))
        }
        return frames
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
