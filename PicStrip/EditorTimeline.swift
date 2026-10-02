import SwiftUI

// MARK: - EditorTimeline

/// The video's covers and sound edits laid out like a video editor's tracks:
/// a time ruler, a strip of frames, and a labelled lane each for faces, text,
/// objects and audio, with every cover or edit as a clip and the playhead
/// across them all.  Drag across the frames to move through the video, tap a
/// clip to select it, and drag the selected clip's yellow ends to change when
/// it applies.
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

    let duration: Double
    let time: Double
    let lanes: [Lane]
    let frames: [UIImage]
    /// The sound's loudness along the video, 0 … 1, drawn in the audio lane.
    let levels: [Float]
    let clips: [Clip]
    let selected: Set<String>
    /// The selected clip whose ends can be dragged.
    let trimmable: String?
    let onSeek: (Double) -> Void
    let onSelect: (Clip) -> Void
    let onTrim: (Clip, ClosedRange<Double>) -> Void

    static let labelWidth: CGFloat = 66
    private static let rulerHeight: CGFloat = 18
    private static let filmHeight: CGFloat = 40
    private static let laneHeight: CGFloat = 28
    private static let gap: CGFloat = 4
    private static let minimumLength = 0.1
    private static let handleColor = Color.yellow

    private enum Edge { case start, end }

    var body: some View {
        VStack(spacing: Self.gap) {
            row(label: nil) { scale in ruler(scale: scale) }
                .frame(height: Self.rulerHeight)
            row(label: Text("Video"), symbol: "film") { scale in filmstrip(scale: scale) }
                .frame(height: Self.filmHeight)
            ForEach(lanes) { lane in
                row(label: Text(lane.title), symbol: lane.symbol) { scale in laneView(lane, scale: scale) }
                    .frame(height: Self.laneHeight)
            }
        }
        .overlay(alignment: .topLeading) { playhead }
        .accessibilityElement(children: .contain)
    }

    private var totalHeight: CGFloat {
        Self.rulerHeight + Self.filmHeight + CGFloat(lanes.count) * Self.laneHeight + CGFloat(lanes.count + 1) * Self.gap
    }

    // MARK: Rows

    /// A lane: its label on the left, its track filling the rest.
    private func row<Track: View>(
        label: Text?, symbol: String? = nil,
        @ViewBuilder track: @escaping (_ scale: CGFloat) -> Track
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
                track(duration > 0 ? geometry.size.width / duration : 0)
            }
        }
    }

    private func ruler(scale: CGFloat) -> some View {
        let step = Self.tickStep(for: duration)
        let ticks = stride(from: 0.0, through: duration, by: step).map { $0 }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { tick in
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.tickLabel(tick, step: step))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle().fill(.secondary).frame(width: 1, height: 4)
                }
                .offset(x: tick * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrub(scale: scale))
        .accessibilityHidden(true)
    }

    private func filmstrip(scale: CGFloat) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width / CGFloat(max(frames.count, 1)), height: geometry.size.height)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.fill.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .contentShape(Rectangle())
        .gesture(scrub(scale: scale))
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(Text("\(VideoCleanerView.clock(time)) of \(VideoCleanerView.clock(duration))"))
        .accessibilityAdjustableAction { direction in
            onSeek(clamp(time + (direction == .increment ? 1 : -1)))
        }
        .accessibilityIdentifier("coverTimelineTrack")
    }

    private func laneView(_ lane: Lane, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.fill.quaternary)
                .contentShape(Rectangle())
                .gesture(scrub(scale: scale))
                .accessibilityHidden(true)
            if lane == .audio, !levels.isEmpty {
                waveform
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ForEach(clips.filter { $0.lane == lane }) { clip in
                clipView(clip, scale: scale)
            }
            if let trimmable, let clip = clips.first(where: { $0.id == trimmable && $0.lane == lane }) {
                handle(.start, of: clip, scale: scale)
                handle(.end, of: clip, scale: scale)
            }
        }
        .coordinateSpace(.named(Self.laneSpace))
    }

    private static let laneSpace = "timelineLane"

    private var waveform: some View {
        Canvas { context, size in
            let width = size.width / CGFloat(levels.count)
            for (index, level) in levels.enumerated() {
                let height = max(1, CGFloat(level) * (size.height - 6))
                let bar = CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2, width: max(1, width - 0.5), height: height)
                context.fill(Path(bar), with: .color(.secondary.opacity(0.45)))
            }
        }
    }

    private func clipView(_ clip: Clip, scale: CGFloat) -> some View {
        let width = max(6, (clip.range.upperBound - clip.range.lowerBound) * scale)
        let isSelected = selected.contains(clip.id)
        return Button {
            onSelect(clip)
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
        }
        .buttonStyle(.plain)
        .offset(x: clip.range.lowerBound * scale, y: 3)
        .accessibilityLabel(Text(clip.label))
        .accessibilityValue(Text("\(VideoCleanerView.clock(clip.range.lowerBound)) – \(VideoCleanerView.clock(clip.range.upperBound))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("clip-\(clip.id)")
    }

    // MARK: Playhead

    private var playhead: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width - Self.labelWidth
            let x = Self.labelWidth + (duration > 0 ? time / duration * trackWidth : 0)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: totalHeight)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red)
                    .frame(width: 10, height: 12)
            }
            .offset(x: x - 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(height: totalHeight)
    }

    // MARK: Gestures

    private func scrub(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard scale > 0 else { return }
                onSeek(clamp(value.location.x / scale))
            }
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
    private func handle(_ edge: Edge, of clip: Clip, scale: CGFloat) -> some View {
        let value = edge == .start ? clip.range.lowerBound : clip.range.upperBound
        return RoundedRectangle(cornerRadius: 3)
            .fill(Self.handleColor)
            .frame(width: 10, height: Self.laneHeight)
            .overlay(Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 12))
            .frame(width: 44, height: Self.laneHeight)
            .contentShape(Rectangle())
            .offset(x: value * scale - 22)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.laneSpace))
                    .onChanged { drag in
                        guard scale > 0 else { return }
                        let range = trimmed(clip, moving: edge, to: drag.location.x / scale)
                        onTrim(clip, range)
                        onSeek(edge == .start ? range.lowerBound : range.upperBound)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? Text("Cover starts") : Text("Cover ends"))
            .accessibilityValue(Text(VideoCleanerView.clock(value)))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                onTrim(clip, trimmed(clip, moving: edge, to: value + step))
            }
            .accessibilityIdentifier(edge == .start ? "coverStartHandle" : "coverEndHandle")
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
}
