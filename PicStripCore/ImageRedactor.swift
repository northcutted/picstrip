import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - RedactionStyle
//
// Defined here (in ImageRedactor.swift) so this file compiles in both the
// main app target and the Share Extension target.  RedactionRegion.swift
// (main-app only) uses these types via normal module-level access.

/// Visual style applied when burning a redaction block onto an image.
nonisolated enum RedactionStyle: String, CaseIterable, Equatable, Hashable, Codable {
    /// Flat opaque fill — the classic government-document redaction bar.
    case solid
    /// Dense diagonal crosshatch lines over a semi-transparent base fill.
    case crosshatch
    /// Pixellates (mosaics) the underlying image region. The `color` property is ignored.
    case pixelate
    /// Smoothly blurs the underlying image region. The `color` property is ignored.
    case blur

    var displayName: String {
        switch self {
        case .solid:      return String(localized: "Solid")
        case .crosshatch: return String(localized: "Crosshatch")
        case .pixelate:   return String(localized: "Pixelate")
        case .blur:       return String(localized: "Blur")
        }
    }

    var symbolName: String {
        switch self {
        case .solid:      return "rectangle.fill"
        case .crosshatch: return "grid"
        case .pixelate:   return "square.grid.3x3.middle.filled"
        case .blur:       return "drop.fill"
        }
    }

    /// Whether the `color` property has any visual effect on the rendered output.
    var supportsColor: Bool { !obscuresSourcePixels }

    /// `true` for styles that scramble the pixels underneath (Core Image pass)
    /// instead of painting over them.
    var obscuresSourcePixels: Bool { self == .pixelate || self == .blur }
}

// MARK: - RedactionColor

/// Fill colour applied to a redaction block during both editing-overlay and export rendering.
nonisolated enum RedactionColor: String, CaseIterable, Equatable, Hashable, Codable {
    // Neutrals
    case black
    case charcoal
    case white
    // Warm
    case red
    case orange
    case yellow
    // Cool
    case green
    case teal
    case blue
    case navy
    // Fun
    case purple
    case pink

    var displayName: String {
        switch self {
        case .black:    return String(localized: "Black")
        case .charcoal: return String(localized: "Charcoal")
        case .white:    return String(localized: "White")
        case .red:      return String(localized: "Red")
        case .orange:   return String(localized: "Orange")
        case .yellow:   return String(localized: "Yellow")
        case .green:    return String(localized: "Green")
        case .teal:     return String(localized: "Teal")
        case .blue:     return String(localized: "Blue")
        case .navy:     return String(localized: "Navy")
        case .purple:   return String(localized: "Purple")
        case .pink:     return String(localized: "Pink")
        }
    }

    /// UIKit colour used in CGContext drawing.
    var uiColor: UIColor {
        switch self {
        case .black:    return .black
        case .charcoal: return UIColor(white: 0.20, alpha: 1)
        case .white:    return .white
        case .red:      return UIColor(red: 0.88, green: 0.10, blue: 0.10, alpha: 1)
        case .orange:   return UIColor(red: 0.95, green: 0.45, blue: 0.05, alpha: 1)
        case .yellow:   return UIColor(red: 0.95, green: 0.82, blue: 0.04, alpha: 1)
        case .green:    return UIColor(red: 0.08, green: 0.60, blue: 0.15, alpha: 1)
        case .teal:     return UIColor(red: 0.04, green: 0.62, blue: 0.62, alpha: 1)
        case .blue:     return UIColor(red: 0.10, green: 0.38, blue: 0.90, alpha: 1)
        case .navy:     return UIColor(red: 0.08, green: 0.13, blue: 0.33, alpha: 1)
        case .purple:   return UIColor(red: 0.52, green: 0.08, blue: 0.80, alpha: 1)
        case .pink:     return UIColor(red: 0.95, green: 0.18, blue: 0.55, alpha: 1)
        }
    }
}

// MARK: - RedactionSpec

/// A lightweight rendering descriptor that is available in both the main app
/// target and the Share Extension.
///
/// `ScrubberViewModel` (main app) maps `[RedactionRegion]` → `[RedactionSpec]`
/// before calling `ImageRedactor.redact(image:specs:)`.  Batch processing and
/// the Share Extension use `redact(image:instances:)`, which synthesises
/// solid-black specs.
nonisolated struct RedactionSpec {
    let rect: CGRect
    let style: RedactionStyle
    let color: RedactionColor
    /// When `false` this spec is skipped by the renderer.
    let isEnabled: Bool
}

// MARK: - ImageRedactor

