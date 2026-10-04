import SwiftUI
import UIKit

// MARK: - EditorTimeline

/// The video's covers and sound edits laid out like a video editor's tracks:
/// a time ruler, a strip of frames, and a labelled lane each for faces, text,
/// objects and audio, with every cover or edit as a clip and the playhead
/// across them all.
///
/// Drag across the frames to move through the video, and pinch to zoom in —
/// zoomed in, a bar under the lanes shows and moves the part in view, and a
/// drag held at either edge carries on along the video.  Tap a clip to select
/// it, hold it for its options, and drag the selected clip's yellow ends to
/// change when it applies.  Hold and drag along the audio lane to select a
/// stretch of sound, with the system's edit menu over it.
struct EditorTimeline: View {

    enum Lane: Int, CaseIterable, Identifiable {
        case faces, text, objects, audio

        var id: Int { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .faces: "Faces"
            case .text: "Text"
            case .objects: "Objects"
            case .audio: "Audio"
            }
        }

        var symbol: String {
            switch self {
            case .faces: PIIType.face.symbolName
            case .text: "text.viewfinder"
            case .objects: "viewfinder"
            case .audio: "waveform"
            }
        }
    }

    struct Clip: Identifiable, Equatable {
        let id: String
        let lane: Lane
        let range: ClosedRange<Double>
        let color: Color
        /// Shown on the clip where it is wide enough, and read by VoiceOver.
        let label: String
        var symbol: String?
    }

    /// Something to do with a stretch of sound selected on the audio lane,
    /// offered in the edit menu over it.
    struct SelectionAction: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        /// Offered to VoiceOver on the audio lane too, for the second from the
        /// playhead; `nil` to offer it only in the menu.
        var playheadTitle: String?
        /// Whether the stretch stays selected afterwards (Play), or is done with.
        var keepsSelection = false
        let perform: (ClosedRange<Double>) -> Void
    }

    let duration: Double
    /// Where the preview is.  Read only by the parts that show it, so that as
    /// the video plays the playhead moves without the lanes being redrawn.
    let playhead: Playhead
    let lanes: [Lane]
    let frames: [UIImage]
    /// The sound's loudness along the video, 0 … 1, drawn in the audio lane.
    let levels: [Float]
    let clips: [Clip]
    let selected: Set<String>
    /// The selected clip whose ends can be dragged.
    let trimmable: String?
    /// What can be done with a selected stretch of sound; with none, the audio
    /// lane cannot be selected along.
    let selectionActions: [SelectionAction]
    let onSeek: (Double) -> Void
    /// The playhead follows a finger: called as it moves, then `onScrubEnd`
    /// once it lifts.
    let onScrub: (Double) -> Void
    let onScrubEnd: () -> Void
    let onSelect: (Clip) -> Void
    /// An end of the selected clip follows a finger: called as it moves, then
    /// `onTrimEnd` once it lifts.
    let onTrim: (Clip, ClosedRange<Double>) -> Void
    let onTrimEnd: () -> Void
    /// A clip's options, shown when it is held.
    let clipMenu: (Clip) -> AnyView

    @State private var width: CGFloat = 0
    @State private var zoom: Double = 1
    @State private var windowStart: Double = 0
    /// The window a pinch started from.
    @State private var pinchStart: TimelineWindow?
    /// The playhead before the touch that turned into a pinch, put back for it.
    @State private var timeBeforeTouch: Double?
    @State private var edgeDirection: Double = 0
    @State private var edgeScroll: Task<Void, Never>?

    @State private var audioSelection: ClosedRange<Double>?
    @State private var isSelectingAudio = false
    @State private var hasDraggedSelection = false
    @State private var selectionAnchor: Double = 0
    @State private var selectionAnchorX: CGFloat = 0
    @State private var lastAudioTouchX: CGFloat = 0
    @State private var selectionStarts = 0
    /// Bumped each time the edit menu is to be shown.
    @State private var menuRequest = 0
    @State private var showsMenu = false

    static let labelWidth: CGFloat = 66
    private static let rulerHeight: CGFloat = 18
    private static let filmHeight: CGFloat = 40
    private static let laneHeight: CGFloat = 28
    private static let overviewHeight: CGFloat = 22
    private static let gap: CGFloat = 4
    private static let minimumLength = 0.1
    /// How close to an edge, zoomed in, a drag starts carrying on along the video.
    private static let edgeZone: CGFloat = 28
    private static let handleColor = Color.yellow
    private static let laneSpace = "timelineLane"

    private enum Edge { case start, end }

    private var window: TimelineWindow {
        TimelineWindow(duration: duration, zoom: zoom, start: windowStart).clamped
    }

    private var trackWidth: CGFloat { max(0, width - Self.labelWidth) }

    var body: some View {
        VStack(spacing: Self.gap) {
            row(label: nil) { mapping in ruler(mapping) }
                .frame(height: Self.rulerHeight)
            row(label: Text("Video"), symbol: "film") { mapping in filmstrip(mapping) }
                .frame(height: Self.filmHeight)
            ForEach(lanes) { lane in
                row(label: Text(lane.title), symbol: lane.symbol) { mapping in laneView(lane, mapping) }
                    .frame(height: Self.laneHeight)
            }
            if window.isZoomed {
                overviewRow
                    .frame(height: Self.overviewHeight)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            PlayheadLine(playhead: playhead, window: window, trackWidth: trackWidth, height: tracksHeight)
        }
        .background {
            PlayheadWatcher(playhead: playhead) { time in
                // Zoomed in, the part in view follows the playhead as it plays.
                guard edgeDirection == 0, pinchStart == nil else { return }
                show(window.revealing(time))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(pinch)
        .sensoryFeedback(.impact(weight: .medium), trigger: selectionStarts)
        .animation(.snappy(duration: 0.2), value: window.isZoomed)
        .accessibilityElement(children: .contain)
    }

    private var tracksHeight: CGFloat {
        Self.rulerHeight + Self.filmHeight + CGFloat(lanes.count) * Self.laneHeight + CGFloat(lanes.count + 1) * Self.gap
    }

    // MARK: Rows

    /// A lane: its label on the left, its track filling the rest.
    private func row<Track: View>(
        label: Text?, symbol: String? = nil,
        @ViewBuilder track: @escaping (_ mapping: TimelineMapping) -> Track
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14)
                }
                label
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)
            .frame(width: Self.labelWidth, alignment: .leading)
            .accessibilityHidden(true)
            GeometryReader { geometry in
                track(TimelineMapping(window: window, width: geometry.size.width))
            }
        }
    }

    private func ruler(_ mapping: TimelineMapping) -> some View {
        let step = Self.tickStep(for: mapping.window.length)
        let first = Int((mapping.window.start / step).rounded(.up))
        let last = Int((mapping.window.end / step).rounded(.down))
        return ZStack(alignment: .topLeading) {
            ForEach(first...max(first, last), id: \.self) { index in
                let tick = Double(index) * step
                if tick <= mapping.window.end {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.tickLabel(tick, step: step))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Rectangle().fill(.secondary).frame(width: 1, height: 4)
                    }
                    .offset(x: mapping.x(tick))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrub(mapping))
        .accessibilityHidden(true)
    }

    /// Frames side by side at their own shape, each the one nearest its place.
    private func filmstrip(_ mapping: TimelineMapping) -> some View {
        let aspect = frames.first.map { $0.size.width / max(1, $0.size.height) } ?? 16 / 9
        let tileWidth = min(80, max(24, Self.filmHeight * aspect))
        let tileSeconds = mapping.pointsPerSecond > 0 ? Double(tileWidth / mapping.pointsPerSecond) : max(duration, 1)
        let first = max(0, Int((mapping.window.start / tileSeconds).rounded(.down)))
        let last = max(first, Int((mapping.window.end / tileSeconds).rounded(.up)))
        return ZStack(alignment: .topLeading) {
            ForEach(first..<last, id: \.self) { index in
                if let frame = frame(at: (Double(index) + 0.5) * tileSeconds) {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .frame(width: tileWidth, height: Self.filmHeight)
                        .clipped()
                        .offset(x: mapping.x(Double(index) * tileSeconds))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .contentShape(Rectangle())
        .gesture(scrub(mapping))
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .modifier(PlayheadValue(playhead: playhead, duration: duration))
        .accessibilityAdjustableAction { direction in
            onSeek(clamp(playhead.time + (direction == .increment ? 1 : -1)))
        }
        .accessibilityAction(named: Text("Zoom In")) { zoom(by: 2) }
        .accessibilityAction(named: Text("Zoom Out")) { zoom(by: 0.5) }
        .accessibilityIdentifier("coverTimelineTrack")
    }

    private func frame(at time: Double) -> UIImage? {
        guard !frames.isEmpty, duration > 0 else { return frames.first }
        return frames[min(frames.count - 1, max(0, Int(time / duration * Double(frames.count))))]
    }

    private func laneView(_ lane: Lane, _ mapping: TimelineMapping) -> some View {
        let selectsAudio = lane == .audio && !selectionActions.isEmpty
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.fill.quaternary)
                .contentShape(Rectangle())
                .gesture(scrub(mapping, selectsAudio: selectsAudio))
                .simultaneousGesture(hold(mapping), including: selectsAudio ? .all : .none)
                .modifier(AudioLaneAccessibility(isAudio: selectsAudio, actions: playheadActions))
            if lane == .audio, !levels.isEmpty {
                Waveform(levels: levels, duration: duration, window: mapping.window)
                    .equatable()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if lane == .audio, let audioSelection {
                selectionView(audioSelection, mapping)
            }
            ForEach(clips.filter { $0.lane == lane }) { clip in
                if let visible = mapping.window.visiblePart(of: clip.range) {
                    clipView(clip, showing: visible, mapping)
                }
            }
            if let trimmable, let clip = clips.first(where: { $0.id == trimmable && $0.lane == lane }) {
                if mapping.window.contains(clip.range.lowerBound) { handle(.start, of: clip, mapping) }
                if mapping.window.contains(clip.range.upperBound) { handle(.end, of: clip, mapping) }
            }
            if selectsAudio {
                EditMenuPresenter(
                    request: showsMenu ? menuRequest : 0,
                    point: menuPoint(mapping),
                    actions: menuActions,
                    onDismiss: { showsMenu = false }
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .coordinateSpace(.named(Self.laneSpace))
    }

    private func clipView(_ clip: Clip, showing visible: ClosedRange<Double>, _ mapping: TimelineMapping) -> some View {
        let width = max(6, mapping.x(visible.upperBound) - mapping.x(visible.lowerBound))
        let isSelected = selected.contains(clip.id)
        // A tap selects the clip; holding it opens its menu.  (A context menu
        // inside a list row would belong to the whole row.)
        return Menu {
            clipMenu(clip)
        } label: {
            HStack(spacing: 3) {
                if let symbol = clip.symbol, width > 22 {
                    Image(systemName: symbol)
                }
                if width > 48 {
                    Text(clip.label)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(width: width, height: Self.laneHeight - 6, alignment: .leading)
            .background(clip.color.opacity(isSelected || selected.isEmpty ? 0.95 : 0.55), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Self.handleColor : .clear, lineWidth: 2)
            )
        } primaryAction: {
            onSelect(clip)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .offset(x: mapping.x(visible.lowerBound), y: 3)
        .accessibilityLabel(Text(clip.label))
        .accessibilityValue(Text("\(VideoCleanerView.clock(clip.range.lowerBound)) – \(VideoCleanerView.clock(clip.range.upperBound))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("clip-\(clip.id)")
    }

    // MARK: Zoom

    /// Zoomed in: how far, on a button that shows the whole video again, and
    /// the whole video in miniature with the part in view, to drag along.
    private var overviewRow: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { show(window.zoomed(to: 1, keeping: 0)) }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "minus.magnifyingglass")
                    Text(Self.zoomLabel(zoom))
                        .monospacedDigit()
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .frame(height: Self.overviewHeight)
                .background(.fill.tertiary, in: Capsule())
                .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: Self.labelWidth, alignment: .leading)
            .accessibilityLabel("Show the whole video")
            .accessibilityValue(Text("Zoomed in \(Self.zoomLabel(zoom))"))
            .accessibilityIdentifier("timelineZoomButton")

            GeometryReader { geometry in
                let scale = duration > 0 ? geometry.size.width / duration : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.fill.quaternary)
                        .frame(height: 8)
                    ForEach(clips) { clip in
                        Capsule()
                            .fill(clip.color.opacity(0.7))
                            .frame(width: max(2, (clip.range.upperBound - clip.range.lowerBound) * scale), height: 4)
                            .offset(x: clip.range.lowerBound * scale)
                    }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.08))
                        .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
                        .frame(width: max(14, window.length * scale), height: Self.overviewHeight - 4)
                        .offset(x: window.start * scale)
                    OverviewPlayhead(playhead: playhead, scale: scale, height: Self.overviewHeight - 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard scale > 0 else { return }
                            show(window.moved(to: drag.location.x / scale - window.length / 2))
                        }
                )
            }
            .accessibilityElement()
            .accessibilityLabel("Part of the video in view")
            .accessibilityValue(Text("\(VideoCleanerView.clock(window.start)) to \(VideoCleanerView.clock(window.end))"))
            .accessibilityAdjustableAction { direction in
                let step = window.length / 2 * (direction == .increment ? 1 : -1)
                show(window.moved(to: window.start + step))
            }
            .accessibilityIdentifier("timelineOverview")
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                if pinchStart == nil {
                    pinchStart = window
                    // The first finger down moved the playhead; put it back.
                    if let timeBeforeTouch { onSeek(timeBeforeTouch) }
                    stopEdgeScroll()
                }
                guard let start = pinchStart, trackWidth > 0 else { return }
                let fraction = min(max((value.startLocation.x - Self.labelWidth) / trackWidth, 0), 1)
                show(start.zoomed(to: start.zoom * value.magnification, keeping: fraction))
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Zooms around the playhead — for VoiceOver.
    private func zoom(by factor: Double) {
        let fraction = window.length > 0 ? (playhead.time - window.start) / window.length : 0
        show(window.zoomed(to: zoom * factor, keeping: min(max(fraction, 0), 1)))
    }

    private func show(_ window: TimelineWindow) {
        guard window.zoom != zoom || window.start != windowStart else { return }
        zoom = window.zoom
        windowStart = window.start
    }

    // MARK: Gestures

    private func scrub(_ mapping: TimelineMapping, selectsAudio: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pinchStart == nil, mapping.width > 0 else { return }
                if timeBeforeTouch == nil { timeBeforeTouch = playhead.time }
                if selectsAudio { lastAudioTouchX = value.location.x }
                carryOn(at: value.location.x, width: mapping.width)
                let now = clamp(mapping.time(min(max(value.location.x, 0), mapping.width)))
                if isSelectingAudio {
                    if abs(value.location.x - selectionAnchorX) > 8 { hasDraggedSelection = true }
                    if hasDraggedSelection {
                        audioSelection = Self.selection(from: selectionAnchor, to: now, duration: duration)
                    }
                    onScrub(now)
                    return
                }
                if audioSelection != nil {
                    audioSelection = nil
                    showsMenu = false
                }
                onScrub(now)
            }
            .onEnded { _ in
                stopEdgeScroll()
                timeBeforeTouch = nil
                onScrubEnd()
                if isSelectingAudio {
                    isSelectingAudio = false
                    presentMenu()
                }
            }
    }

    /// Holding still on the audio lane starts selecting a stretch of sound
    /// there — a second of it, until a drag sets its other end.
    private func hold(_ mapping: TimelineMapping) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
            .onEnded { _ in
                guard pinchStart == nil, mapping.width > 0 else { return }
                let anchor = clamp(mapping.time(min(max(lastAudioTouchX, 0), mapping.width)))
                selectionAnchor = anchor
                selectionAnchorX = lastAudioTouchX
                hasDraggedSelection = false
                isSelectingAudio = true
                showsMenu = false
                audioSelection = Self.selection(from: anchor, to: anchor + 1, duration: duration)
                selectionStarts += 1
            }
    }

    /// Zoomed in, a drag held at either edge keeps moving along the video,
    /// carrying the playhead with it.
    private func carryOn(at x: CGFloat, width: CGFloat) {
        guard window.isZoomed else { return stopEdgeScroll() }
        let direction: Double = x > width - Self.edgeZone ? 1 : (x < Self.edgeZone ? -1 : 0)
        guard direction != edgeDirection else { return }
        edgeScroll?.cancel()
        edgeDirection = direction
        guard direction != 0 else { return }
        edgeScroll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                let before = window
                let after = before.moved(to: before.start + direction * before.length * 0.04)
                guard after.start != before.start else { return }
                show(after)
                let now = direction > 0 ? after.end : after.start
                if isSelectingAudio {
                    hasDraggedSelection = true
                    audioSelection = Self.selection(from: selectionAnchor, to: now, duration: duration)
                }
                onScrub(now)
            }
        }
    }

    private func stopEdgeScroll() {
        edgeScroll?.cancel()
        edgeScroll = nil
        edgeDirection = 0
    }

    private func clamp(_ value: Double) -> Double {
        min(max(0, value), duration)
    }

    private func trimmed(_ clip: Clip, moving edge: Edge, to value: Double) -> ClosedRange<Double> {
        switch edge {
        case .start:
            let lower = min(clamp(value), clip.range.upperBound - Self.minimumLength)
            return max(0, lower)...clip.range.upperBound
        case .end:
            let upper = max(clamp(value), clip.range.lowerBound + Self.minimumLength)
            return clip.range.lowerBound...min(duration, upper)
        }
    }

    /// A yellow grip on one end of the selected clip, with a full-size touch target.
    private func handle(_ edge: Edge, of clip: Clip, _ mapping: TimelineMapping) -> some View {
        let value = edge == .start ? clip.range.lowerBound : clip.range.upperBound
        return RoundedRectangle(cornerRadius: 3)
            .fill(Self.handleColor)
            .frame(width: 10, height: Self.laneHeight)
            .overlay(Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 12))
            .frame(width: 44, height: Self.laneHeight)
            .contentShape(Rectangle())
            .offset(x: mapping.x(value) - 22)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.laneSpace))
                    .onChanged { drag in
                        guard mapping.width > 0 else { return }
                        // Zoomed in, an end goes as far as the part in view.
                        let x = min(max(drag.location.x, 0), mapping.width)
                        let range = trimmed(clip, moving: edge, to: mapping.time(x))
                        onTrim(clip, range)
                        onScrub(edge == .start ? range.lowerBound : range.upperBound)
                    }
                    .onEnded { _ in
                        onTrimEnd()
                        onScrubEnd()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? Text("Cover starts") : Text("Cover ends"))
            .accessibilityValue(Text(VideoCleanerView.clock(value)))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                onTrim(clip, trimmed(clip, moving: edge, to: value + step))
                onTrimEnd()
            }
            .accessibilityIdentifier(edge == .start ? "coverStartHandle" : "coverEndHandle")
    }

    // MARK: Selecting sound

    @ViewBuilder
    private func selectionView(_ selection: ClosedRange<Double>, _ mapping: TimelineMapping) -> some View {
        if let visible = mapping.window.visiblePart(of: selection) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Self.handleColor.opacity(0.28))
                .strokeBorder(Self.handleColor, lineWidth: 2)
                .frame(width: max(4, mapping.x(visible.upperBound) - mapping.x(visible.lowerBound)), height: Self.laneHeight)
                .contentShape(Rectangle())
                // Tapping the selection brings its menu back.
                .onTapGesture { presentMenu() }
                .offset(x: mapping.x(visible.lowerBound))
                .accessibilityHidden(true)
        }
    }

    private func presentMenu() {
        guard audioSelection != nil else { return }
        menuRequest += 1
        showsMenu = true
    }

    /// Over the middle of the part of the selection in view.
    private func menuPoint(_ mapping: TimelineMapping) -> CGPoint {
        guard let audioSelection, let visible = mapping.window.visiblePart(of: audioSelection) else { return .zero }
        return CGPoint(x: (mapping.x(visible.lowerBound) + mapping.x(visible.upperBound)) / 2, y: 0)
    }

    private var menuActions: [UIAction] {
        guard let audioSelection else { return [] }
        var actions = selectionActions.map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in
                action.perform(audioSelection)
                if !action.keepsSelection { self.audioSelection = nil }
            }
        }
        if audioSelection != 0...duration {
            actions.append(UIAction(
                title: String(localized: "Select All"), image: UIImage(systemName: "arrow.left.and.right")
            ) { _ in
                self.audioSelection = 0...duration
                // Once this menu has gone, show it again over the whole video.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    presentMenu()
                }
            })
        }
        return actions
    }

    /// The actions VoiceOver offers on the audio lane, each for the second
    /// from the playhead.
    private var playheadActions: [AudioLaneAccessibility.Action] {
        selectionActions.compactMap { action in
            action.playheadTitle.map { title in
                AudioLaneAccessibility.Action(title: title) {
                    let time = playhead.time
                    action.perform(Self.selection(from: time, to: time + 1, duration: duration))
                }
            }
        }
    }

    // MARK: Scales

    /// The stretch between `anchor` and `end`, at least a tenth of a second,
    /// within the video.
    static func selection(from anchor: Double, to end: Double, duration: Double) -> ClosedRange<Double> {
        let lower = min(max(0, min(anchor, end)), max(0, duration - minimumLength))
        let upper = min(duration, max(max(anchor, end), lower + minimumLength))
        return lower...max(lower, upper)
    }

    /// "0:05" on a ruler of whole seconds, "1.5s" on one of half seconds.
    static func tickLabel(_ tick: Double, step: Double) -> String {
        step < 1 ? tick.formatted(.number.precision(.fractionLength(1))) + "s" : VideoCleanerView.clock(tick)
    }

    /// Ruler marks about five to a timeline, at round times.
    static func tickStep(for duration: Double) -> Double {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1_800]
        return steps.first { duration / $0 <= 6 } ?? 3_600
    }

    /// "2×", "2.5×".
    static func zoomLabel(_ zoom: Double) -> String {
        zoom.formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}

