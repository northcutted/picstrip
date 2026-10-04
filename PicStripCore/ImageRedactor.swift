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
    /// Opaque fill with a contrasting diagonal lattice drawn over it.
    case crosshatch
    /// Pixellates (mosaics) the underlying image region. The `color` property is ignored.
    case pixelate
    /// Smoothly blurs the underlying image region. The `color` property is ignored.
    case blur
    /// An emoji over the region (`RedactionSpec.emoji`), on the strongest blur:
    /// emoji have transparent corners and gaps, and those must not show a face.
    case emoji

    var displayName: String {
        switch self {
        case .solid:      return String(localized: "Solid")
        case .crosshatch: return String(localized: "Crosshatch")
        case .pixelate:   return String(localized: "Pixelate")
        case .blur:       return String(localized: "Blur")
        case .emoji:      return String(localized: "Emoji")
        }
    }

    var symbolName: String {
        switch self {
        case .solid:      return "rectangle.fill"
        case .crosshatch: return "grid"
        case .pixelate:   return "square.grid.3x3.middle.filled"
        case .blur:       return "drop.fill"
        case .emoji:      return "face.smiling"
        }
    }

    /// Whether the `color` property has any visual effect on the rendered output.
    var supportsColor: Bool { !obscuresSourcePixels }

    /// `true` for styles that scramble the pixels underneath (Core Image pass)
    /// instead of painting over them.
    var obscuresSourcePixels: Bool { scramblePass != nil }

    /// The Core Image pass that scrambles this style's region: an emoji sits on a blur.
    var scramblePass: RedactionStyle? {
        switch self {
        case .pixelate:      return .pixelate
        case .blur, .emoji:  return .blur
        case .solid, .crosshatch: return nil
        }
    }

    /// Whether `RedactionSpec.strength` changes the rendered output.  The blur
    /// under an emoji is always the strongest.
    var supportsStrength: Bool { self == .pixelate || self == .blur }
}

// MARK: - RedactionStrength

