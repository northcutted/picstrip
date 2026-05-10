import SwiftUI
import UIKit

// MARK: - Coordinate transform helper

/// Converts a raw touch point (in the outer container's coordinate space) into
/// a normalised (0…1, 0…1) position within the displayed image.
///
/// This accounts for three sources of offset that the previous implementation
/// ignored, causing drawn redaction boxes to land in the wrong place:
///
/// 1. **Centering offset** – the fitted image is centred inside its container,
///    so the image's top-left is at `((containerW − imageW⋅scale)/2, …)`.
/// 2. **Zoom scale** – when the user has pinched in, each image point spans
///    `scale` screen points; dividing by `scale` converts back to image points.
/// 3. **Pan offset** – the user may have dragged the image away from centre.
///
/// - Parameters:
///   - point:         Touch location in the outer container's coordinate space.
///   - imageSize:     Fitted (displayed) image size in points.
///   - containerSize: Full size of the gesture-receiving container view.
///   - scale:         Current zoom scale (1 = no zoom).
///   - panOffset:     Current pan translation applied to the image layer.
/// - Returns: Normalised (x, y) in image space. Values outside [0, 1] indicate
///   a touch outside the image bounds (callers should clamp as needed).
func imageNormalizedPoint(
    _ point: CGPoint,
    imageSize: CGSize,
    containerSize: CGSize,
    scale: CGFloat = 1,
    panOffset: CGSize = .zero
) -> CGPoint {
    // The image layer is centred in the container and scaled around that centre.
    let originX = (containerSize.width  - imageSize.width  * scale) / 2 + panOffset.width
    let originY = (containerSize.height - imageSize.height * scale) / 2 + panOffset.height
    return CGPoint(
        x: (point.x - originX) / (scale * imageSize.width),
        y: (point.y - originY) / (scale * imageSize.height)
    )
}

// MARK: - ZoomableImagePreview

struct ZoomableImagePreview: View {
    let image: UIImage
    var highlightedResults: [DetectionResult] = []
    var focusedResult: DetectionResult?
    var redactionRegions: [RedactionRegion] = []
    var selectedRedactionRegionID: Binding<String?>?
    var isRedactionEditing: Bool = false
    var isAddingRedaction: Bool = false
    var resetZoomRequest: Int = 0
    var isScanning: Bool = false
    var showZoomHint: Bool = true
    var accessibilityIdentifier: String = "metadataPhotoPreview"
    var onTap: (() -> Void)?
    var onAddRedaction: ((CGRect) -> Void)?
    var onBeginUpdateRedaction: ((String) -> Void)?
    var onUpdateRedaction: ((String, CGRect) -> Void)?
    var onSelectRedaction: ((String?) -> Void)?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var focusPulse = false
    @State private var draftRedactionRect: CGRect?
    @State private var dragStartRect: CGRect?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var imageSize: CGSize { image.size == .zero ? CGSize(width: 1, height: 1) : image.size }

    private var previewAccessibilityValue: String {
        if let focusedResult {
            return String(localized: "Focused \(focusedResult.type.description)")
        }

        let regionCount = redactionRegions.isEmpty
            ? highlightedResults.reduce(0) { $0 + $1.matchCount }
            : redactionRegions.filter(\.isEnabled).count
        guard regionCount > 0 else { return String(localized: "No sensitive data highlighted") }
        return String(localized: "^[\(regionCount) sensitive data region](inflect: true) highlighted")
    }

