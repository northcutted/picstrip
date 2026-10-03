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
            }
        }
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
    }
}

// MARK: - Camera gestures

extension View {
    /// The Camera app's gestures on a viewfinder: tap to focus, pinch to zoom,
    /// and — after focusing — drag up or down for exposure.
    func cameraGestures(
        focus: @escaping (CGPoint) -> Void,
        pinch: @escaping (CGFloat) -> Void,
        endPinch: @escaping () -> Void,
        exposure: @escaping (Float) -> Void,
        endExposure: @escaping () -> Void
    ) -> some View {
        contentShape(Rectangle())
            .onTapGesture { location in focus(location) }
            .gesture(
                MagnifyGesture()
                    .onChanged { pinch($0.magnification) }
                    .onEnded { _ in endPinch() }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag in
                        guard abs(drag.translation.height) > abs(drag.translation.width) else { return }
                        exposure(Float(-drag.translation.height / 120))
                    }
                    .onEnded { _ in endExposure() }
            )
    }
}
