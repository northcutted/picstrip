import AVKit
import Photos
import PhotosUI
import SwiftUI

// MARK: - VideoCleanerView

/// Cleans a video: finds the faces in it and covers them (blur, or an emoji per
/// face), then saves or shares a copy without its hidden details.  Text in the
/// video is not covered — the screen says so.
struct VideoCleanerView: View {
    let source: VideoSource

    @Environment(\.dismiss) private var dismiss
    @State private var model = VideoCleanerModel()
    @State private var saveState = SaveState.idle
    @State private var emojiFace: FaceTrack?
    /// The playhead time a new cover is being drawn at.
    @State private var drawingAt: DrawingTime?

    struct DrawingTime: Identifiable {
        let time: Double
        var id: Double { time }
    }

    enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .loading:
                    loadingView
                case .scanning:
                    scanningView
                case .review:
                    reviewView
                case .saving:
                    savingView
                case .cleaned:
                    cleanedView
                case .failed(let message):
                    ContentUnavailableView("Could not clean this video", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .navigationTitle("Clean Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("videoDoneButton")
                }
            }
        }
        .task { await model.start(source) }
        .onDisappear { model.discard() }
        .sheet(item: $drawingAt) { drawing in
            DrawCoverSheet(model: model, time: drawing.time)
        }
        .sheet(item: $emojiFace) { face in
            FaceEmojiSheet(
                face: face,
                selection: model.cover(for: face).emoji,
                onSelect: { model.setCover(.emoji($0), for: face) },
                onUseForEveryFace: model.faces.count > 1 ? { model.setCoverForEveryFace(model.cover(for: face)) } : nil
            )
        }
    }

    // MARK: Opening

    private var loadingView: some View {
        VStack(spacing: 20) {
            LoadingCard()
                .frame(maxHeight: 340)
            VStack(spacing: 8) {
                Text("Opening video…")
                    .font(.headline)
                if let fraction = model.loadProgress {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: 0)
                }
                Text("Long videos, and videos kept in iCloud, take a moment to arrive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("videoLoading")
        }
        .padding(32)
        .frame(maxWidth: 480, maxHeight: .infinity)
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(spacing: 20) {
            ScanGlimpseView(glimpse: model.glimpse)
                .frame(maxHeight: 340)
            VStack(spacing: 14) {
                ScanStatusView(progress: model.scanProgress)
                ProgressView(value: model.scanProgress.fraction)
                    .accessibilityIdentifier("videoScanProgress")
            }
            if model.isLong { longVideoNote }
            Button("Skip Covering") { model.skipCovering() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("skipFacesButton")
            Text("Skipping keeps everything in the video visible and only removes the hidden details.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 480, maxHeight: .infinity)
    }

    private var longVideoNote: some View {
        Label("This is a long video, so scanning it and saving the copy can take several minutes. Keep PicStrip open until it finishes.", systemImage: "clock")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("longVideoNote")
    }

    // MARK: Review

    private var reviewView: some View {
        List {
            Section {
                if let still = model.previewStill {
                    Image(uiImage: still)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .background(.black)
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Preview with covers")
                        .accessibilityIdentifier("videoPreviewStill")
                } else {
                    VideoPlayer(player: model.player)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Preview with covers")
                }
                EditorTimeline(
                    duration: model.duration,
                    time: model.currentTime,
                    lanes: timelineLanes,
                    frames: model.filmstrip,
                    levels: model.audioLevels,
                    clips: timelineClips,
                    selected: selectedClipIDs,
                    trimmable: trimmableClipID,
                    onSeek: { model.scrub(to: $0) },
                    onSelect: { select($0) },
                    onTrim: { trim($0, to: $1) }
                )
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("coverTimeline")

                HStack(spacing: 8) {
                    editButton("Cover an Object", systemImage: "viewfinder", identifier: "addCoverButton") {
                        model.player.pause()
                        drawingAt = DrawingTime(time: model.currentTime)
                    }
                    if model.hasAudio {
                        editButton("Bleep", systemImage: "waveform.badge.exclamationmark", identifier: "addBleepButton") {
                            model.addAudioEdit(.bleep)
                        }
                        editButton("Mute", systemImage: "speaker.slash", identifier: "addMuteButton") {
                            model.addAudioEdit(.mute)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .listRowSeparator(.hidden)
                if let track = selectedTrack, model.ranges[track.id] != nil {
                    Button("Reset Timing") { model.resetRange(for: track) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("resetTimingButton")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if model.previewStill != nil {
                        Text("This device cannot play the preview, so it shows one frame. Tap a row to see it covered.")
                    }
                    Text(timelineHint)
                }
            }

            if !model.drawnCovers.isEmpty {
                Section {
                    ForEach(Array(model.drawnCovers.enumerated()), id: \.element.id) { index, cover in
                        drawnRow(cover, number: index + 1)
                    }
                } header: {
                    Text("Objects")
                } footer: {
                    Text("Anything you draw around — a person, a car, a screen, a sign — is tracked as it moves, forwards and back.")
                }
            }

            if !model.audioEdits.isEmpty {
                Section {
                    ForEach(Array(model.audioEdits.enumerated()), id: \.element.id) { index, edit in
                        audioRow(edit, number: index + 1)
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("A bleep replaces the sound with a tone; a mute silences it.")
                }
            }

            if model.faces.isEmpty && model.findingGroups.isEmpty {
                Section {
                    Label("No faces or sensitive text found", systemImage: "face.dashed")
                        .accessibilityIdentifier("nothingFoundRow")
                } footer: {
                    Text("You can still cover objects yourself, bleep the sound, or save a copy with only the hidden details removed.")
                }
            }

            if !model.faces.isEmpty {
                Section {
                    Toggle("Cover faces", isOn: $model.coversFaces)
                        .accessibilityIdentifier("coverFacesToggle")
                    if model.coversFaces {
                        ForEach(Array(model.faces.enumerated()), id: \.element.id) { index, face in
                            faceRow(face, number: index + 1)
                        }
                    }
                } header: {
                    Text("Faces")
                } footer: {
                    Text("Faces are found automatically and one can be missed — small, turned away, or on screen for a moment. Watch the preview before you share.")
                }
            }

            if !model.findingGroups.isEmpty {
                Section {
                    Picker("Cover with", selection: $model.textStyle) {
                        ForEach([RedactionStyle.solid, .pixelate, .blur], id: \.self) { style in
                            Label(style.displayName, systemImage: style.symbolName).tag(style)
                        }
                    }
                    .accessibilityIdentifier("textStylePicker")
                    ForEach(Array(model.findingGroups.enumerated()), id: \.element.id) { index, group in
                        findingRow(group, number: index + 1)
                    }
                } header: {
                    Text("Text and codes")
                } footer: {
                    Text("Text is read twice a second, so text that is small, blurred by movement, or on screen only briefly can be missed.")
                }
            }

            if model.isLong {
                Section { longVideoNote }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.makeCopy()
            } label: {
                Label("Make Cleaned Copy", systemImage: "wand.and.sparkles")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("makeCleanedCopyButton")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func faceRow(_ face: FaceTrack, number: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                model.seek(to: face)
            } label: {
                HStack(spacing: 12) {
                    faceThumbnail(face)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Face \(number)")
                            .foregroundStyle(.primary)
                        Text(timeRange(face))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this face in the preview")
            .accessibilityIdentifier("faceRow-\(number)")

            Menu {
                Button {
                    model.setCover(.blur, for: face)
                } label: {
                    Label("Blur", systemImage: "drop.fill")
                }
                Button {
                    model.setCover(.solid, for: face)
                } label: {
                    Label("Solid", systemImage: "rectangle.fill")
                }
                Button {
                    emojiFace = face
                } label: {
                    Label("Emoji…", systemImage: "face.smiling")
                }
                Divider()
                Button {
                    model.setVisible(true, for: face)
                } label: {
                    Label("Leave Visible", systemImage: "eye")
                }
            } label: {
                coverLabel(model.isVisible(face) ? nil : model.cover(for: face))
            }
            .accessibilityLabel("Cover for face \(number)")
            .accessibilityValue(coverName(model.isVisible(face) ? nil : model.cover(for: face)))
            .accessibilityIdentifier("faceCoverMenu-\(number)")
        }
        .listRowBackground(model.selection == .face(face.id) ? Color.accentColor.opacity(0.12) : nil)
    }

    private func drawnRow(_ cover: FaceTrack, number: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                model.seek(to: cover)
            } label: {
                HStack(spacing: 12) {
                    faceThumbnail(cover)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Object \(number)")
                            .foregroundStyle(.primary)
                        Text(Self.timeRange(model.range(of: cover).lowerBound, model.range(of: cover).upperBound))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows it in the preview")
            .accessibilityIdentifier("drawnRow-\(number)")

            Menu {
                Button {
                    model.setCover(.blur, for: cover)
                } label: {
                    Label("Blur", systemImage: "drop.fill")
                }
                Button {
                    model.setCover(.solid, for: cover)
                } label: {
                    Label("Solid", systemImage: "rectangle.fill")
                }
                Button {
                    emojiFace = cover
                } label: {
                    Label("Emoji…", systemImage: "face.smiling")
                }
                Divider()
                Button(role: .destructive) {
                    model.deleteDrawnCover(cover)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                coverLabel(model.cover(for: cover))
            }
            .accessibilityLabel("Cover for object \(number)")
            .accessibilityValue(coverName(model.cover(for: cover)))
            .accessibilityIdentifier("drawnCoverMenu-\(number)")
        }
        .listRowBackground(model.selection == .drawn(cover.id) ? Color.accentColor.opacity(0.12) : nil)
    }

    // MARK: Timeline

    /// An action under the timeline: its symbol over a short title, the
    /// buttons sharing the width.
    private func editButton(
        _ title: LocalizedStringKey, systemImage: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier(identifier)
    }

    private var timelineLanes: [EditorTimeline.Lane] {
        var lanes: [EditorTimeline.Lane] = []
        if !model.faces.isEmpty { lanes.append(.faces) }
        if !model.findingGroups.isEmpty { lanes.append(.text) }
        lanes.append(.objects)
        if model.hasAudio { lanes.append(.audio) }
        return lanes
    }

    /// Every cover and sound edit as a clip, in its lane and colour.
    private var timelineClips: [EditorTimeline.Clip] {
        var clips: [EditorTimeline.Clip] = []
        if model.coversFaces {
            for (index, face) in model.faces.enumerated() where !model.isVisible(face) {
                clips.append(.init(
                    id: "face-\(face.id)", lane: .faces, range: model.range(of: face),
                    color: PIIType.face.riskLevel.color, label: String(localized: "Face \(index + 1)")
                ))
            }
        }
        for group in model.findingGroups where model.isCovered(group) {
            for track in group.tracks {
                clips.append(.init(
                    id: "text-\(track.id)", lane: .text,
                    range: model.clamped((track.start - FindingTracking.hold)...(track.end + FindingTracking.hold)),
                    color: group.type.riskLevel.color, label: group.type.description, symbol: group.type.symbolName
                ))
            }
        }
        for (index, cover) in model.drawnCovers.enumerated() {
            clips.append(.init(
                id: "face-\(cover.id)", lane: .objects, range: model.range(of: cover),
                color: .accentColor, label: String(localized: "Object \(index + 1)"), symbol: "viewfinder"
            ))
        }
        for edit in model.audioEdits {
            clips.append(.init(
                id: "audio-\(edit.id)", lane: .audio, range: edit.range,
                color: edit.kind == .bleep ? .red : .gray,
                label: edit.kind == .bleep ? String(localized: "Bleep") : String(localized: "Mute"),
                symbol: edit.kind == .bleep ? "waveform.badge.exclamationmark" : "speaker.slash.fill"
            ))
        }
        return clips
    }

    private var selectedClipIDs: Set<String> {
        switch model.selection {
        case .face(let id), .drawn(let id):
            return ["face-\(id)"]
        case .group(let groupID):
            return Set(model.findingGroups.first { $0.id == groupID }?.tracks.map { "text-\($0.id)" } ?? [])
        case .audio(let id):
            return ["audio-\(id)"]
        case nil:
            return []
        }
    }

    /// The selected clip whose ends can be dragged: a face, an object or a sound edit.
    private var trimmableClipID: String? {
        switch model.selection {
        case .face(let id), .drawn(let id): "face-\(id)"
        case .audio(let id): "audio-\(id)"
        default: nil
        }
    }

    /// The face or object cover picked, whose timing can be changed.
    private var selectedTrack: FaceTrack? {
        switch model.selection {
        case .face(let id), .drawn(let id): model.track(id)
        default: nil
        }
    }

    private var timelineHint: String {
        trimmableClipID != nil
            ? String(localized: "Drag the yellow ends of the selected clip to change when it applies. Drag across the frames to move through the video.")
            : String(localized: "Each lane shows when something is covered. Tap a clip to select it, or drag across the frames to move through the video.")
    }

    private func select(_ clip: EditorTimeline.Clip) {
        let parts = clip.id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return }
        let id = String(parts[1])
        switch parts[0] {
        case "face":
            if let number = Int(id), let track = model.track(number) { model.seek(to: track) }
        case "text":
            if let number = Int(id), let group = model.findingGroups.first(where: { $0.tracks.contains { $0.id == number } }) {
                model.seek(to: group)
            }
        case "audio":
            if let number = Int(id) {
                model.selection = .audio(number)
                model.scrub(to: clip.range.lowerBound)
            }
        default:
            break
        }
    }

    private func trim(_ clip: EditorTimeline.Clip, to range: ClosedRange<Double>) {
        if let track = selectedTrack, clip.id == "face-\(track.id)" {
            model.setRange(range, for: track)
        } else if case .audio(let id) = model.selection, let edit = model.audioEdit(id) {
            model.setRange(range, of: edit)
        }
    }

    private func audioRow(_ edit: AudioEdit, number: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                model.selection = .audio(edit.id)
                model.scrub(to: edit.range.lowerBound)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: edit.kind == .bleep ? "waveform.badge.exclamationmark" : "speaker.slash.fill")
                        .font(.title3)
                        .foregroundStyle(edit.kind == .bleep ? .red : .secondary)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(edit.kind == .bleep ? "Bleep" : "Mute")
                            .foregroundStyle(.primary)
                        Text(Self.timeRange(edit.range.lowerBound, edit.range.upperBound))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows it on the timeline")
            .accessibilityIdentifier("audioRow-\(number)")

            Menu {
                Button {
                    model.setKind(.bleep, of: edit)
                } label: {
                    Label("Bleep", systemImage: "waveform.badge.exclamationmark")
                }
                Button {
                    model.setKind(.mute, of: edit)
                } label: {
                    Label("Mute", systemImage: "speaker.slash")
                }
                Divider()
                Button(role: .destructive) {
                    model.deleteAudioEdit(edit)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Change audio edit \(number)")
            .accessibilityIdentifier("audioMenu-\(number)")
        }
        .listRowBackground(model.selection == .audio(edit.id) ? Color.accentColor.opacity(0.12) : nil)
    }

    private func findingRow(_ group: FindingGroup, number: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                model.seek(to: group)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: group.type.symbolName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.type.description)
                            .foregroundStyle(.primary)
                        Text(group.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(group.tracks.prefix(3).map(timeRange).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows it in the preview")
            .accessibilityIdentifier("findingRow-\(number)")

            Toggle(isOn: Binding(
                get: { model.isCovered(group) },
                set: { model.setCovered($0, for: group) }
            )) {
                Text("Cover \(group.type.description)")
            }
            .labelsHidden()
            .accessibilityIdentifier("findingToggle-\(number)")
        }
        .listRowBackground(model.selection == .group(group.id) ? Color.accentColor.opacity(0.12) : nil)
    }

    @ViewBuilder
    private func faceThumbnail(_ face: FaceTrack) -> some View {
        Group {
            if let image = model.faceThumbnails[face.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.square")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    /// `nil` for a face left visible.
    private func coverLabel(_ cover: FaceCover?) -> some View {
        HStack(spacing: 4) {
            switch cover {
            case nil:
                Image(systemName: "eye")
                Text("Visible")
            case .blur:
                Image(systemName: "drop.fill")
                Text("Blur")
            case .solid:
                Image(systemName: "rectangle.fill")
                Text("Solid")
            case .emoji(let emoji):
                Text(emoji).font(.title3)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
    }

    private func coverName(_ cover: FaceCover?) -> String {
        switch cover {
        case nil: String(localized: "Visible")
        case .blur: String(localized: "Blur")
        case .solid: String(localized: "Solid")
        case .emoji(let emoji): emoji
        }
    }

    private func timeRange(_ face: FaceTrack) -> String {
        Self.timeRange(face.start, face.end)
    }

    private func timeRange(_ track: FindingTrack) -> String {
        Self.timeRange(track.start, track.end)
    }

    static func timeRange(_ start: Double, _ end: Double) -> String {
        clock(start) == clock(end) ? clock(start) : "\(clock(start)) – \(clock(end))"
    }

    static func clock(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds).rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: Saving

    private var savingView: some View {
        VStack(spacing: 16) {
            Text(model.hasSomethingToCover ? "Covering and saving a copy…" : "Cleaning video…")
                .font(.headline)
            ProgressView(value: model.saveProgress)
                .accessibilityIdentifier("videoSaveProgress")
            if model.isLong { longVideoNote }
        }
        .padding(32)
        .frame(maxWidth: 480, maxHeight: .infinity)
    }

    // MARK: Cleaned

    private var cleanedView: some View {
        List {
            Section {
                VideoPlayer(player: model.player)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel("Cleaned video")
            }

            Section {
                if model.coveredFaceCount > 0 {
                    resultRow(
                        title: Text("^[\(model.coveredFaceCount) face](inflect: true) covered"),
                        symbol: "face.dashed.fill", values: []
                    )
                    .accessibilityIdentifier("facesCoveredRow")
                }
                if model.coveredDrawnCount > 0 {
                    resultRow(
                        title: Text("Objects covered: \(model.coveredDrawnCount)"),
                        symbol: "viewfinder", values: []
                    )
                    .accessibilityIdentifier("drawnCoveredRow")
                }
                if model.editedAudioCount > 0 {
                    resultRow(
                        title: Text("Sound bleeped or muted: \(model.editedAudioCount)"),
                        symbol: "waveform.badge.exclamationmark", values: []
                    )
                    .accessibilityIdentifier("audioEditedRow")
                }
                if model.coveredFindingCount > 0 {
                    resultRow(
                        title: Text("Text and codes covered: \(model.coveredFindingCount)"),
                        symbol: "text.viewfinder", values: []
                    )
                    .accessibilityIdentifier("textCoveredRow")
                }
                if model.faces.isEmpty && model.findingGroups.isEmpty && !model.skipsCovering {
                    Label("No faces or sensitive text found", systemImage: "face.dashed")
                        .accessibilityIdentifier("noFacesFoundRow")
                }
                let kinds = Dictionary(grouping: model.removed, by: \.kind)
                if kinds.isEmpty && !model.removedOther {
                    Label("No hidden details found", systemImage: "checkmark.seal")
                } else {
                    ForEach(VideoFinding.Kind.allCases.filter { kinds[$0] != nil && $0 != .other }, id: \.self) { kind in
                        resultRow(title: Text(kind.title), symbol: kind.symbolName, values: kinds[kind]?.map(\.value) ?? [])
                    }
                    if model.removedOther, kinds[.other] != nil {
                        resultRow(title: Text(VideoFinding.Kind.other.title), symbol: VideoFinding.Kind.other.symbolName, values: [])
                    }
                }
            } header: {
                Text("Removed from the copy")
            }

            if !model.skipsCovering {
                Section {
                    Button {
                        saveState = .idle
                        model.changeCovers()
                    } label: {
                        Label("Change What’s Covered", systemImage: "face.smiling")
                    }
                    .accessibilityIdentifier("changeCoversButton")
                }
            }

            Section {
                Label(
                    model.coveredFaceCount + model.coveredFindingCount > 0
                        ? "Faces and text were covered automatically, and some can be missed. Watch the copy before you share it."
                        : "Faces and text in the video stay visible: PicStrip removes hidden details only.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let output = model.output {
                cleanedActions(output)
            }
        }
    }

    private func cleanedActions(_ output: URL) -> some View {
        VStack(spacing: 10) {
            ShareLink(item: output, preview: SharePreview("Cleaned video", image: Image(systemName: "video"))) {
                Label("Share cleaned video", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("shareCleanedVideoButton")

            Button {
                Task { await save(output) }
            } label: {
                Group {
                    switch saveState {
                    case .saving: ProgressView()
                    case .saved: Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    default: Label("Save as New Video", systemImage: "plus.square.on.square")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(saveState == .saving || saveState == .saved)
            .accessibilityIdentifier("saveCleanedVideoButton")

            if case .failed(let message) = saveState {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func resultRow(title: Text, symbol: String, values: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                let shown = values.map(Self.readable).filter { !$0.isEmpty }
                if !shown.isEmpty {
                    Text(shown.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Removed")
        }
        .accessibilityElement(children: .combine)
    }

    /// An ISO 6709 location ("+41.8781-087.6298+180.000/") as "41.8781, -87.6298".
    static func readable(_ value: String) -> String {
        let pattern = /^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)/
        guard let match = value.firstMatch(of: pattern),
              let latitude = Double(match.1), let longitude = Double(match.2)
        else { return value }
        return "\(latitude.formatted(.number.precision(.fractionLength(0...4)))), \(longitude.formatted(.number.precision(.fractionLength(0...4))))"
    }

    // MARK: Work

    private func save(_ url: URL) async {
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed(String(localized: "Photo library access was denied. Please enable it in Settings."))
            return
        }
        do {
            try await PhotoLibraryWriter.saveVideo(at: url)
            saveState = .saved
        } catch {
            saveState = .failed(String(localized: "Could not save to Photos: \(error.localizedDescription)"))
        }
    }
}

// MARK: - ScanGlimpseView

/// The frame being scanned, drawn as the viewfinder draws what it sees: every
/// line of text read in a hairline, each finding outlined in its risk colour
/// with its badge — and a scan line sweeping down.
private struct ScanGlimpseView: View {
    let glimpse: VideoScanner.Glimpse?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let glimpse {
                Image(decorative: glimpse.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geometry in
                            let size = geometry.size
                            ReadingLines(lines: glimpse.lines.map { Self.rect(for: $0, in: size) })
                            ForEach(Array(glimpse.marks.enumerated()), id: \.offset) { _, mark in
                                let rect = Self.rect(for: mark.box, in: size).insetBy(dx: -3, dy: -3)
                                DetectionBox(type: mark.type, confidence: mark.confidence)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                DetectionBadge(type: mark.type)
                                    .position(x: rect.minX, y: rect.minY)
                            }
                        }
                    }
                    .overlay {
                        if !reduceMotion { ScanSweep() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityElement()
                    .accessibilityLabel("The frame being scanned")
            } else {
                LoadingCard()
            }
        }
        .accessibilityIdentifier("scanGlimpse")
    }

    static func rect(for box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
    }
}

/// What the scan has found so far, in the viewfinder's status capsule: the
/// kinds of finding in their risk colours, with counts.
private struct ScanStatusView: View {
    let progress: VideoScanner.Progress

    /// Kinds of text shown as symbols before the rest are counted.
    private static let maximumSymbols = 4

    var body: some View {
        HStack(spacing: 8) {
            if progress.isCooling {
                Image(systemName: "thermometer.high")
                Text("Paused while the device cools down")
            } else {
                Image(systemName: "text.viewfinder")
                    .symbolEffect(.pulse)
                Text("Looking for faces and text…")
            }
            HStack(spacing: 6) {
                if progress.faceCount > 0 {
                    count(progress.faceCount, of: .face)
                }
                ForEach(progress.textKinds.prefix(Self.maximumSymbols), id: \.type) { kind in
                    count(kind.count, of: kind.type)
                }
                if progress.textKinds.count > Self.maximumSymbols {
                    Text(verbatim: "+" + (progress.textKinds.count - Self.maximumSymbols).formatted())
                        .font(.caption2.weight(.bold))
                }
            }
            .accessibilityHidden(true)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(in: .capsule)
        .animation(.snappy, value: progress.faceCount)
        .animation(.snappy, value: progress.textCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(progress.isCooling ? "Paused while the device cools down" : "Looking for faces and text…"))
        .accessibilityValue(Text("^[\(progress.faceCount) face](inflect: true) found so far") + Text(verbatim: ", ")
            + Text("Text and codes found so far: \(progress.textCount)"))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("scanCounts")
    }

    private func count(_ count: Int, of type: PIIType) -> some View {
        HStack(spacing: 2) {
            Image(systemName: type.symbolName)
                .foregroundStyle(type.riskLevel.color)
            Text(count, format: .number)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .transition(.scale.combined(with: .opacity))
    }
}

/// Where the frame will be, before the first one arrives: a soft shimmer
/// across a film frame, so the wait looks like work.
private struct LoadingCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.fill.tertiary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        GeometryReader { geometry in
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.18), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: geometry.size.width * 0.4)
                            .offset(x: geometry.size.width * (phase * 1.4 - 0.4))
                        }
                    }
                }
            }
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}

/// A soft line moving down the frame, two seconds a pass.  Driven by the
/// timeline, not a repeating animation, so nothing else on screen is caught up
/// in it.
private struct ScanSweep: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            GeometryReader { geometry in
                LinearGradient(
                    colors: [.clear, Color.accentColor.opacity(0.35), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: geometry.size.height * 0.18)
                .offset(y: geometry.size.height * (phase * 1.18 - 0.18))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - DrawCoverSheet

/// The paused frame, with the covers already on it, to draw a box around
/// something the scan missed.  PicStrip then follows it through the video.
private struct DrawCoverSheet: View {
    let model: VideoCleanerModel
    let time: Double

    @Environment(\.dismiss) private var dismiss
    @State private var frame: UIImage?
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    @State private var following: Task<Void, Never>?

    /// The drawn box, normalised, top-left origin; `nil` until it is big enough.
    private var box: CGRect? {
        guard let start, let end else { return nil }
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        return rect.width >= 0.02 && rect.height >= 0.02 ? rect : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let frame {
                        Image(uiImage: frame)
                            .resizable()
                            .scaledToFit()
                            .overlay { drawingLayer }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("The paused frame")
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                if let progress = model.followProgress {
                    VStack(spacing: 6) {
                        Text("Tracking it through the video…")
                            .font(.headline)
                        ProgressView(value: progress)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("followProgress")
                } else {
                    Text("Draw a box around anything — a person, a car, a screen, a sign. PicStrip tracks it through the video, forwards and back, for as long as it can see it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .navigationTitle("Cover an Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        following?.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("cancelDrawButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Track") {
                        guard let box else { return }
                        following = Task {
                            await model.addDrawnCover(box, at: time)
                            if !Task.isCancelled { dismiss() }
                        }
                    }
                    .disabled(box == nil || following != nil)
                    .accessibilityIdentifier("followButton")
                }
            }
            .task { frame = await model.coveredFrame(at: time) }
            .interactiveDismissDisabled(following != nil)
        }
    }

    private var drawingLayer: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard following == nil, size.width > 0, size.height > 0 else { return }
                                func normalised(_ point: CGPoint) -> CGPoint {
                                    CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
                                }
                                if drag.translation == .zero || start == nil { start = normalised(drag.startLocation) }
                                end = normalised(drag.location)
                            }
                    )
                    .accessibilityIdentifier("drawingArea")
                if let box {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.18))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: box.width * size.width, height: box.height * size.height)
                        .offset(x: box.minX * size.width, y: box.minY * size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - FaceEmojiSheet

/// Picks the emoji that covers one face in a video.
private struct FaceEmojiSheet: View {
    let face: FaceTrack
    let selection: String?
    let onSelect: (String) -> Void
    /// `nil` when the video has only this face.
    let onUseForEveryFace: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RedactionEmojiPicker(selection: selection) { emoji in
                        onSelect(emoji)
                    }
                    Text("The face is blurred under the emoji too, so nothing shows through around it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let onUseForEveryFace, selection != nil {
                        Button("Use this cover for every face") {
                            onUseForEveryFace()
                            dismiss()
                        }
                        .accessibilityIdentifier("applyToAllFacesButton")
                    }
                }
                .padding(20)
            }
            .navigationTitle("Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("emojiDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