    var body: some View {
        GeometryReader { geo in
            let fittedSize = fittedImageSize(in: geo.size)

            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    imageLayer(size: fittedSize)
                        .scaleEffect(scale)
                        .offset(offset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .gesture(zoomGesture(container: geo.size, image: fittedSize))
                .simultaneousGesture(panGesture(container: geo.size, image: fittedSize))
                .simultaneousGesture(addRedactionGesture(image: fittedSize, container: geo.size))
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    resetZoom()
                })
                // Use a regular (non-simultaneous) gesture for the single-tap deselect/tap-through.
                // Unlike simultaneousGesture, a regular .gesture() FAILS when a child view's own
                // gesture fires — so tapping a region selects it instead of immediately deselecting.
                .gesture(TapGesture().onEnded {
                    if isRedactionEditing {
                        selectRedaction(nil)
                    } else {
                        onTap?()
                    }
                })

                if showZoomHint {
                    Label(zoomHintText, systemImage: isAddingRedaction ? "plus.square.dashed" : "hand.draw")
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
        .onChange(of: isAddingRedaction) { _, _ in draftRedactionRect = nil }
        .onChange(of: resetZoomRequest) { _, _ in resetZoom() }
    }

    // MARK: - Image layer

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

            if !redactionRegions.isEmpty {
                redactionRegionOverlay(size: size)
            }

            // Draft box while the user is still drawing a new redaction.
            // Uses .position() so the hit-test frame is also at the right location.
            if let draftRedactionRect {
                redactionShape(
                    rect: draftRedactionRect,
                    size: size,
                    isSelected: true,
                    isEnabled: true,
                    overlayColor: .accentColor
                )
                .allowsHitTesting(false)
                .position(
                    x: (draftRedactionRect.minX + draftRedactionRect.width  / 2) * size.width,
                    y: (draftRedactionRect.minY + draftRedactionRect.height / 2) * size.height
                )
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

    // MARK: - Zoom hint

    private var zoomHintText: String {
        if isAddingRedaction {
            return "Drag to redact"
        }
        if isRedactionEditing {
            return "Drag boxes to adjust"
        }
        return scale > 1.01 ? "Double tap to reset" : "Pinch to zoom"
    }

    // MARK: - Detection overlay (display-only, no gestures)

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
                        // .offset() is fine here — detection overlays are display-only
                        // and never have gesture targets that need correct hit-testing.
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

    // MARK: - Gestures

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
                guard scale > 1.01, !isAddingRedaction else { return }
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

    /// Drag-to-draw gesture for adding a new custom redaction box.
    ///
    /// `container` is passed so `normalizedRect` can correct for the centering
    /// offset and the current zoom/pan state — the gesture lives on the full
    /// container view, not the image view itself.
    private func addRedactionGesture(image: CGSize, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard isRedactionEditing, isAddingRedaction else { return }
                draftRedactionRect = normalizedRect(
                    from: value.startLocation,
                    to: value.location,
                    image: image,
                    container: container
                )
            }
            .onEnded { value in
                guard isRedactionEditing, isAddingRedaction else { return }
                let rect = normalizedRect(
                    from: value.startLocation,
                    to: value.location,
                    image: image,
                    container: container
                )
                draftRedactionRect = nil
                guard rect.width >= 0.015, rect.height >= 0.015 else { return }
                onAddRedaction?(rect)
            }
    }

    // MARK: - Redaction overlay

    /// Interactive overlay layer for existing redaction regions.
    ///
    /// Each region uses `.position()` (not `.offset()`) to place both its
    /// visual rendering AND its hit-test frame at the correct screen location.
    /// SwiftUI's `.offset()` only moves pixels — the layout/hit-test frame
    /// stays at the origin — which is why taps and drags previously landed in
    /// the wrong place.
    private func redactionRegionOverlay(size: CGSize) -> some View {
        ZStack {
            ForEach(redactionRegions) { region in
                let cx = (region.rect.minX + region.rect.width  / 2) * size.width
                let cy = (region.rect.minY + region.rect.height / 2) * size.height

                redactionShape(
                    rect: region.rect,
                    size: size,
                    isSelected: selectedRedactionRegionID?.wrappedValue == region.id,
                    isEnabled: region.isEnabled,
                    overlayColor: region.color.color
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isRedactionEditing else { return }
                    selectRedaction(region.id)
                }
                .gesture(moveGesture(for: region, image: size))
                // .position() correctly places BOTH the visual layer and the
                // hit-test frame at the region's centre in image coordinates.
                .position(x: cx, y: cy)

                if isRedactionEditing, selectedRedactionRegionID?.wrappedValue == region.id {
                    resizeHandle(for: region, size: size)
                }
            }
        }
        // Explicit frame ensures .position() coordinates map 1-to-1 with image pixels.
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: selectedRedactionRegionID?.wrappedValue)
    }

