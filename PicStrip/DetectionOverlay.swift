import SwiftUI

// MARK: - DetectionBox

/// A finding as PicStrip outlines it over a picture — in the viewfinder and
/// while a video is scanned: its risk colour, a light fill, a soft glow, and an
/// outline that shows the match strength.
struct DetectionBox: View {
    let type: PIIType
    let confidence: ConfidenceLevel

    var body: some View {
        let color = type.riskLevel.color
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.opacity(0.16))
            .strokeBorder(color, style: Self.outline(for: confidence))
            .shadow(color: color.opacity(0.6), radius: 5)
    }

    /// Match strength at a glance, even where a finding only has a badge: a
    /// strong match is outlined solid, a possible one dashed, a tentative one dotted.
    static func outline(for confidence: ConfidenceLevel) -> StrokeStyle {
        switch confidence {
        case .high:   return StrokeStyle(lineWidth: 2)
        case .medium: return StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 4])
        case .low:    return StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 4])
        }
    }
}

// MARK: - DetectionBadge

/// A finding's kind, in a circle of its risk colour, where there is no room
/// for a label.
struct DetectionBadge: View {
    let type: PIIType

    var body: some View {
        Image(systemName: type.symbolName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(type.riskLevel.color, in: Circle())
    }
}

// MARK: - ReadingLines

/// A hairline around every line of text read — what PicStrip sees, sensitive or
/// not.  Rects in view points.
struct ReadingLines: View {
    let lines: [CGRect]

    var body: some View {
        Canvas { context, _ in
            for line in lines {
                let path = Path(roundedRect: line.insetBy(dx: -2, dy: -1), cornerRadius: 3)
                context.fill(path, with: .color(.white.opacity(0.08)))
                context.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
