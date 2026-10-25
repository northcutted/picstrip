import CoreGraphics
import SwiftUI
import XCTest
@testable import PicStrip

/// Where the photo editor and the camera put their controls: below the
/// picture, or — on iPhone Duo's inner display — beside it.
final class CanvasLayoutTests: XCTestCase {

    // Content sizes inside the safe area, below a navigation bar where there is one.

    func testPhonesStayStackedInEitherOrientation() {
        // iPhone 18 Pro Max upright and on its side, iPhone 17 Pro, iPhone SE.
        for size in [CGSize(width: 440, height: 816), CGSize(width: 956, height: 386),
                     CGSize(width: 402, height: 778), CGSize(width: 667, height: 343)] {
            XCTAssertEqual(CanvasLayout.resolve(for: size, isEligible: true), .stacked, "\(size)")
        }
    }

    func testTheFoldedDuoIsStacked() {
        // The outer display is portrait only; the vertical bar takes a strip of its width.
        XCTAssertEqual(CanvasLayout.resolve(for: CGSize(width: 382, height: 610), isEligible: true), .stacked)
        XCTAssertEqual(CanvasLayout.resolve(for: CGSize(width: 466, height: 678), isEligible: true), .stacked)
    }

    func testTheUnfoldedDuoPutsTheControlsBeside() {
        // The inner display, 951 × 669, with and without the vertical bar and a navigation bar.
        XCTAssertEqual(CanvasLayout.resolve(for: CGSize(width: 951, height: 669), isEligible: true), .sideBySide)
        XCTAssertEqual(CanvasLayout.resolve(for: CGSize(width: 867, height: 590), isEligible: true), .sideBySide)
        // Turned upright it is a large phone.
        XCTAssertEqual(CanvasLayout.resolve(for: CGSize(width: 669, height: 900), isEligible: true), .stacked)
    }

    func testIPadKeepsItsLayout() {
        for size in [CGSize(width: 1376, height: 960), CGSize(width: 1032, height: 1300), CGSize(width: 951, height: 669)] {
            XCTAssertEqual(CanvasLayout.resolve(for: size, isEligible: false), .stacked, "\(size)")
        }
    }

    func testNoSizeYetIsStacked() {
        XCTAssertEqual(CanvasLayout.resolve(for: .zero, isEligible: true), .stacked)
    }

    func testTheColumnStartsAtTheFold() {
        // Vertical bar on the trailing side: content 0…867 in a 951-point window.
        let window = CGRect(x: 0, y: 0, width: 951, height: 669)
        let trailingBar = CGRect(x: 0, y: 50, width: 867, height: 600)
        XCTAssertEqual(CanvasLayout.sideColumnWidth(content: trailingBar, window: window), 867 - 475.5, accuracy: 0.001)
        // On the leading side the fold is further into the content: the column
        // is as wide as allowed, the picture as close to the fold as that lets it.
        let leadingBar = CGRect(x: 84, y: 50, width: 867, height: 600)
        XCTAssertEqual(CanvasLayout.sideColumnWidth(content: leadingBar, window: window), 475.5, accuracy: 0.001)
        // Right to left, the column is on the left, from the content's edge to the fold.
        XCTAssertEqual(
            CanvasLayout.sideColumnWidth(content: trailingBar, window: window, layoutDirection: .rightToLeft),
            475.5, accuracy: 0.001
        )
    }

    func testTheColumnStaysUsable() {
        let window = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        // Far past the fold on a big window: no wider than the range.
        XCTAssertEqual(CanvasLayout.sideColumnWidth(content: CGRect(x: 0, y: 0, width: 1376, height: 960), window: window), 480)
        // Before anything is measured, or with the fold beyond the content: the narrowest.
        XCTAssertEqual(CanvasLayout.sideColumnWidth(content: .zero, window: .zero), 320)
        XCTAssertEqual(CanvasLayout.sideColumnWidth(content: CGRect(x: 0, y: 0, width: 700, height: 500), window: CGRect(x: 0, y: 0, width: 1600, height: 500)), 320)
        // Never so wide that the picture is narrower than the narrowest column.
        XCTAssertEqual(CanvasLayout.sideColumnWidth(content: CGRect(x: 0, y: 0, width: 720, height: 500), window: CGRect(x: 0, y: 0, width: 100, height: 500)), 400)
    }
}