    /// Renders the redaction box border + fill using the region's chosen overlay colour.
    ///
    /// `overlayColor` is the SwiftUI colour to use for the border and semi-transparent
    /// fill. Pass `region.color.color` for existing regions, `.accentColor` for the
    /// draft box while the user is still drawing.
    ///
    /// No `.offset()` — callers are responsible for positioning via `.position()`.
    private func redactionShape(
        rect: CGRect,
        size: CGSize,
        isSelected: Bool,
        isEnabled: Bool,
        overlayColor: Color
    ) -> some View {
        RoundedRectangle(cornerRadius: isSelected ? 4 : 2)
            .strokeBorder(
                overlayColor.opacity(isEnabled ? 0.95 : 0.4),
                style: StrokeStyle(
                    lineWidth: isSelected ? 3 : 1.5,
                    dash: isEnabled ? [] : [5, 4]
                )
            )
            .background(
                RoundedRectangle(cornerRadius: isSelected ? 4 : 2)
                    .fill(overlayColor.opacity(isEnabled ? (isSelected ? 0.24 : 0.12) : 0.05))
            )
            .frame(width: rect.width * size.width, height: rect.height * size.height)
            .accessibilityHidden(!isRedactionEditing)
    }

    /// Resize handle pinned to the bottom-right corner of the selected region.
    ///
    /// Uses `.position()` so its hit-test area lands on the correct pixel.
    private func resizeHandle(for region: RedactionRegion, size: CGSize) -> some View {
        Circle()
            .fill(Color.red)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            .position(
                x: region.rect.maxX * size.width,
                y: region.rect.maxY * size.height
            )
            .gesture(resizeGesture(for: region, image: size))
            .accessibilityLabel("Resize redaction")
    }

    private func moveGesture(for region: RedactionRegion, image: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isRedactionEditing, !isAddingRedaction else { return }
                if dragStartRect == nil {
                    dragStartRect = region.rect
                    selectRedaction(region.id)
                    // Notify the view model once per gesture so it can push exactly
                    // one undo snapshot regardless of how many drag events follow.
                    onBeginUpdateRedaction?(region.id)
                }
                guard let dragStartRect else { return }
                let delta = normalizedDelta(value.translation, image: image)
                onUpdateRedaction?(region.id, RedactionRegion.moved(dragStartRect, by: delta))
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func resizeGesture(for region: RedactionRegion, image: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isRedactionEditing else { return }
                if dragStartRect == nil {
                    dragStartRect = region.rect
                    selectRedaction(region.id)
                    onBeginUpdateRedaction?(region.id)
                }
                guard let dragStartRect else { return }
                let delta = normalizedDelta(value.translation, image: image)
                onUpdateRedaction?(region.id, RedactionRegion.resized(dragStartRect, by: delta))
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func selectRedaction(_ id: String?) {
        selectedRedactionRegionID?.wrappedValue = id
        onSelectRedaction?(id)
    }

    // MARK: - Coordinate helpers

    /// Converts two raw container-space touch points into a normalised image rect.
    ///
    /// Delegates to `imageNormalizedPoint` so the centering offset, zoom scale,
    /// and pan translation are all accounted for.
    private func normalizedRect(
        from start: CGPoint,
        to end: CGPoint,
        image: CGSize,
        container: CGSize
    ) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let s = imageNormalizedPoint(start, imageSize: image, containerSize: container,
                                     scale: scale, panOffset: offset)
        let e = imageNormalizedPoint(end, imageSize: image, containerSize: container,
                                     scale: scale, panOffset: offset)
        let minX   = min(s.x, e.x)
        let minY   = min(s.y, e.y)
        let width  = abs(e.x - s.x)
        let height = abs(e.y - s.y)
        return RedactionRegion.clamped(CGRect(x: minX, y: minY, width: width, height: height))
    }

    /// Converts a drag translation (in the image layer's coordinate space,
    /// already scaled by SwiftUI's gesture system) to normalised image-space delta.
    private func normalizedDelta(_ translation: CGSize, image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        return CGSize(width: translation.width / image.width, height: translation.height / image.height)
    }

    // MARK: - Zoom helpers

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
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let imageAspect     = imageSize.width / imageSize.height
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
        let maxX = max(0, (image.width  * scale - container.width)  / 2)
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

// MARK: - PhotoScanSweep

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
