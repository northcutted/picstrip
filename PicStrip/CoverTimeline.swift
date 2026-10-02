import SwiftUI

// MARK: - CoverTimeline

/// When each cover is on, under the video preview: a lane each for faces, text
/// and drawn covers, and the playhead.  Tap or drag to move the playhead; the
/// selected cover's ends can be dragged to start it earlier or end it later.
struct CoverTimeline: View {
    struct Item: Identifiable, Equatable {
        let id: String
        /// 0 faces, 1 text and codes, 2 drawn covers.
        let lane: Int
        let range: ClosedRange<Double>
        let color: Color
    }

    let duration: Double
    let time: Double
    let items: [Item]
    /// The cover picked in the list, outlined; it has handles when `onTrim` is set.
    let selected: [Item]
    let onSeek: (Double) -> Void
    let onTrim: ((ClosedRange<Double>) -> Void)?

    private static let height: CGFloat = 56
    private static let laneHeight: CGFloat = 6
    private static let minimumLength = 0.1

    private enum Edge { case start, end }

    var body: some View {
        GeometryReader { geometry in
            let scale = duration > 0 ? geometry.size.width / duration : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.fill.tertiary)
                    .accessibilityElement()
                    .accessibilityLabel("Timeline")
                    .accessibilityValue(Text("\(VideoCleanerView.clock(time)) of \(VideoCleanerView.clock(duration))"))
                    .accessibilityAdjustableAction { direction in
                        onSeek(clamp(time + (direction == .increment ? 1 : -1)))
                    }
                    .accessibilityIdentifier("coverTimelineTrack")

                ForEach(items) { item in
                    let isPicked = selected.contains { $0.id == item.id }
                    Capsule()
                        .fill(item.color.opacity(selected.isEmpty || isPicked ? 0.9 : 0.35))
                        .frame(width: max(4, (item.range.upperBound - item.range.lowerBound) * scale), height: Self.laneHeight)
                        .offset(x: item.range.lowerBound * scale, y: laneY(item.lane))
                        .accessibilityHidden(true)
                }

                ForEach(selected) { item in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(item.color.opacity(0.12))
                        .strokeBorder(item.color, lineWidth: 2)
                        .frame(width: max(8, (item.range.upperBound - item.range.lowerBound) * scale), height: Self.height)
                        .offset(x: item.range.lowerBound * scale)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: Self.height + 8)
                    .offset(x: time * scale - 1, y: -4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if onTrim != nil, selected.count == 1, let item = selected.first {
                    handle(.start, of: item, scale: scale)
                    handle(.end, of: item, scale: scale)
                }
            }
            .coordinateSpace(.named("timeline"))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        guard scale > 0 else { return }
                        onSeek(clamp(value.location.x / scale))
                    }
            )
        }
        .frame(height: Self.height)
        .animation(.snappy, value: selected)
    }

    private func laneY(_ lane: Int) -> CGFloat {
        let spacing = (Self.height - 3 * Self.laneHeight) / 4
        return spacing + CGFloat(lane) * (Self.laneHeight + spacing)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(0, value), duration)
    }

    private func trimmed(_ item: Item, moving edge: Edge, to value: Double) -> ClosedRange<Double> {
        switch edge {
        case .start:
            let lower = min(clamp(value), item.range.upperBound - Self.minimumLength)
            return max(0, lower)...item.range.upperBound
        case .end:
            let upper = max(clamp(value), item.range.lowerBound + Self.minimumLength)
            return item.range.lowerBound...min(duration, upper)
        }
    }

    /// A grip on one end of the selected cover, with a full-size touch target.
    private func handle(_ edge: Edge, of item: Item, scale: CGFloat) -> some View {
        let value = edge == .start ? item.range.lowerBound : item.range.upperBound
        return Capsule()
            .fill(item.color)
            .frame(width: 12, height: Self.height)
            .overlay(Capsule().fill(.white).frame(width: 2, height: 18))
            .frame(width: 44, height: Self.height)
            .contentShape(Rectangle())
            .offset(x: value * scale - 22)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { drag in
                        guard scale > 0 else { return }
                        let range = trimmed(item, moving: edge, to: drag.location.x / scale)
                        onTrim?(range)
                        onSeek(edge == .start ? range.lowerBound : range.upperBound)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? Text("Cover starts") : Text("Cover ends"))
            .accessibilityValue(Text(VideoCleanerView.clock(value)))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                onTrim?(trimmed(item, moving: edge, to: value + step))
            }
            .accessibilityIdentifier(edge == .start ? "coverStartHandle" : "coverEndHandle")
    }
}
