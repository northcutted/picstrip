import AVFoundation
import SwiftUI

// MARK: - CameraZoomButtons

/// The Camera app's lens buttons: the lens in use shows the exact zoom in
/// yellow ("1.6×"); the others their lens (".5", "2", "4").
struct CameraZoomButtons: View {
    let levels: [CGFloat]
    /// The zoom now, as the Camera app labels it.
    let zoom: CGFloat
    let onSelect: (CGFloat) -> Void

    var body: some View {
        // The lens in use: the last one at or below the zoom.
        let current = levels.last { $0 <= zoom + 0.01 } ?? levels.first
        HStack(spacing: 6) {
            ForEach(levels, id: \.self) { level in
                let isCurrent = level == current
                Button {
                    onSelect(level)
                } label: {
                    Text(verbatim: isCurrent ? Self.label(zoom, suffix: true) : Self.label(level, suffix: false))
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? .yellow : .primary)
                        .frame(width: 34, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Zoom")
                .accessibilityValue(Text(verbatim: Self.label(level, suffix: true)))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .largeContent()
            }
        }
        .cameraChrome()
    }

    /// "1×", "1.6×"; ".5" and "2" on the lenses not in use, as in the Camera app.
    static func label(_ level: CGFloat, suffix: Bool) -> String {
        let text = Double(level).formatted(.number.precision(.fractionLength(0...1)))
        let short = level < 1 && text.hasPrefix("0") ? String(text.dropFirst()) : text
        return suffix ? text + "×" : short
    }
}

// MARK: - ExposureIndicator

/// The sun beside the focus square, with how far exposure was dragged.
struct ExposureIndicator: View {
    let bias: Float

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "sun.max.fill")
                .font(.body.weight(.semibold))
            if bias != 0 {
                Text(bias, format: .number.precision(.fractionLength(1)).sign(strategy: .always()))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.yellow)
        .shadow(radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - CameraFlipButton

/// Switches between the back and front cameras.
struct CameraFlipButton: View {
    let position: AVCaptureDevice.Position
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title3.weight(.semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(position == .back ? Text("Switch to the front camera") : Text("Switch to the back camera"))
        .largeContent()
        .cameraChrome()
    }
}

// MARK: - Camera chrome at large text sizes

extension View {
    /// The controls over and under the picture keep their size, as in the
    /// Camera app, so the picture stays in view.  At accessibility text sizes,
    /// touching and holding one shows it large instead (`largeContent()`).
    func cameraChrome() -> some View {
        dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// What the camera says on the picture grows, but only so far: past it,
    /// the words would cover what they describe.
    func cameraNote() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// Shown large by a touch and hold at accessibility text sizes — for
    /// controls that keep their size.
    func largeContent() -> some View {
        accessibilityShowsLargeContentViewer()
    }
}

// MARK: - Camera gestures

/// What the viewfinder's gestures do to the camera, for both of them: a
/// finger's (`cameraGestures`) and VoiceOver's (`viewfinderAccessibility`).
struct ViewfinderAdjustments {
    /// Focus at a point in the viewfinder's coordinates.
    let focus: (CGPoint) -> Void
    /// Zoom by a factor from where the pinch started, then end it.
    let pinch: (CGFloat) -> Void
    let endPinch: () -> Void
    /// Exposure by stops from where the drag started, then end it.
    let exposure: (Float) -> Void
    let endExposure: () -> Void
}

extension View {
    /// The Camera app's gestures on a viewfinder: tap to focus, pinch to zoom,
    /// and — after focusing — drag up or down for exposure.
    func cameraGestures(_ adjust: ViewfinderAdjustments) -> some View {
        contentShape(Rectangle())
            .onTapGesture { location in adjust.focus(location) }
            .gesture(
                MagnifyGesture()
                    .onChanged { adjust.pinch($0.magnification) }
                    .onEnded { _ in adjust.endPinch() }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag in
                        guard abs(drag.translation.height) > abs(drag.translation.width) else { return }
                        adjust.exposure(Float(-drag.translation.height / 120))
                    }
                    .onEnded { _ in adjust.endExposure() }
            )
    }

    /// The viewfinder as VoiceOver and Switch Control see it, with what the
    /// gestures above do for a finger: swipe up or down to zoom, and Brighter
    /// or Darker from the actions — focusing on the middle first when nothing
    /// is focused, as the exposure drag needs a focus point.
    func viewfinderAccessibility(_ adjust: ViewfinderAdjustments, zoom: CGFloat, center: CGPoint, isFocused: Bool) -> some View {
        let changeExposure = { (stops: Float) in
            if !isFocused { adjust.focus(center) }
            adjust.exposure(stops)
            adjust.endExposure()
        }
        return accessibilityElement(children: .ignore)
            .accessibilityLabel("Viewfinder")
            .accessibilityValue(Text("Zoom \(CameraZoomButtons.label(zoom, suffix: true))"))
            .accessibilityHint("Swipe up or down to zoom.")
            .accessibilityAdjustableAction { direction in
                adjust.pinch(direction == .increment ? 1.25 : 0.8)
                adjust.endPinch()
            }
            .accessibilityAction(named: Text("Brighter")) { changeExposure(0.5) }
            .accessibilityAction(named: Text("Darker")) { changeExposure(-0.5) }
            .accessibilityIdentifier("viewfinder")
    }
}

// MARK: - CameraFrameLayout

/// The Camera app's layout: the controls on the black above and below the
/// picture, and the picture fitted between them — so no control sits half on
/// the picture and half on the black.  `inPicture` is laid over the picture
/// itself, inside its edges: what is in view, and the lens buttons.
///
/// On a display wide enough for it (`CanvasLayout.sideBySide`: iPhone Duo's
/// inner display, unfolded) the bottom controls stand in a column beside the
/// picture, as in the Camera app held sideways, and the picture gets the
/// height the bar below would have taken.  `bottom` is told which, to lay
/// itself out across or down.  The same views either way, so folding or
/// unfolding the phone does not restart the viewfinder.
struct CameraFrameLayout<Top: View, Viewfinder: View, InPicture: View, Bottom: View>: View {
    /// The picture's width over its height, for a viewfinder of the given size.
    let aspect: (CGSize) -> CGFloat?
    /// The Camera Control's overlay is showing: everything but the picture makes way.
    let controlsHidden: Bool
    @ViewBuilder let top: () -> Top
    @ViewBuilder let viewfinder: () -> Viewfinder
    @ViewBuilder let inPicture: () -> InPicture
    @ViewBuilder let bottom: (CanvasLayout) -> Bottom

    @State private var size: CGSize = .zero

    var body: some View {
        let layout = CanvasLayout.resolve(for: size, isEligible: CanvasLayout.isEligibleDevice)
        let isSideBySide = layout == .sideBySide
        CameraFrameArrangement(isSideBySide: isSideBySide) {
            top()
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .opacity(controlsHidden ? 0 : 1)
                .allowsHitTesting(!controlsHidden)
            GeometryReader { geometry in
                let picture = CameraFrame.fitted(aspect(geometry.size), in: geometry.size)
                ZStack(alignment: .topLeading) {
                    viewfinder()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    inPicture()
                        .padding(12)
                        .frame(width: picture.width, height: picture.height)
                        .offset(x: picture.minX, y: picture.minY)
                        .opacity(controlsHidden ? 0 : 1)
                        .allowsHitTesting(!controlsHidden)
                }
            }
            bottom(layout)
                .padding(.horizontal, isSideBySide ? 16 : 20)
                .padding(.top, isSideBySide ? 8 : 12)
                .padding(.bottom, 8)
                .opacity(controlsHidden ? 0 : 1)
                .allowsHitTesting(!controlsHidden)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .animation(.easeInOut(duration: 0.2), value: controlsHidden)
    }
}

/// `CameraFrameLayout`'s three parts — the top bar, the picture, the bottom
/// controls — stacked down the screen, or with the bottom controls in a column
/// beside the other two.  The top and bottom take the room they need; the
/// picture takes the rest.
private struct CameraFrameArrangement: Layout {
    let isSideBySide: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (top, picture, bottom) = (subviews[0], subviews[1], subviews[2])
        // The bars are centred across the space they are given, as a VStack centres them.
        if isSideBySide {
            let columnWidth = min(bottom.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width, bounds.width / 2)
            let mainWidth = bounds.width - columnWidth
            let topHeight = top.sizeThatFits(ProposedViewSize(width: mainWidth, height: nil)).height
            top.place(
                at: CGPoint(x: bounds.minX + mainWidth / 2, y: bounds.minY),
                anchor: .top,
                proposal: ProposedViewSize(width: mainWidth, height: topHeight)
            )
            picture.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + topHeight),
                proposal: ProposedViewSize(width: mainWidth, height: max(0, bounds.height - topHeight))
            )
            bottom.place(
                at: CGPoint(x: bounds.maxX - columnWidth / 2, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
            )
        } else {
            let topHeight = top.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            let bottomHeight = bottom.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            top.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY),
                anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: topHeight)
            )
            picture.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + topHeight),
                proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - topHeight - bottomHeight))
            )
            bottom.place(
                at: CGPoint(x: bounds.midX, y: bounds.maxY),
                anchor: .bottom,
                proposal: ProposedViewSize(width: bounds.width, height: bottomHeight)
            )
        }
    }
}

nonisolated enum CameraFrame {
    /// The largest rectangle of `aspect` (width over height) centred in
    /// `size`, as the preview layer draws the picture; all of `size` without one.
    static func fitted(_ aspect: CGFloat?, in size: CGSize) -> CGRect {
        guard let aspect, aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}