// MARK: - TimelineWindow

/// The part of the video the timeline shows: all of it at zoom 1, and a
/// shorter stretch, which can be moved along, zoomed in.
nonisolated struct TimelineWindow: Equatable {
    /// The shortest stretch shown, zoomed all the way in.
    static let shortest = 2.0

    var duration: Double
    /// 1 shows the whole video, 2 half of it, and so on.
    var zoom: Double = 1
    /// The first second in view.
    var start: Double = 0

    var length: Double { zoom > 0 ? duration / zoom : duration }
    var end: Double { start + length }
    var isZoomed: Bool { zoom > 1.001 }

    static func maximumZoom(for duration: Double) -> Double {
        max(1, duration / shortest)
    }

    /// The zoom within its limits, and the window within the video.
    var clamped: TimelineWindow {
        var window = self
        window.zoom = min(max(zoom, 1), Self.maximumZoom(for: duration))
        window.start = min(max(start, 0), max(0, duration - window.length))
        return window
    }

    /// Zoomed to `zoom`, keeping the time `fraction` of the way across where it is.
    func zoomed(to zoom: Double, keeping fraction: Double) -> TimelineWindow {
        let anchor = start + fraction * length
        var window = self
        window.zoom = zoom
        window = window.clamped
        window.start = anchor - fraction * window.length
        return window.clamped
    }

    /// Moved to start at `start`, within the video.
    func moved(to start: Double) -> TimelineWindow {
        var window = self
        window.start = start
        return window.clamped
    }

    /// Moved, if `time` is out of view, so it sits a tenth of the way in.
    func revealing(_ time: Double) -> TimelineWindow {
        guard isZoomed, !contains(time) else { return self }
        return moved(to: time - length / 10)
    }

    func contains(_ time: Double) -> Bool {
        time >= start - 0.0001 && time <= end + 0.0001
    }

    /// The part of `range` in view, or `nil` if none of it is.
    func visiblePart(of range: ClosedRange<Double>) -> ClosedRange<Double>? {
        let lower = max(range.lowerBound, start)
        let upper = min(range.upperBound, end)
        return lower <= upper ? lower...upper : nil
    }

    /// Where `time` is across a track `width` wide.
    func x(_ time: Double, width: CGFloat) -> CGFloat {
        length > 0 ? CGFloat((time - start) / length) * width : 0
    }

    /// The time at `x` across a track `width` wide.
    func time(at x: CGFloat, width: CGFloat) -> Double {
        width > 0 ? start + Double(x / width) * length : start
    }
}