/// How hard `.pixelate` and `.blur` scramble a region, from 0 (lightest) to 1.
///
/// The lightest setting is what PicStrip shipped before strength existed, so no
/// setting is weaker than that; the default is deliberately stronger.
nonisolated enum RedactionStrength {
    static let range: ClosedRange<Double> = 0...1
    /// The UI moves in these steps, which also bounds how many Core Image
    /// passes one export can need (one per style and distinct strength).
    static let step = 0.25
    static let standard = 0.5

    static func clamped(_ value: Double) -> Double {
        let snapped = (value / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    /// The block edge one export pass uses for `rects` (normalised, 0 … 1) on an
    /// image of `pixelSize`: every region in a pass shares the size chosen for
    /// the smallest of them.
    static func blockSize(forNormalizedRects rects: [CGRect], pixelSize: CGSize, strength: Double) -> CGFloat {
        let smallest = rects
            .map { min($0.width * pixelSize.width, $0.height * pixelSize.height) }
            .filter { $0 > 0 }
            .min() ?? 100
        return blockSize(shortSide: smallest, strength: strength)
    }

    /// Mosaic block edge, in pixels, for a region whose short side is `shortSide`.
    /// Blur uses the same blocks and then smooths them, so it scales with this too.
    static func blockSize(shortSide: CGFloat, strength: Double) -> CGFloat {
        let t = CGFloat(clamped(strength))
        let fraction = 0.12 + (0.45 - 0.12) * t
        let cap = 40 + (160 - 40) * t
        return min(cap, max(10, shortSide * fraction))
    }
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

nonisolated extension RedactionColor {
    /// The crosshatch lattice: light lines on dark fills, dark lines on light ones.
    var latticeColor: UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.5 ? UIColor(white: 0, alpha: 0.55) : UIColor(white: 1, alpha: 0.6)
    }
}

// MARK: - RedactionLattice

/// Geometry of the crosshatch lattice, shared by the export renderer and the
/// editor's live preview so the two cannot drift apart.
nonisolated enum RedactionLattice {
    /// Line spacing and width, in the same units as `rect` and `imageSize`.
    ///
    /// The lattice scales with the region and the image, so it is still a
    /// visible pattern on a 48 MP photo instead of hairlines that average out
    /// to a flat tint.
    static func metrics(rect: CGRect, imageSize: CGSize) -> (spacing: CGFloat, lineWidth: CGFloat) {
        let shortSide = min(rect.width, rect.height)
        let floor = max(6, max(imageSize.width, imageSize.height) / 160)
        let spacing = max(floor, shortSide / 3.5)
        return (spacing, max(1.5, spacing * 0.16))
    }

    /// Both diagonal families across `rect`; the caller clips to `rect`.
    static func path(in rect: CGRect, spacing: CGFloat) -> CGPath {
        let path = CGMutablePath()
        var startX = rect.minX - rect.height
        while startX < rect.maxX {
            path.move(to: CGPoint(x: startX, y: rect.minY))
            path.addLine(to: CGPoint(x: startX + rect.height, y: rect.maxY))
            path.move(to: CGPoint(x: startX + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: startX, y: rect.maxY))
            startX += spacing
        }
        return path
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
nonisolated struct RedactionSpec: Equatable {
    let rect: CGRect
    let style: RedactionStyle
    let color: RedactionColor
    /// When `false` this spec is skipped by the renderer.
    let isEnabled: Bool
    /// See `RedactionStrength`.  Ignored unless the style `supportsStrength`.
    var strength: Double = RedactionStrength.standard
    /// The emoji drawn by `.emoji`; ignored by every other style.
    var emoji: String = EmojiCover.defaultEmoji

    /// The strength of this region's scramble pass.
    var passStrength: Double {
        style == .emoji ? RedactionStrength.range.upperBound : RedactionStrength.clamped(strength)
    }
}

// MARK: - EmojiCover

/// The emoji that `.emoji` draws, and how large.
nonisolated enum EmojiCover {
    static let defaultEmoji = "🙂"

    /// Offered in the editor; any other single emoji can be typed.
    static let choices = [
        "🙂", "😀", "😎", "🤓", "🥸", "😺", "🐶", "🐱", "🐼", "🦊", "🐸", "🐵",
        "🙈", "🤖", "👽", "👻", "🤡", "🎃", "🌝", "⭐️", "🌸", "🍩", "🎈", "❤️"
    ]

    /// How much larger than the region's longer side the glyph is drawn, so a
    /// round emoji still reaches the box's corners.
    static let coverage: CGFloat = 1.2

    /// The first emoji in `text`, or `nil` when it has none — what the "other"
    /// field keeps of whatever is typed or pasted into it.
    static func firstEmoji(in text: String) -> String? {
        text.first(where: isEmoji).map(String.init)
    }

    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        // Digits and "#" are emoji-capable but only emoji with a keycap sequence.
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && character.unicodeScalars.count > 1)
    }

    /// The point size that draws `emoji` `coverage` times the longer side of `size`.
    static func fontSize(for emoji: String, covering size: CGSize) -> CGFloat {
        let reference: CGFloat = 100
        let glyph = (emoji as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: reference)])
        let glyphSide = max(glyph.width, glyph.height)
        guard glyphSide > 0 else { return max(size.width, size.height) }
        return reference * max(size.width, size.height) * coverage / glyphSide
    }

    /// Draws `emoji` centred on `rect` in the current UIKit context.
    static func draw(_ emoji: String, covering rect: CGRect) {
        let font = UIFont.systemFont(ofSize: fontSize(for: emoji, covering: rect.size))
        let text = emoji as NSString
        let glyph = text.size(withAttributes: [.font: font])
        text.draw(
            at: CGPoint(x: rect.midX - glyph.width / 2, y: rect.midY - glyph.height / 2),
            withAttributes: [.font: font]
        )
    }
}

// MARK: - ImageRedactor