/// Stateless service that burns styled redaction blocks over image regions.
///
/// **Coordinate convention:** All normalised rects use a top-left origin (0 … 1).
/// Y was already flipped in `PIIScanner`, so multiplying by `image.size` maps
/// directly into the `UIGraphicsImageRenderer` coordinate space.
///
/// **Rendering pipeline:**
/// 1. For any `.pixelate` / `.blur` specs, a CIFilter pre-pass obscures those
///    areas of the source image first (reads pixels, colour-agnostic).
/// 2. A single `UIGraphicsImageRenderer` pass draws the (possibly pre-obscured)
///    base image, then stamps each remaining style on top.
///
/// **Fail closed:** if a Core Image pass cannot run, its regions are painted
/// solid instead — a region the user asked to hide is never left readable.
nonisolated struct ImageRedactor {

    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    /// Burns styled redaction blocks over the supplied specs and returns a new,
    /// flattened `UIImage`.  Specs whose `isEnabled` flag is false are skipped.
    ///
    /// `@concurrent`: always renders off the caller's actor, so a full-resolution
    /// redraw never blocks the UI.
    @concurrent
    func redact(image: UIImage, specs: [RedactionSpec]) async -> UIImage? {
        let enabled = specs.filter(\.isEnabled)
        guard !enabled.isEmpty else { return image }

        // ── Step 1: Core Image pre-pass (pixelate, then blur) ──────────────
        var workingImage = image
        var paintedSolidInstead: [RedactionSpec] = []
        for style in [RedactionStyle.pixelate, .blur] {
            let styled = enabled.filter { $0.style == style }
            guard !styled.isEmpty else { continue }
            if let obscured = Self.applyObscuring(style, to: workingImage, specs: styled) {
                workingImage = obscured
            } else {
                paintedSolidInstead += styled
            }
        }

        // ── Step 2: Raster pass for remaining styles ───────────────────────
        let size     = image.size
        let format   = image.imageRendererFormat
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            workingImage.draw(at: .zero)

            let painted = enabled.filter { !$0.style.obscuresSourcePixels } + paintedSolidInstead
            for spec in painted {
                let rect = CGRect(
                    x: spec.rect.minX * size.width,
                    y: spec.rect.minY * size.height,
                    width: spec.rect.width * size.width,
                    height: spec.rect.height * size.height
                )
                guard rect.width > 0, rect.height > 0 else { continue }

                switch spec.style {
                case .solid:
                    Self.renderSolid(color: spec.color.uiColor, rect: rect)
                case .crosshatch:
                    Self.renderCrosshatch(color: spec.color.uiColor, rect: rect, in: ctx)
                case .pixelate, .blur:
                    // Only reached when the Core Image pass failed.
                    Self.renderSolid(color: RedactionColor.black.uiColor, rect: rect)
                }
            }
        }
    }

    // MARK: - Unattended redaction

    /// Burns opaque solid-black rectangles over every supplied `DetectedInstance`.
    /// Used where nobody picks a style: batch processing and the Share Extension.
    func redact(image: UIImage, instances: [DetectedInstance]) async -> UIImage? {
        let specs = instances.map {
            RedactionSpec(rect: $0.boundingBox, style: .solid, color: .black, isEnabled: true)
        }
        return await redact(image: image, specs: specs)
    }

    // MARK: - Solid

    private static func renderSolid(color: UIColor, rect: CGRect) {
        color.setFill()
        UIRectFill(rect)
    }

    // MARK: - Crosshatch

    /// Dense diagonal crosshatch — a 35 % base fill plus forward- and backward-
    /// diagonal lines spaced 7 pt apart, clipped to the region rect.
    private static func renderCrosshatch(
        color: UIColor,
        rect: CGRect,
        in ctx: UIGraphicsImageRendererContext
    ) {
        let cgCtx = ctx.cgContext
        cgCtx.saveGState()

        // Semi-transparent base
        color.withAlphaComponent(0.35).setFill()
        UIRectFill(rect)

        // Clip diagonal lines to the region rect
        cgCtx.clip(to: rect)
        color.withAlphaComponent(0.80).setStroke()
        cgCtx.setLineWidth(1.0)

        let spacing: CGFloat = 7.0

        // Forward diagonals (↘)
        var startX = rect.minX - rect.height
        while startX < rect.maxX {
            cgCtx.move(to: CGPoint(x: startX, y: rect.minY))
            cgCtx.addLine(to: CGPoint(x: startX + rect.height, y: rect.maxY))
            startX += spacing
        }
        // Backward diagonals (↙)
        startX = rect.minX - rect.height
        while startX < rect.maxX {
            cgCtx.move(to: CGPoint(x: startX + rect.height, y: rect.minY))
            cgCtx.addLine(to: CGPoint(x: startX, y: rect.maxY))
            startX += spacing
        }
        cgCtx.strokePath()
        cgCtx.restoreGState()
    }

    // MARK: - Pixellate / blur (CIFilter pre-pass)

    /// Uses a single filter evaluation plus one mask-driven blend to obscure
    /// every supplied region in one pass.  Colour is ignored — the effect shows
    /// scrambled source pixels, not a solid fill.
    ///
    /// **Blur is a mosaic first.**  A plain Gaussian blur of text can be
    /// sharpened back into something legible, so `.blur` pixellates exactly as
    /// `.pixelate` does and then blurs the mosaic: it looks smooth, but carries
    /// no more information than the blocks underneath.
    ///
    /// The previous implementation ran one CIPixellate + CIBlendWithMask per spec,
    /// each iteration feeding the accumulated result forward.  That scaled poorly
    /// when an OCR-heavy image produced many pixelate regions: every region
    /// triggered a fresh full-image Core Image evaluation.  The combined-mask
    /// approach evaluates the pixellated layer exactly once and composites it
    /// against a single union-of-rects mask.
    nonisolated private static func applyObscuring(
        _ style: RedactionStyle,
        to image: UIImage,
        specs: [RedactionSpec]
    ) -> UIImage? {
        guard !specs.isEmpty, let ciImage = CIImage(image: image) else { return nil }
        let extent = ciImage.extent   // CI pixel space (Y-up, device pixels)

        // ── 1. Resolve rects in CI pixel space ───────────────────────────────
        let ciRects: [CGRect] = specs.compactMap { spec in
            let rect = CGRect(
                x: spec.rect.minX * extent.width,
                y: (1.0 - spec.rect.maxY) * extent.height,
                width: spec.rect.width * extent.width,
                height: spec.rect.height * extent.height
            )
            return (rect.width > 0 && rect.height > 0) ? rect : nil
        }
        guard !ciRects.isEmpty else { return image }

        // ── 2. Pick a single block size from the smallest region ─────────────
        // Keeps the visual character of pixelation for the privacy-critical
        // small regions; large regions get slightly chunkier blocks, which is
        // still adequately obscuring.
        let smallestDim = ciRects
            .map { min($0.width, $0.height) }
            .min() ?? 100
        let blockSize = Float(min(40, max(10, smallestDim * 0.12)))

        // ── 3. Run CIPixellate ONCE over the whole image ─────────────────────
        guard let pixFilter = CIFilter(name: "CIPixellate") else { return nil }
        pixFilter.setValue(ciImage, forKey: kCIInputImageKey)
        pixFilter.setValue(
            CIVector(cgPoint: CGPoint(x: extent.midX, y: extent.midY)),
            forKey: kCIInputCenterKey
        )
        pixFilter.setValue(blockSize, forKey: "inputScale")
        guard var obscured = pixFilter.outputImage else { return nil }

        if style == .blur {
            // Clamp first so the blur does not pull transparent pixels in at the
            // image edges; crop back to the original extent afterwards.
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = obscured.clampedToExtent()
            blur.radius = blockSize * 1.5
            guard let blurred = blur.outputImage else { return nil }
            obscured = blurred.cropped(to: extent)
        }

        // ── 4. Build a single mask CIImage = union of white rects ────────────
        // CIImage(color: white) is infinite-extent; cropping to a rect produces
        // a white region exactly of that shape.  Stacking them with
        // CISourceOverCompositing yields the union.  Core Image consolidates
        // this into one render pass when fed into CIBlendWithMask.
        var mask = CIImage(color: CIColor.clear).cropped(to: extent)
        for rect in ciRects {
            let whiteRect = CIImage(color: CIColor.white).cropped(to: rect)
            guard let composite = CIFilter(name: "CISourceOverCompositing") else { continue }
            composite.setValue(whiteRect, forKey: kCIInputImageKey)
            composite.setValue(mask, forKey: kCIInputBackgroundImageKey)
            mask = composite.outputImage ?? mask
        }

        // ── 5. Single blend pass ─────────────────────────────────────────────
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(obscured, forKey: kCIInputImageKey)
        blendFilter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let result = blendFilter.outputImage else { return nil }

        guard let cgOut = ciContext.createCGImage(result, from: extent) else { return nil }
        return UIImage(cgImage: cgOut, scale: image.scale, orientation: image.imageOrientation)
    }
}