/// A `TimelineWindow` across one track's width.
private struct TimelineMapping {
    let window: TimelineWindow
    let width: CGFloat

    var pointsPerSecond: CGFloat { window.length > 0 ? width / CGFloat(window.length) : 0 }
    func x(_ time: Double) -> CGFloat { window.x(time, width: width) }
    func time(_ x: CGFloat) -> Double { window.time(at: x, width: width) }
}

// MARK: - Playhead views

/// The red line across the lanes at the preview's time.
private struct PlayheadLine: View {
    let playhead: Playhead
    let window: TimelineWindow
    let trackWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let time = playhead.time
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.red)
                .frame(width: 10, height: 12)
        }
        .offset(x: EditorTimeline.labelWidth + window.x(time, width: trackWidth) - 5)
        .opacity(window.contains(time) ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The playhead in the zoomed-in overview of the whole video.
private struct OverviewPlayhead: View {
    let playhead: Playhead
    /// Points a second.
    let scale: Double
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: height)
            .offset(x: playhead.time * scale - 1)
    }
}

/// Tells `onMove` each time the playhead moves; draws nothing.
private struct PlayheadWatcher: View {
    let playhead: Playhead
    let onMove: (Double) -> Void

    var body: some View {
        Color.clear
            .onChange(of: playhead.time) { _, time in onMove(time) }
            .accessibilityHidden(true)
    }
}