/// Stateless service that burns styled redaction blocks over image regions.
///
/// **Coordinate convention:** All normalised rects use a top-left origin (0 … 1).
/// Y was already flipped in `PIIScanner`, so multiplying by `image.size` maps
/// directly into the `UIGraphicsImageRenderer` coordinate space.
///
/// **Rendering pipeline:**
/// 1. For any `.pixelate` / `.blur` specs, a CIFilter pre-pass scrambles the
///    source pixels under those regions (reads pixels, colour-agnostic) and
///    renders just the regions.
/// 2. A single `UIGraphicsImageRenderer` pass draws the source image and the
///    scrambled regions over it, then stamps each remaining style on top.
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
        let scramble = Self.scramble(image, specs: enabled)

        // ── Step 2: Raster pass for remaining styles ───────────────────────
        // `imageRendererFormat` keeps the source's colour space and depth.
        let size     = image.size
        let format   = image.imageRendererFormat
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            image.draw(at: .zero)
            for patch in scramble.patches {
                patch.image.draw(in: patch.rect)
            }

            let painted = enabled.filter { !$0.style.obscuresSourcePixels } + scramble.paintedSolidInstead
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
                    Self.renderCrosshatch(color: spec.color, rect: rect, imageSize: size, in: ctx)
                case .pixelate, .blur, .emoji:
                    // Only reached when the Core Image pass failed.
                    Self.renderSolid(color: RedactionColor.black.uiColor, rect: rect)
                }
            }

            // The emoji go on last, over their blur (or the solid fill that
            // replaced it), and may reach past their box.
            for spec in enabled where spec.style == .emoji {
                let rect = CGRect(
                    x: spec.rect.minX * size.width, y: spec.rect.minY * size.height,
                    width: spec.rect.width * size.width, height: spec.rect.height * size.height
                )
                guard rect.width > 0, rect.height > 0 else { continue }
                EmojiCover.draw(spec.emoji, covering: rect)
            }
        }
    }

    // MARK: - Live preview

    /// The whole of `image` obscured with `style` at a fixed `blockSize` (in
    /// `image` pixels).  The editor masks this to each region, so a box shows the
    /// real effect while it is being dragged.  `nil` for the painted styles.
    @concurrent
    func previewLayer(_ style: RedactionStyle, blockSize: CGFloat, of image: UIImage) async -> UIImage? {
        guard let pass = style.scramblePass,
              let ciImage = Self.uprightCIImage(image),
              let layer = Self.obscuredLayer(pass, blockSize: max(1, blockSize), of: ciImage),
              let cgImage = Self.ciContext.createCGImage(layer, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
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

    /// An opaque block with a diagonal lattice in a contrasting tone.
    ///
    /// The base is fully opaque on purpose: a see-through fill leaves the text
    /// underneath readable, which is not a redaction.
    private static func renderCrosshatch(
        color: RedactionColor,
        rect: CGRect,
        imageSize: CGSize,
        in ctx: UIGraphicsImageRendererContext
    ) {
        let cgCtx = ctx.cgContext
        cgCtx.saveGState()

        color.uiColor.setFill()
        UIRectFill(rect)

        let lattice = RedactionLattice.metrics(rect: rect, imageSize: imageSize)
        cgCtx.clip(to: rect)
        color.latticeColor.setStroke()
        cgCtx.setLineWidth(lattice.lineWidth)
        cgCtx.addPath(RedactionLattice.path(in: rect, spacing: lattice.spacing))
        cgCtx.strokePath()
        cgCtx.restoreGState()
    }

    // MARK: - Pixellate / blur (CIFilter pre-pass)

    /// What the Core Image pass made: the scrambled pixels over each region,
    /// and the regions it could not scramble, which are painted solid instead.
    private struct Scramble {
        /// Each region's pixels, with the rect (in `image` points) they go in.
        var patches: [(image: UIImage, rect: CGRect)] = []
        var paintedSolidInstead: [RedactionSpec] = []
    }

    /// Pixellates and blurs every `.pixelate`, `.blur` and `.emoji` region in
    /// one Core Image graph, and renders only the regions out of it.  Colour is
    /// ignored — the effect shows scrambled source pixels, not a solid fill.
    ///
    /// **Blur is a mosaic first.**  A plain Gaussian blur of text can be
    /// sharpened back into something legible, so `.blur` pixellates exactly as
    /// `.pixelate` does and then blurs the mosaic: it looks smooth, but carries
    /// no more information than the blocks underneath.
    ///
    /// Each style and strength is one pass with one block size, chosen from its
    /// smallest region; the passes are chained, so a later one scrambles what
    /// the earlier ones left.  A pass is rendered only around its regions, so
    /// Core Image computes the mosaic and the blur (up to 240 px) there and not
    /// over the whole photo — blending a whole-photo layer in through a mask
    /// computed both everywhere, and every pass came back as a full-size bitmap
    /// that the raster pass then drew again.
    nonisolated private static func scramble(_ image: UIImage, specs: [RedactionSpec]) -> Scramble {
        var scramble = Scramble()
        let scrambled = specs.filter { $0.style.scramblePass != nil }
        guard !scrambled.isEmpty else { return scramble }
        guard let source = uprightCIImage(image) else {
            scramble.paintedSolidInstead = scrambled
            return scramble
        }
        let extent = source.extent   // CI pixel space (Y-up, device pixels), upright

        var composite = source
        var covered: [(spec: RedactionSpec, rect: CGRect)] = []
        for style in [RedactionStyle.pixelate, .blur] {
            let styled = scrambled.filter { $0.style.scramblePass == style }
            // One pass per strength in use: a pass has a single block size.
            for strength in Set(styled.map(\.passStrength)).sorted() {
                let group = styled.filter { $0.passStrength == strength }
                let regions = group.compactMap { spec -> (spec: RedactionSpec, rect: CGRect)? in
                    let rect = CGRect(
                        x: spec.rect.minX * extent.width,
                        y: (1.0 - spec.rect.maxY) * extent.height,
                        width: spec.rect.width * extent.width,
                        height: spec.rect.height * extent.height
                    )
                    return (rect.width > 0 && rect.height > 0) ? (spec, rect) : nil
                }
                guard !regions.isEmpty else { continue }

                // Keeps the visual character of pixelation for the privacy-critical
                // small regions; large regions get slightly chunkier blocks, which is
                // still adequately obscuring.
                let blockSize = RedactionStrength.blockSize(
                    forNormalizedRects: group.map(\.rect), pixelSize: extent.size, strength: strength
                )
                // Rendered once, around this pass's regions only.  A mosaic comes
                // out the same as over the whole photo only where Core Image is
                // asked for whole blocks, so a pixelate pass reaches one block
                // past its regions.  A blur near the edge of what is rendered
                // can come out a few levels off the whole-photo one (iOS 26), so
                // a blur pass reaches twice its radius past them.
                let union = regions.reduce(CGRect.null) { $0.union($1.rect) }
                let reach = style == .pixelate ? blockSize : blockSize * 3
                let area = union.insetBy(dx: -reach, dy: -reach).integral.intersection(extent)
                guard let obscured = obscuredLayer(style, blockSize: blockSize, of: composite),
                      let rendered = ciContext.createCGImage(obscured, from: area)
                else {
                    scramble.paintedSolidInstead += group
                    continue
                }
                let layer = CIImage(cgImage: rendered)
                    .transformed(by: CGAffineTransform(translationX: area.minX, y: area.minY))
                for region in regions {
                    composite = layer.cropped(to: region.rect).composited(over: composite)
                }
                covered += regions
            }
        }

        // Whole pixels around each region, so a patch is drawn back 1:1.  The
        // edge pixels a region only partly covers blend in, as they always have.
        for region in covered {
            let pixels = region.rect.integral.intersection(extent)
            guard !pixels.isEmpty, let cgImage = ciContext.createCGImage(composite, from: pixels) else {
                scramble.paintedSolidInstead.append(region.spec)
                continue
            }
            let points = CGRect(
                x: (pixels.minX - extent.minX) / image.scale,
                y: (extent.maxY - pixels.maxY) / image.scale,
                width: pixels.width / image.scale,
                height: pixels.height / image.scale
            )
            scramble.patches.append((UIImage(cgImage: cgImage, scale: image.scale, orientation: .up), points))
        }
        return scramble
    }

    /// The whole of `ciImage` pixellated — and, for `.blur`, then blurred.
    nonisolated static func obscuredLayer(
        _ style: RedactionStyle,
        blockSize: CGFloat,
        of ciImage: CIImage
    ) -> CIImage? {
        let extent = ciImage.extent
        guard let pixFilter = CIFilter(name: "CIPixellate") else { return nil }
        // A mosaic block takes its colour from its centre.  Blocks that straddle
        // the photo's edge have their centre outside it, so without clamping they
        // come out transparent — a see-through rim, and a blur that fades into it.
        pixFilter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
        pixFilter.setValue(
            CIVector(cgPoint: CGPoint(x: extent.midX, y: extent.midY)),
            forKey: kCIInputCenterKey
        )
        pixFilter.setValue(Float(blockSize), forKey: "inputScale")
        guard let pixellated = pixFilter.outputImage else { return nil }
        guard style == .blur else { return pixellated.cropped(to: extent) }

        // The mosaic is already infinite (clamped input), so the blur has real
        // colour to pull in at the edges; crop back to the photo afterwards.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = pixellated
        blur.radius = Float(blockSize * 1.5)
        return blur.outputImage?.cropped(to: extent)
    }

    /// The image's pixels turned the way it is displayed, with the extent at the origin.
    ///
    /// `CIImage(image:)` ignores `imageOrientation`, and a portrait iPhone photo is
    /// stored sideways.  Region rects are in display space, so without this the
    /// effect lands somewhere else and the chosen region stays readable.
    nonisolated private static func uprightCIImage(_ image: UIImage) -> CIImage? {
        guard let base = CIImage(image: image) else { return nil }
        let exif: CGImagePropertyOrientation
        switch image.imageOrientation {
        case .up:            exif = .up
        case .down:          exif = .down
        case .left:          exif = .left
        case .right:         exif = .right
        case .upMirrored:    exif = .upMirrored
        case .downMirrored:  exif = .downMirrored
        case .leftMirrored:  exif = .leftMirrored
        case .rightMirrored: exif = .rightMirrored
        @unknown default:    exif = .up
        }
        let upright = base.oriented(exif)
        return upright.transformed(by: CGAffineTransform(
            translationX: -upright.extent.minX, y: -upright.extent.minY
        ))
    }
}
