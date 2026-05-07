import SwiftUI
import UIKit

struct ZoomableImagePreview: View {
    let image: UIImage
    var highlightedResults: [DetectionResult] = []
    var focusedResult: DetectionResult?
    var isScanning: Bool = false
    var showZoomHint: Bool = true
    var accessibilityIdentifier: String = "metadataPhotoPreview"
    var onTap: (() -> Void)?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var focusPulse = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var imageSize: CGSize { image.size == .zero ? CGSize(width: 1, height: 1) : image.size }

    private var previewAccessibilityValue: String {
        if let focusedResult {
            return "Focused \(focusedResult.type.description)"
        }

        let regionCount = highlightedResults.reduce(0) { $0 + $1.matchCount }
        guard regionCount > 0 else { return "No sensitive data highlighted" }
        return "\(regionCount) sensitive data region\(regionCount == 1 ? "" : "s") highlighted"
    }

    var body: some View {
        GeometryReader { geo in
            let fittedSize = fittedImageSize(in: geo.size)

            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    imageLayer(size: fittedSize)
                        .scaleEffect(scale)
                        .offset(offset)
                        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: scale)
                        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: offset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .gesture(zoomGesture(container: geo.size, image: fittedSize))
                .simultaneousGesture(panGesture(container: geo.size, image: fittedSize))
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    resetZoom()
                })
                .simultaneousGesture(TapGesture().onEnded {
                    onTap?()
                })

                if showZoomHint {
                    Label(scale > 1.01 ? "Double tap to reset" : "Pinch to zoom", systemImage: "hand.draw")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo preview")
        .accessibilityValue(previewAccessibilityValue)
        .accessibilityHint("Pinch to zoom and drag to pan")
        .accessibilityIdentifier(accessibilityIdentifier)
        .onChange(of: image) { _, _ in resetZoom() }
        .onChange(of: focusedResult?.id) { _, _ in pulseFocusedResult() }
    }

    private func imageLayer(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)

            if !highlightedResults.isEmpty {
                detectionOverlay(results: highlightedResults, size: size, style: .subtle)
            }

            if let focusedResult {
                detectionOverlay(results: [focusedResult], size: size, style: .focused)
            }

            if isScanning {
                PhotoScanSweep(reduceMotion: reduceMotion)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private enum DetectionOverlayStyle: Equatable {
        case subtle
        case focused
    }

    private func detectionOverlay(
        results: [DetectionResult],
        size: CGSize,
        style: DetectionOverlayStyle
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(results) { result in
                ForEach(result.instances) { instance in
                    let box = instance.boundingBox
                    RoundedRectangle(cornerRadius: style == .focused ? 4 : 2)
                        .strokeBorder(
                            style == .focused ? Color.red : Color.orange,
                            lineWidth: style == .focused ? (focusPulse ? 4 : 2.5) : 1.5
                        )
                        .background(
                            RoundedRectangle(cornerRadius: style == .focused ? 4 : 2)
                                .fill((style == .focused ? Color.red : Color.orange).opacity(style == .focused ? 0.22 : 0.10))
                        )
                        .shadow(
                            color: style == .focused ? Color.red.opacity(focusPulse ? 0.45 : 0.22) : Color.clear,
                            radius: style == .focused ? 8 : 0
                        )
                        .frame(
                            width: box.width * size.width,
                            height: box.height * size.height
                        )
                        .scaleEffect(style == .focused && focusPulse ? 1.04 : 1)
                        .offset(
                            x: box.minX * size.width,
                            y: box.minY * size.height
                        )
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: highlightedResults)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: focusedResult)
    }

    private func zoomGesture(container: CGSize, image: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = clamp(lastScale * value, min: 1, max: 5)
                offset = clamped(offset, container: container, image: image, scale: scale)
            }
            .onEnded { _ in
                scale = clamp(scale, min: 1, max: 5)
                if scale <= 1.01 {
                    resetZoom()
                } else {
                    offset = clamped(offset, container: container, image: image, scale: scale)
                    lastScale = scale
                    lastOffset = offset
                }
            }
    }

    private func panGesture(container: CGSize, image: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard scale > 1.01 else { return }
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clamped(proposed, container: container, image: image, scale: scale)
            }
            .onEnded { _ in
                offset = clamped(offset, container: container, image: image, scale: scale)
                lastOffset = offset
            }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func pulseFocusedResult() {
        guard focusedResult != nil else {
            focusPulse = false
            return
        }

        guard !reduceMotion else {
            focusPulse = false
            return
        }

        focusPulse = false
        withAnimation(.easeOut(duration: 0.18)) {
            focusPulse = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard focusedResult != nil else { return }
            withAnimation(.easeInOut(duration: 0.55)) {
                focusPulse = false
            }
        }
    }

    private func fittedImageSize(in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height

        if imageAspect > containerAspect {
            let width = container.width
            return CGSize(width: width, height: width / imageAspect)
        } else {
            let height = container.height
            return CGSize(width: height * imageAspect, height: height)
        }
    }

    private func clamped(_ proposed: CGSize, container: CGSize, image: CGSize, scale: CGFloat) -> CGSize {
        let maxX = max(0, (image.width * scale - container.width) / 2)
        let maxY = max(0, (image.height * scale - container.height) / 2)
        return CGSize(
            width: clamp(proposed.width, min: -maxX, max: maxX),
            height: clamp(proposed.height, min: -maxY, max: maxY)
        )
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}

private struct PhotoScanSweep: View {
    let reduceMotion: Bool
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.green.opacity(reduceMotion ? 0.08 : 0.03)

                if reduceMotion {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.green.opacity(0.45), lineWidth: 2)
                } else {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color.green.opacity(0.85), location: 0.5),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 26)
                        .shadow(color: .green.opacity(0.45), radius: 10)
                        .offset(y: sweep ? geo.size.height + 20 : -40)
                        .onAppear {
                            sweep = false
                            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                                sweep = true
                            }
                        }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