/// The timeline's VoiceOver value: where the playhead is.
private struct PlayheadValue: ViewModifier {
    let playhead: Playhead
    let duration: Double

    func body(content: Content) -> some View {
        content.accessibilityValue(Text("\(VideoCleanerView.clock(playhead.time)) of \(VideoCleanerView.clock(duration))"))
    }
}

// MARK: - Waveform

/// The sound's loudness in the audio lane, as one shape.  Zoomed out there
/// are more readings than points, so each point shows the loudest reading in
/// it: a long video's thousands of readings are drawn as a few hundred bars.
private struct Waveform: View, Equatable {
    let levels: [Float]
    let duration: Double
    let window: TimelineWindow

    var body: some View {
        Canvas { context, size in
            guard duration > 0, !levels.isEmpty, size.width > 0 else { return }
            let mapping = TimelineMapping(window: window, width: size.width)
            let seconds = duration / Double(levels.count)
            let first = max(0, Int(window.start / seconds))
            let last = min(levels.count, Int((window.end / seconds).rounded(.up)))
            guard first < last else { return }
            let barWidth = CGFloat(seconds) * mapping.pointsPerSecond
            func bar(at x: CGFloat, width: CGFloat, level: Float) -> CGRect {
                let height = max(1, CGFloat(level) * (size.height - 6))
                return CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
            }
            var shape = Path()
            if barWidth >= 1 {
                for index in first..<last {
                    shape.addRect(bar(at: mapping.x(Double(index) * seconds), width: max(1, barWidth - 0.5), level: levels[index]))
                }
            } else {
                var column = mapping.x(Double(first) * seconds).rounded(.down)
                var loudest: Float = 0
                for index in first..<last {
                    let x = mapping.x(Double(index) * seconds).rounded(.down)
                    if x != column {
                        shape.addRect(bar(at: column, width: 1, level: loudest))
                        column = x
                        loudest = 0
                    }
                    loudest = max(loudest, levels[index])
                }
                shape.addRect(bar(at: column, width: 1, level: loudest))
            }
            context.fill(shape, with: .color(.secondary.opacity(0.45)))
        }
    }
}

