import CoreGraphics
import SwiftUI
import UIKit

/// How a screen arranges its picture and its controls in the space it has.
///
/// `.stacked` is the layout every screen was designed for: the picture above,
/// the controls below.  `.sideBySide` puts the controls in a column beside the
/// picture.  It is for iPhone Duo's inner display, unfolded — about 950 × 670
/// points, wide and only as tall as the folded phone — where stacking leaves
/// the picture a strip. Wide iPad windows use the same inspector. Active
/// system divisions take precedence over these size-based defaults.
nonisolated enum CanvasLayout: Equatable, Sendable {
    case stacked
    case sideBySide
    /// A horizontal active fold: picture above, controls on the lower half.
    case tabletop

    /// The space a side column needs: room for the picture beside it.
    static let minimumWidth: CGFloat = 700
    /// Taller than any phone in landscape, so only a display like the Duo's
    /// inner one qualifies.
    static let minimumHeight: CGFloat = 480

    /// The layout for content of `size` (inside the safe area).
    static func resolve(for size: CGSize, isEligible: Bool, division: CGRect? = nil) -> CanvasLayout {
        if let division, size.width > 0, size.height > 0 {
            if division.height > size.height / 2, division.midX > 100, division.midX < size.width - 100 { return .sideBySide }
            if division.width > size.width / 2, division.midY > 100, division.midY < size.height - 100 { return .tabletop }
        }
        guard isEligible,
              size.width > size.height,
              size.width >= minimumWidth,
              size.height >= minimumHeight
        else { return .stacked }
        return .sideBySide
    }

    /// The width of the controls column beside a picture, for content at
    /// `content` in a window at `window` (both in the window's coordinates).
    ///
    /// The Duo's inner display folds down its middle, so the column starts at
    /// the middle of the window — the picture stays on one half, clear of the
    /// fold — as long as that leaves the column a width in `range` and the
    /// picture at least `range.lowerBound`.  In a right-to-left layout the
    /// column is on the left.
    static func sideColumnWidth(
        content: CGRect,
        window: CGRect,
        layoutDirection: LayoutDirection = .leftToRight,
        range: ClosedRange<CGFloat> = 320...480
    ) -> CGFloat {
        let toFold = layoutDirection == .rightToLeft ? window.midX - content.minX : content.maxX - window.midX
        let widest = max(range.lowerBound, min(range.upperBound, content.width - range.lowerBound))
        return min(max(toFold, range.lowerBound), widest)
    }

    /// Phones and iPads can use the wide layout. Narrow windows stay stacked.
    @MainActor static var isEligibleDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || UIDevice.current.userInterfaceIdiom == .pad
            || ProcessInfo.processInfo.environment["PICSTRIP_SIDE_LAYOUT_ON_ANY_DEVICE"] != nil
    }
}

/// The system's active division, expanded by its recommended margins, in the
/// canvas's physical coordinates. Fully open devices have no active division.
nonisolated struct CanvasPanes: Equatable, Sendable {
    let picture: CGFloat
    let controls: CGFloat
    let gap: CGFloat
}

nonisolated struct CanvasGeometry: Equatable, Sendable {
    var frame: CGRect = .zero
    var division: CGRect?

    static func measured(frame: CGRect, division: CGRect? = nil) -> CanvasGeometry {
#if DEBUG
        // Exercises active divisions on ordinary CI simulators. The shipping
        // build only consumes the operating system's reserved regions.
        switch ProcessInfo.processInfo.environment["PICSTRIP_TEST_DIVISION_AXIS"] {
        case "vertical":
            return CanvasGeometry(frame: frame, division: CGRect(x: frame.width / 2 - 12, y: 0, width: 24, height: frame.height))
        case "horizontal":
            return CanvasGeometry(frame: frame, division: CGRect(x: 0, y: frame.height / 2 - 12, width: frame.width, height: 24))
        default: break
        }
#endif
        return CanvasGeometry(frame: frame, division: division)
    }

    @MainActor var layout: CanvasLayout {
        CanvasLayout.resolve(for: frame.size, isEligible: CanvasLayout.isEligibleDevice, division: division)
    }

    func panes(layoutDirection: LayoutDirection) -> CanvasPanes? {
        guard let division,
              CanvasLayout.resolve(for: frame.size, isEligible: false, division: division) != .stacked else { return nil }
        let horizontal = division.height > frame.height / 2
        let start = max(0, horizontal ? division.minX : division.minY)
        let end = min(horizontal ? frame.width : frame.height, horizontal ? division.maxX : division.maxY)
        let length = horizontal ? frame.width : frame.height
        if horizontal && layoutDirection == .rightToLeft {
            return CanvasPanes(picture: max(0, length - end), controls: start, gap: max(0, end - start))
        }
        return CanvasPanes(picture: start, controls: max(0, length - end), gap: max(0, end - start))
    }
}

extension View {
    /// Kept behind an SDK flag so the iOS 26 compatibility build still compiles.
    /// Geometry, including active division regions, drives layout; hinge angle
    /// is deliberately not used as a proxy for usable space.
    @ViewBuilder
    func onCanvasGeometryChange(_ action: @escaping (CanvasGeometry) -> Void) -> some View {
#if PICSTRIP_FOLD_APIS
        if #available(iOS 27.1, *) {
            onGeometryChange(for: CanvasGeometry.self) { proxy in
                let region = proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).first
                let division = region.map { region in
                    let margin = region.margins
                    return region.frame.inset(by: UIEdgeInsets(top: -margin.top, left: -margin.leading,
                                                               bottom: -margin.bottom, right: -margin.trailing))
                }
                return CanvasGeometry.measured(frame: proxy.frame(in: .global), division: division)
            } action: { action($0) }
        } else {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action(CanvasGeometry.measured(frame: $0)) }
        }
#else
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action(CanvasGeometry.measured(frame: $0)) }
#endif
    }
}
