import CoreGraphics
import SwiftUI
import UIKit

/// How a screen arranges its picture and its controls in the space it has.
///
/// `.stacked` is the layout every screen was designed for: the picture above,
/// the controls below.  `.sideBySide` puts the controls in a column beside the
/// picture.  It is for iPhone Duo's inner display, unfolded — about 950 × 670
/// points, wide and only as tall as the folded phone — where stacking leaves
/// the picture a strip.  A phone in landscape is never tall enough for it
/// (iPhone 18 Pro Max is 440 points), the folded Duo is portrait, and iPad
/// keeps the layout it has always had.
nonisolated enum CanvasLayout: Equatable, Sendable {
    case stacked
    case sideBySide

    /// The space a side column needs: room for the picture beside it.
    static let minimumWidth: CGFloat = 700
    /// Taller than any phone in landscape, so only a display like the Duo's
    /// inner one qualifies.
    static let minimumHeight: CGFloat = 480

    /// The layout for content of `size` (inside the safe area).  `isEligible`
    /// is false on iPad, which keeps the stacked layout at every size.
    static func resolve(for size: CGSize, isEligible: Bool) -> CanvasLayout {
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

    /// iPhone — iPhone Duo is one — or, for UI tests that look at the side
    /// layout on an iPad simulator, any device.
    @MainActor static var isEligibleDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            || ProcessInfo.processInfo.environment["PICSTRIP_SIDE_LAYOUT_ON_ANY_DEVICE"] != nil
    }
}