// MARK: - AudioLaneAccessibility

/// The audio lane as one VoiceOver element, with actions at the playhead;
/// other lanes are left out, their clips speaking for them.
private struct AudioLaneAccessibility: ViewModifier {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let isAudio: Bool
    let actions: [Action]

    func body(content: Content) -> some View {
        if isAudio {
            content
                .accessibilityElement()
                .accessibilityLabel("Audio")
                .accessibilityHint("Hold and drag to select a stretch of sound.")
                .accessibilityActions {
                    ForEach(actions.indices, id: \.self) { index in
                        Button(actions[index].title, action: actions[index].perform)
                    }
                }
                .accessibilityIdentifier("audioLane")
        } else {
            content.accessibilityHidden(true)
        }
    }
}

// MARK: - EditMenuPresenter

/// Shows the system edit menu — the bar of actions over selected text — at
/// `point` each time `request` changes to a new value other than 0, and
/// closes it at 0.  It takes no touches itself.
private struct EditMenuPresenter: UIViewRepresentable {
    let request: Int
    let point: CGPoint
    let actions: [UIAction]
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        let interaction = UIEditMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        return view
    }

    func updateUIView(_ view: PassThroughView, context: Context) {
        let coordinator = context.coordinator
        coordinator.actions = actions
        coordinator.onDismiss = onDismiss
        guard request != coordinator.shown else { return }
        coordinator.shown = request
        guard request != 0 else {
            coordinator.interaction?.dismissMenu()
            return
        }
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        configuration.preferredArrowDirection = .down
        coordinator.interaction?.presentEditMenu(with: configuration)
    }

    final class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        var interaction: UIEditMenuInteraction?
        var actions: [UIAction] = []
        var onDismiss: () -> Void = {}
        var shown = 0

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            UIMenu(children: actions)
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
            animator: any UIEditMenuInteractionAnimating
        ) {
            onDismiss()
        }
    }

    final class PassThroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
