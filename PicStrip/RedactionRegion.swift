import CoreGraphics
import Foundation
import SwiftUI

// MARK: - RedactionColor SwiftUI extension
//
// `RedactionColor` and `RedactionStyle` are defined in ImageRedactor.swift so
// they compile in both the main app target and the Share Extension.  The SwiftUI
// `color` property is main-app-only and lives here.

extension RedactionColor {
    /// SwiftUI colour used in the editing overlay.
    var color: Color {
        switch self {
        case .black:    return .black
        case .charcoal: return Color(white: 0.20)
        case .white:    return .white
        case .red:      return Color(red: 0.88, green: 0.10, blue: 0.10)
        case .orange:   return Color(red: 0.95, green: 0.45, blue: 0.05)
        case .yellow:   return Color(red: 0.95, green: 0.82, blue: 0.04)
        case .green:    return Color(red: 0.08, green: 0.60, blue: 0.15)
        case .teal:     return Color(red: 0.04, green: 0.62, blue: 0.62)
        case .blue:     return Color(red: 0.10, green: 0.38, blue: 0.90)
        case .navy:     return Color(red: 0.08, green: 0.13, blue: 0.33)
        case .purple:   return Color(red: 0.52, green: 0.08, blue: 0.80)
        case .pink:     return Color(red: 0.95, green: 0.18, blue: 0.55)
        }
    }

    /// `true` for colours light enough to need a dark (black) checkmark/label.
    var isLight: Bool {
        switch self {
        case .white, .yellow: return true
        default:              return false
        }
    }
}

// MARK: - RedactionRegionSource

enum RedactionRegionSource: String, Codable, Equatable {
    case detected
    case custom
}

// MARK: - RedactionRegion

struct RedactionRegion: Identifiable, Hashable {
    let id: String
    var rect: CGRect
    var source: RedactionRegionSource
    var type: PIIType?
    var subtype: PIISubtype?
    var score: Double?
    var snippet: String?
    var isEnabled: Bool
    /// Visual style applied when this region is burned onto the exported image.
    var style: RedactionStyle = .solid
    /// Fill colour for this region. Ignored when `style == .pixelate`.
    var color: RedactionColor = .black

    var displayName: String {
        subtype?.displayName ?? type?.description ?? "Custom Redaction"
    }

    var confidence: ConfidenceLevel? {
        score.map(ConfidenceLevel.init(score:))
    }

    var scorePercent: Int? {
        score.map { Int(round($0 * 100)) }
    }

    /// Converts this region into a `RedactionSpec` suitable for the rendering pipeline.
    var spec: RedactionSpec {
        RedactionSpec(rect: rect, style: style, color: color, isEnabled: isEnabled)
    }

    static func detected(
        result: DetectionResult,
        instance: DetectedInstance,
        index: Int,
        isEnabled: Bool = true
    ) -> RedactionRegion {
        RedactionRegion(
            id: "detected-\(result.type.id)-\(index)",
            rect: Self.clamped(instance.boundingBox),
            source: .detected,
            type: result.type,
            subtype: instance.subtype,
            score: instance.score,
            snippet: instance.snippet,
            isEnabled: isEnabled
        )
    }

    static func custom(rect: CGRect) -> RedactionRegion {
        RedactionRegion(
            id: "custom-\(UUID().uuidString)",
            rect: Self.clamped(rect),
            source: .custom,
            type: nil,
            subtype: nil,
            score: nil,
            snippet: nil,
            isEnabled: true
        )
    }

    static func clamped(_ rect: CGRect, minimumSize: CGFloat = 0.015) -> CGRect {
        let width = min(max(rect.width, minimumSize), 1)
        let height = min(max(rect.height, minimumSize), 1)
        let x = min(max(rect.minX, 0), max(0, 1 - width))
        let y = min(max(rect.minY, 0), max(0, 1 - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        clamped(rect.offsetBy(dx: delta.width, dy: delta.height))
    }

    static func resized(_ rect: CGRect, by delta: CGSize) -> CGRect {
        clamped(CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width + delta.width,
            height: rect.height + delta.height
        ))
    }
}
