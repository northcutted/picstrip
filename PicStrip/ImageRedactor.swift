import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - RedactionStyle
//
// Defined here (in ImageRedactor.swift) so this file compiles in both the
// main app target and the Share Extension target.  RedactionRegion.swift
// (main-app only) uses these types via normal module-level access.

/// Visual style applied when burning a redaction block onto an image.
enum RedactionStyle: String, CaseIterable, Equatable, Hashable, Codable {
    /// Flat opaque fill — the classic government-document redaction bar.
    case solid
    /// Dense diagonal crosshatch lines over a semi-transparent base fill.
    case crosshatch
    /// Pixellates (mosaics) the underlying image region. The `color` property is ignored.
    case pixelate

    var displayName: String {
        switch self {
        case .solid:      return "Solid"
        case .crosshatch: return "Crosshatch"
        case .pixelate:   return "Pixelate"
        }
    }

    var symbolName: String {
        switch self {
        case .solid:      return "rectangle.fill"
        case .crosshatch: return "grid"
        case .pixelate:   return "square.grid.3x3.middle.filled"
        }
    }

    /// Whether the `color` property has any visual effect on the rendered output.
    var supportsColor: Bool { self != .pixelate }
}

// MARK: - RedactionColor

/// Fill colour applied to a redaction block during both editing-overlay and export rendering.
enum RedactionColor: String, CaseIterable, Equatable, Hashable, Codable {
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
        case .black:    return "Black"
        case .charcoal: return "Charcoal"
        case .white:    return "White"
        case .red:      return "Red"
        case .orange:   return "Orange"
        case .yellow:   return "Yellow"
        case .green:    return "Green"
        case .teal:     return "Teal"
        case .blue:     return "Blue"
        case .navy:     return "Navy"
        case .purple:   return "Purple"
        case .pink:     return "Pink"
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
/// before calling `ImageRedactor.redact(image:specs:)`.  The Share Extension
/// uses the backward-compatible `redact(image:instances:)` wrapper which
/// synthesises solid-black specs internally.
struct RedactionSpec {
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
/// 1. For any `.pixelate` specs, a CIFilter pre-pass mosaics those areas of
///    the source image first (reads pixels, colour-agnostic).
/// 2. A single `UIGraphicsImageRenderer` pass draws the (possibly pre-pixellated)
///    base image, then stamps each remaining style on top.
struct ImageRedactor {

    // MARK: - Public API

    /// Burns styled redaction blocks over the supplied specs and returns a new,
    /// flattened `UIImage`.  Specs whose `isEnabled` flag is false are skipped.
    func redact(image: UIImage, specs: [RedactionSpec]) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let enabled = specs.filter(\.isEnabled)
            guard !enabled.isEmpty else { return image }

            // ── Step 1: Pixelate pre-pass ──────────────────────────────────
            let pixelateSpecs = enabled.filter { $0.style == .pixelate }
            var workingImage = image
            if !pixelateSpecs.isEmpty,
               let pixellated = Self.applyPixellate(to: image, specs: pixelateSpecs) {
                workingImage = pixellated
            }

            // ── Step 2: Raster pass for remaining styles ───────────────────
            let size     = image.size
            let format   = image.imageRendererFormat
            let renderer = UIGraphicsImageRenderer(size: size, format: format)

            return renderer.image { ctx in
                workingImage.draw(at: .zero)

                for spec in enabled where spec.style != .pixelate {
                    let rect = CGRect(
                        x: spec.rect.minX * size.width,
                        y: spec.rect.minY * size.height,
                        width:  spec.rect.width  * size.width,
                        height: spec.rect.height * size.height
                    )
                    guard rect.width > 0, rect.height > 0 else { continue }

                    switch spec.style {
                    case .solid:
                        Self.renderSolid(color: spec.color.uiColor, rect: rect)
                    case .crosshatch:
                        Self.renderCrosshatch(color: spec.color.uiColor, rect: rect, in: ctx)
                    case .pixelate:
                        break  // handled in step 1
                    }
                }
            }
        }.value
    }

    // MARK: - Backward-compatible overloads

    /// Burns opaque solid-black rectangles over every supplied `DetectedInstance`.
    /// Kept for the Share Extension batch-processing code path.
    func redact(image: UIImage, instances: [DetectedInstance]) async -> UIImage? {
        await redact(image: image, rects: instances.map(\.boundingBox))
    }

    /// Burns opaque solid-black rectangles over every supplied normalised rect.
    /// Kept so existing tests compile without changes.
    func redact(image: UIImage, rects: [CGRect]) async -> UIImage? {
        let specs = rects.map { RedactionSpec(rect: $0, style: .solid, color: .black, isEnabled: true) }
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
            cgCtx.move(to:    CGPoint(x: startX,              y: rect.minY))
            cgCtx.addLine(to: CGPoint(x: startX + rect.height, y: rect.maxY))
            startX += spacing
        }
        // Backward diagonals (↙)
        startX = rect.minX - rect.height
        while startX < rect.maxX {
            cgCtx.move(to:    CGPoint(x: startX + rect.height, y: rect.minY))
            cgCtx.addLine(to: CGPoint(x: startX,               y: rect.maxY))
            startX += spacing
        }
        cgCtx.strokePath()
        cgCtx.restoreGState()
    }

    // MARK: - Pixellate (CIFilter pre-pass)

    /// Uses `CIPixellate` to mosaic each region and composites the pixellated
    /// areas back onto the original image.  Colour is ignored — the effect shows
    /// scrambled source pixels, not a solid fill.
    private nonisolated static func applyPixellate(to image: UIImage, specs: [RedactionSpec]) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let extent = ciImage.extent   // CI pixel space (Y-up, device pixels)

        var result = ciImage

        for spec in specs {
            // Map normalised top-left-origin rect → CI pixel rect (Y-up)
            let ciRect = CGRect(
                x:      spec.rect.minX * extent.width,
                y:      (1.0 - spec.rect.maxY) * extent.height,
                width:  spec.rect.width  * extent.width,
                height: spec.rect.height * extent.height
            )
            guard ciRect.width > 0, ciRect.height > 0 else { continue }

            // Block size: ~12 % of the shorter dimension, clamped to [10, 40] pixels
            let blockSize = Float(
                min(40, max(10, min(ciRect.width, ciRect.height) * 0.12))
            )

            guard let pixFilter = CIFilter(name: "CIPixellate") else { continue }
            pixFilter.setValue(result, forKey: kCIInputImageKey)
            pixFilter.setValue(
                CIVector(cgPoint: CGPoint(x: ciRect.midX, y: ciRect.midY)),
                forKey: kCIInputCenterKey
            )
            pixFilter.setValue(blockSize, forKey: "inputScale")
            guard let pixellated = pixFilter.outputImage else { continue }

            // White mask inside the region → CIBlendWithMask takes from pixellated
            // where mask is white, from background (result) where mask is transparent.
            let mask = CIImage(color: CIColor.white).cropped(to: ciRect)

            guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { continue }
            blendFilter.setValue(result,     forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(pixellated, forKey: kCIInputImageKey)
            blendFilter.setValue(mask,       forKey: kCIInputMaskImageKey)

            result = blendFilter.outputImage ?? result
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgOut = ciContext.createCGImage(result, from: extent) else { return nil }
        return UIImage(cgImage: cgOut, scale: image.scale, orientation: image.imageOrientation)
    }
}
