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
    /// Export pixels per pixel of `image` (≥ 1).  Pixel-based effects in the live
    /// redaction preview are scaled by it so a box looks as it will when saved.
    var exportScale: CGFloat = 1
    var selectedRedactionRegionID: Binding<String?>?
    var isRedactionEditing: Bool = false
    var isAddingRedaction: Bool = false
    var resetZoomRequest: Int = 0
    var isScanning: Bool = false
    var showZoomHint: Bool = true
    var accessibilityIdentifier: String = "metadataPhotoPreview"
    var onTap: (() -> Void)?
    var onAddRedaction: ((CGRect) -> Void)?
    /// A single tap while adding a region: outline the object under it.
    /// `nil` where tap-an-object is not available.
    var onSelectObject: ((CGPoint) -> Void)?
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
    /// The live normalised rect for the region currently being moved or resized.
    ///
    /// Kept as local `@State` so position updates during a drag only re-render
    /// `ZoomableImagePreview` itself — not the entire `ContentView` hierarchy.
    /// `onUpdateRedaction` is called **once** in `onEnded` with the final rect,
    /// instead of on every `onChanged` event (60–120×/sec on ProMotion), which
    /// was triggering expensive `@Observable` mutations and dropped frames.
    @State private var dragLiveRect: CGRect?
    /// True while the user is actively dragging or resizing a redaction region.
    /// Used to suppress the simultaneous pan gesture so the background does not
    /// scroll while a redaction handle is being moved.
    @State private var isDraggingRedaction: Bool = false
    /// Whole-image pixelate / blur renders that the live preview masks to each region.
    @State private var obscuredLayers: [ObscuredLayerKey: UIImage] = [:]

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
                    imageLayer(size: fittedSize, container: geo.size)
                        .scaleEffect(scale)
                        .offset(offset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                // Named coordinate space consumed by moveGesture / resizeGesture.
                // Gestures on views *inside* imageLayer (which has .scaleEffect applied
                // from outside) would otherwise report locations in the pre-scale view
                // coordinate space rather than container-space, making normalised deltas
                // wrong at any zoom level other than 1×.  By declaring a named space
                // here and requesting it in those gestures, both add-new and move/resize
                // paths go through the same imageNormalizedPoint conversion pipeline.
                .coordinateSpace(name: "zoomablePreviewContainer")
                .gesture(zoomGesture(container: geo.size, image: fittedSize))
                .simultaneousGesture(panGesture(container: geo.size, image: fittedSize))
                .simultaneousGesture(addRedactionGesture(image: fittedSize, container: geo.size))
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    resetZoom()
                })
                // Use a regular (non-simultaneous) gesture for the single-tap deselect/tap-through.
                // Unlike simultaneousGesture, a regular .gesture() FAILS when a child view's own
                // gesture fires — so tapping a region selects it instead of immediately deselecting.
                .gesture(SpatialTapGesture(coordinateSpace: .named("zoomablePreviewContainer")).onEnded { tap in
                    if isRedactionEditing, isAddingRedaction, let onSelectObject {
                        let point = imageNormalizedPoint(
                            tap.location, imageSize: fittedSize, containerSize: geo.size,
                            scale: scale, panOffset: offset
                        )
                        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
                        onSelectObject(point)
                    } else if isRedactionEditing {
                        selectRedaction(nil)
                    } else {
                        onTap?()
                    }
                })

                if showZoomHint {
                    Label(zoomHintText, systemImage: isAddingRedaction ? "plus.square.dashed" : "hand.draw")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .glassEffect(in: .capsule)
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
        .onChange(of: image) { _, _ in
            resetZoom()
            obscuredLayers = [:]
        }
        .task(id: ObscuredLayerRequest(image: ObjectIdentifier(image), keys: obscuredGroups.map(\.key))) {
            await renderMissingObscuredLayers()
        }
        .onChange(of: focusedResult?.id) { _, _ in pulseFocusedResult() }
        .onChange(of: isAddingRedaction) { _, _ in draftRedactionRect = nil }
        .onChange(of: resetZoomRequest) { _, _ in resetZoom() }
    }

    // MARK: - Image layer

    private func imageLayer(size: CGSize, container: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Static content: source image bitmap, detection-highlight overlays,
            // and the scan sweep animation.  None of these change while the user
            // is dragging or resizing a redaction box.  Wrapping in an Equatable
            // view lets SwiftUI skip StaticImageLayer.body entirely on every
            // dragLiveRect update (60–120×/sec on ProMotion), keeping only the
            // redaction overlay in the hot-render path.
            StaticImageLayer(
                image: image,
                size: size,
                highlightedResults: highlightedResults,
                focusedResult: focusedResult,
                focusPulse: focusPulse,
                isScanning: isScanning,
                reduceMotion: reduceMotion
            )
            .equatable()

            if !redactionRegions.isEmpty {
                redactionStylePreview(size: size)
                redactionRegionOverlay(size: size, container: container)
            }

            // Draft box while the user is still drawing a new redaction.
            // Uses .position() so the hit-test frame is also at the right location.
            if let draftRedactionRect {
                redactionShape(
                    rect: draftRedactionRect,
                    size: size,
                    isSelected: true,
                    isEnabled: true,
                    overlayColor: .accentColor,
                    isDraft: true
                )
                .allowsHitTesting(false)
                .position(
                    x: (draftRedactionRect.minX + draftRedactionRect.width  / 2) * size.width,
                    y: (draftRedactionRect.minY + draftRedactionRect.height / 2) * size.height
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Zoom hint

    private var zoomHintText: LocalizedStringKey {
        if isAddingRedaction {
            return onSelectObject == nil ? "Drag to redact" : "Drag to redact, or tap an object"
        }
        if isRedactionEditing {
            return "Drag boxes to adjust"
        }
        return scale > 1.01 ? "Double tap to reset" : "Pinch to zoom"
    }

    // MARK: - Gestures

    private func zoomGesture(container: CGSize, image: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = clamp(lastScale * value.magnification, min: 1, max: 5)
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
                guard scale > 1.01, !isAddingRedaction, !isDraggingRedaction else { return }
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
    private func redactionRegionOverlay(size: CGSize, container: CGSize) -> some View {
        ZStack {
            ForEach(redactionRegions) { region in
                let effectiveRect = liveRect(of: region)

                let cx = (effectiveRect.minX + effectiveRect.width  / 2) * size.width
                let cy = (effectiveRect.minY + effectiveRect.height / 2) * size.height

                redactionShape(
                    rect: effectiveRect,
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
                .gesture(moveGesture(for: region, image: size, container: container))
                // .position() correctly places BOTH the visual layer and the
                // hit-test frame at the region's centre in image coordinates.
                .position(x: cx, y: cy)

                if isRedactionEditing, selectedRedactionRegionID?.wrappedValue == region.id {
                    resizeHandle(rect: effectiveRect, size: size)
                        .gesture(resizeGesture(for: region, image: size, container: container))
                }
            }
        }
        // Explicit frame ensures .position() coordinates map 1-to-1 with image pixels.
        .frame(width: size.width, height: size.height)
        // Suppress the spring when a drag is active: selectedRedactionRegionID
        // won't change during drag anyway, but suppressing is defensive and avoids
        // any SwiftUI batching edge case re-animating the position at gesture end.
        .animation(
            isDraggingRedaction
                ? nil
                : .spring(response: 0.25, dampingFraction: 0.78),
            value: selectedRedactionRegionID?.wrappedValue
        )
    }

    // MARK: - Live style preview

    /// A region's rect as it should be drawn right now.  During a drag or resize
    /// that is the local live rect, so only this view re-renders — not ContentView.
    private func liveRect(of region: RedactionRegion) -> CGRect {
        let isActiveDrag = isDraggingRedaction && selectedRedactionRegionID?.wrappedValue == region.id
        return isActiveDrag ? (dragLiveRect ?? region.rect) : region.rect
    }

    /// Enabled pixelate / blur regions, grouped the way the export groups them:
    /// one pass, and so one block size, per style and strength.
    ///
    /// Block sizes come from the committed rects, not the live drag rect, so the
    /// layer under a moving box stays put; it is re-rendered when the drag ends.
    private var obscuredGroups: [ObscuredGroup] {
        let previewPixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let exportPixels = CGSize(width: previewPixels.width * exportScale, height: previewPixels.height * exportScale)
        let regions = redactionRegions.filter { $0.isEnabled && $0.style.obscuresSourcePixels }
        let grouped = Dictionary(grouping: regions) {
            ObscuredPass(style: $0.style, strength: RedactionStrength.clamped($0.strength))
        }
        return grouped
            .map { pass, members in
                let exportBlock = RedactionStrength.blockSize(
                    forNormalizedRects: members.map(\.rect), pixelSize: exportPixels, strength: pass.strength
                )
                let key = ObscuredLayerKey(style: pass.style, blockSize: max(1, Int((exportBlock / exportScale).rounded())))
                return ObscuredGroup(pass: pass, key: key, regions: members)
            }
            // Pixelate before blur, light before strong — the export's order.
            .sorted { ($0.pass.style == .pixelate ? 0 : 1, $0.pass.strength) < ($1.pass.style == .pixelate ? 0 : 1, $1.pass.strength) }
    }

    private func renderMissingObscuredLayers() async {
        let needed = Set(obscuredGroups.map(\.key))
        for key in needed where obscuredLayers[key] == nil {
            let layer = await ImageRedactor().previewLayer(key.style, blockSize: CGFloat(key.blockSize), of: image)
            guard !Task.isCancelled else { return }
            obscuredLayers[key] = layer
        }
        obscuredLayers = obscuredLayers.filter { needed.contains($0.key) }
    }

    /// Draws every enabled region in the style it will be saved with.
    ///
    /// Pixelate and blur mask a whole-image render to the region, so the effect
    /// follows a box in real time.  Solid and crosshatch go see-through while
    /// they are being moved, so you can see what you are about to cover.
    private func redactionStylePreview(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(obscuredGroups, id: \.pass) { group in
                let mask = Path { path in
                    for region in group.regions { path.addRect(displayRect(liveRect(of: region), in: size)) }
                }
                // While a new block size renders (a resize just ended), keep showing
                // the last render of this style instead of flashing a placeholder.
                let stale = obscuredLayers.first { $0.key.style == group.key.style }?.value
                if let layer = obscuredLayers[group.key] ?? stale {
                    Image(uiImage: layer)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .mask(alignment: .topLeading) { mask.frame(width: size.width, height: size.height) }
                } else {
                    // Until the render lands, never show the region untouched.
                    mask.fill(Color(.systemGray3))
                }
            }

            Canvas { context, _ in
                let previewPixelWidth = image.size.width * image.scale
                let exportPixels = CGSize(
                    width: previewPixelWidth * exportScale,
                    height: image.size.height * image.scale * exportScale
                )
                let pointsPerExportPixel = exportPixels.width > 0 ? size.width / exportPixels.width : 1

                for region in redactionRegions where region.isEnabled && !region.style.obscuresSourcePixels {
                    let live = liveRect(of: region)
                    let rect = displayRect(live, in: size)
                    var layer = context
                    let isMoving = isDraggingRedaction && selectedRedactionRegionID?.wrappedValue == region.id
                    layer.opacity = isMoving ? 0.55 : 1
                    layer.fill(Path(rect), with: .color(region.color.color))

                    guard region.style == .crosshatch else { continue }
                    let exportRect = CGRect(
                        x: live.minX * exportPixels.width, y: live.minY * exportPixels.height,
                        width: live.width * exportPixels.width, height: live.height * exportPixels.height
                    )
                    let lattice = RedactionLattice.metrics(rect: exportRect, imageSize: exportPixels)
                    layer.clip(to: Path(rect))
                    layer.stroke(
                        Path(RedactionLattice.path(in: rect, spacing: lattice.spacing * pointsPerExportPixel)),
                        with: .color(Color(uiColor: region.color.latticeColor)),
                        lineWidth: lattice.lineWidth * pointsPerExportPixel
                    )
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func displayRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width, y: normalized.minY * size.height,
            width: normalized.width * size.width, height: normalized.height * size.height
        )
    }

    /// The redaction box's border — what you grab, and what marks the selection.
    ///
    /// An enabled region has no fill of its own: `redactionStylePreview` draws
    /// its real style underneath.  The draft box (still being drawn) has no style
    /// yet, so it keeps a tint; pass `.accentColor` and `isDraft` for it.  The
    /// selected region is outlined — outside its edge — in the accent colour with
    /// a white hairline, because the region's own colour vanishes against its fill.
    ///
    /// No `.offset()` — callers are responsible for positioning via `.position()`.
    private func redactionShape(
        rect: CGRect,
        size: CGSize,
        isSelected: Bool,
        isEnabled: Bool,
        overlayColor: Color,
        isDraft: Bool = false
    ) -> some View {
        let marksSelection = isSelected && !isDraft
        let fillOpacity = isDraft ? 0.24 : (isEnabled ? 0 : 0.05)
        return RoundedRectangle(cornerRadius: isSelected ? 4 : 2)
            .strokeBorder(
                overlayColor.opacity(marksSelection ? 0 : (isEnabled ? 0.95 : 0.4)),
                style: StrokeStyle(
                    lineWidth: isSelected ? 3 : 1.5,
                    dash: isEnabled ? [] : [5, 4]
                )
            )
            .background(
                RoundedRectangle(cornerRadius: isSelected ? 4 : 2)
                    .fill(overlayColor.opacity(fillOpacity))
            )
            .overlay {
                // Drawn outside the box, so it never covers the style preview
                // of a region that is only a line of text tall.
                if marksSelection {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                        .padding(-4)
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            Color.accentColor.opacity(isEnabled ? 1 : 0.5),
                            style: StrokeStyle(lineWidth: 3, dash: isEnabled ? [] : [5, 4])
                        )
                        .padding(-3)
                }
            }
            .frame(width: rect.width * size.width, height: rect.height * size.height)
            .accessibilityHidden(!isRedactionEditing)
    }

    /// Resize handle pinned to the bottom-right corner of the selected region.
    ///
    /// Accepts the pre-computed `effectiveRect` (live during drag, model rect otherwise)
    /// so the handle tracks the finger without going through the view model.
    /// The caller is responsible for attaching `resizeGesture` to the returned view.
    private func resizeHandle(rect: CGRect, size: CGSize) -> some View {
        Circle()
            .fill(Color.red)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            // The dot stays 18 pt; the thing you grab is a full 44 pt target.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .position(
                x: rect.maxX * size.width,
                y: rect.maxY * size.height
            )
            .accessibilityLabel("Resize redaction")
    }

    private func moveGesture(for region: RedactionRegion, image: CGSize, container: CGSize) -> some Gesture {
        // Use the named coordinate space declared on the outer ZStack so that
        // value.startLocation / value.location arrive in container space rather
        // than the pre-scaleEffect view space.  imageNormalizedPoint then converts
        // both points through the same centering + scale + pan pipeline, so the
        // computed delta is correct at any zoom level.
        DragGesture(minimumDistance: 2, coordinateSpace: .named("zoomablePreviewContainer"))
            .onChanged { value in
                guard isRedactionEditing, !isAddingRedaction else { return }
                if dragStartRect == nil {
                    dragStartRect = region.rect
                    isDraggingRedaction = true
                    // Notify the view model once per gesture so it can push exactly
                    // one undo snapshot regardless of how many drag events follow.
                    onBeginUpdateRedaction?(region.id)
                    // Select the region in its own render pass so the selection-state
                    // spring (see .animation modifier on the overlay) only animates the
                    // visual style change (border/fill), not a position delta.
                    var t = Transaction()
                    t.disablesAnimations = false
                    withTransaction(t) { selectRedaction(region.id) }
                    // Return early — first event translation ≤ minimumDistance (2 pt);
                    // skipping it is imperceptible and avoids batching a rect mutation
                    // with the selectedRedactionRegionID change on the same frame.
                    return
                }
                guard let dragStartRect else { return }
                let delta = normalizedDelta(
                    from: value.startLocation,
                    to: value.location,
                    image: image,
                    container: container
                )
                // Write only local @State — does NOT mutate the view model, so
                // ContentView does not re-render on every gesture event.
                dragLiveRect = RedactionRegion.moved(dragStartRect, by: delta)
            }
            .onEnded { _ in
                // Commit the final position to the model exactly once per gesture.
                if let live = dragLiveRect {
                    onUpdateRedaction?(region.id, live)
                }
                dragStartRect = nil
                dragLiveRect = nil
                isDraggingRedaction = false
            }
    }

    private func resizeGesture(for region: RedactionRegion, image: CGSize, container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("zoomablePreviewContainer"))
            .onChanged { value in
                guard isRedactionEditing else { return }
                if dragStartRect == nil {
                    dragStartRect = region.rect
                    isDraggingRedaction = true
                    onBeginUpdateRedaction?(region.id)
                    // Same split as moveGesture: select first, skip the first delta.
                    var t = Transaction()
                    t.disablesAnimations = false
                    withTransaction(t) { selectRedaction(region.id) }
                    return
                }
                guard let dragStartRect else { return }
                let delta = normalizedDelta(
                    from: value.startLocation,
                    to: value.location,
                    image: image,
                    container: container
                )
                dragLiveRect = RedactionRegion.resized(dragStartRect, by: delta)
            }
            .onEnded { _ in
                if let live = dragLiveRect {
                    onUpdateRedaction?(region.id, live)
                }
                dragStartRect = nil
                dragLiveRect = nil
                isDraggingRedaction = false
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

    /// Converts two absolute container-space touch points into a normalised
    /// image-space delta, correctly accounting for zoom scale and pan offset.
    ///
    /// Using `startLocation` / `location` (absolute container-space positions)
    /// rather than `value.translation` is essential: `translation` is reported in
    /// the coordinate space of the *gesture's view*, but that view has
    /// `.scaleEffect(scale)` applied from outside.  At zoom>1 the gesture view is
    /// scaled *visually* but SwiftUI's gesture system still delivers translation in
    /// the *pre-scale* (display) coordinate space, so dividing by `imageSize` alone
    /// undercounts the delta by a factor of `scale`.
    ///
    /// By going through `imageNormalizedPoint` for both endpoints the pan offset
    /// cancels out (it's added to both numerator and denominator) and the scale
    /// factor is divided out correctly:
    ///
    ///     imageNormalizedPoint(end) – imageNormalizedPoint(start)
    ///       = (end – start) / (scale × imageSize)
    ///       = translation / (scale × imageSize)   ✓
    private func normalizedDelta(from start: CGPoint, to end: CGPoint,
                                 image: CGSize, container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let s = imageNormalizedPoint(start, imageSize: image, containerSize: container,
                                     scale: scale, panOffset: offset)
        let e = imageNormalizedPoint(end, imageSize: image, containerSize: container,
                                     scale: scale, panOffset: offset)
        return CGSize(width: e.x - s.x, height: e.y - s.y)
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

// MARK: - StaticImageLayer

/// The parts of `ZoomableImagePreview` that are **never mutated during a drag**:
/// the source image bitmap, detection-highlight overlays, and the scan sweep.
///
/// Conforming to `Equatable` and calling `.equatable()` at the call site instructs
/// SwiftUI to call `==` before evaluating `body`.  During a redaction drag only
/// `dragLiveRect` (local `@State`) changes; all inputs passed to `StaticImageLayer`
/// remain identical, so `body` is skipped entirely — reducing per-frame work from
/// O(image + overlays) down to O(redaction box only) and eliminating the CPU spike
/// that was causing dropped frames and visible jitter.
private struct StaticImageLayer: View, Equatable {
    let image: UIImage
    let size: CGSize
    let highlightedResults: [DetectionResult]
    let focusedResult: DetectionResult?
    /// Forwarded from `ZoomableImagePreview.focusPulse` so the pulse animation
    /// still fires correctly; changes here are rare and intentional.
    let focusPulse: Bool
    let isScanning: Bool
    let reduceMotion: Bool

    // MARK: Equatable

    static func == (lhs: Self, rhs: Self) -> Bool {
        // UIImage is a reference type — pointer equality is the right check here.
        // Two distinct UIImage objects representing the same photo are still different
        // renders from the user's perspective (e.g. after undo), so we must re-draw.
        lhs.image === rhs.image
            && lhs.size == rhs.size
            && lhs.highlightedResults == rhs.highlightedResults
            && lhs.focusedResult == rhs.focusedResult
            && lhs.focusPulse == rhs.focusPulse
            && lhs.isScanning == rhs.isScanning
            && lhs.reduceMotion == rhs.reduceMotion
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)

            if !highlightedResults.isEmpty {
                detectionOverlay(results: highlightedResults, style: .subtle)
            }

            if let focusedResult {
                detectionOverlay(results: [focusedResult], style: .focused)
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

    // MARK: Detection overlay

    private enum OverlayStyle: Equatable {
        case subtle
        case focused
    }

    /// Detection-highlight overlay.  Display-only: uses `.offset()` because these
    /// boxes never have gesture targets that need correct hit-testing.
    private func detectionOverlay(
        results: [DetectionResult],
        style: OverlayStyle
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
                                .fill((style == .focused ? Color.red : Color.orange)
                                    .opacity(style == .focused ? 0.22 : 0.10))
                        )
                        .shadow(
                            color: style == .focused
                                ? Color.red.opacity(focusPulse ? 0.45 : 0.22)
                                : Color.clear,
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

// MARK: - Live preview support

/// One export pass: every enabled region with this style and strength.
private struct ObscuredPass: Hashable {
    let style: RedactionStyle
    let strength: Double
}

/// A whole-image render the preview can reuse: the style and its block size in
/// preview pixels.  Two passes that resolve to the same block size share one.
private struct ObscuredLayerKey: Hashable {
    let style: RedactionStyle
    let blockSize: Int
}

private struct ObscuredGroup {
    let pass: ObscuredPass
    let key: ObscuredLayerKey
    let regions: [RedactionRegion]
}

private struct ObscuredLayerRequest: Hashable {
    let image: ObjectIdentifier
    let keys: [ObscuredLayerKey]
}
