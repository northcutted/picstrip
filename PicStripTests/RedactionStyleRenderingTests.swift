@testable import PicStrip
import UIKit
import XCTest

/// What each redaction style actually burns into the exported pixels.
@MainActor
final class RedactionStyleRenderingTests: XCTestCase {

    private let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    // MARK: - Crosshatch

    /// Crosshatch is a redaction, so nothing of the source may show through it:
    /// the same region over a white photo and over a black photo has to come
    /// out pixel-for-pixel identical.
    func testCrosshatchLetsNothingOfTheSourceShowThrough() async throws {
        let spec = RedactionSpec(rect: region, style: .crosshatch, color: .black, isEnabled: true)
        let overWhite = try await render(spec, over: flatImage(.white))
        let overBlack = try await render(spec, over: flatImage(.black))

        // Stay a pixel inside the edge, where antialiasing blends with the photo.
        for y in stride(from: 52, to: 148, by: 3) {
            for x in stride(from: 52, to: 148, by: 3) {
                XCTAssertEqual(overWhite.pixel(x, y), overBlack.pixel(x, y), "Source shows through at (\(x), \(y)).")
            }
        }
    }

    /// The point of the style is that it does not look like a solid block.
    func testCrosshatchDrawsAVisibleLatticeUnlikeSolid() async throws {
        let image = flatImage(.white)
        let hatch = try await render(
            RedactionSpec(rect: region, style: .crosshatch, color: .black, isEnabled: true), over: image
        )
        let solid = try await render(
            RedactionSpec(rect: region, style: .solid, color: .black, isEnabled: true), over: image
        )

        var hatchLevels = Set<UInt8>()
        var solidLevels = Set<UInt8>()
        for x in 52..<148 {
            hatchLevels.insert(hatch.pixel(x, 100)[0])
            solidLevels.insert(solid.pixel(x, 100)[0])
        }
        XCTAssertEqual(solidLevels.count, 1, "Solid is one flat colour.")
        let brightest = try XCTUnwrap(hatchLevels.max())
        let darkest = try XCTUnwrap(hatchLevels.min())
        XCTAssertLessThan(darkest, 20, "The base of a black crosshatch is black.")
        XCTAssertGreaterThan(brightest, 110, "The lattice must stand out from the base, got \(brightest).")
    }

    /// Light fills get dark lines; every colour must contrast with its own lattice.
    func testEveryColourContrastsWithItsLattice() {
        for color in RedactionColor.allCases {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            var lattice: CGFloat = 0
            color.uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
            color.latticeColor.getWhite(&lattice, alpha: nil)
            let fill = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            XCTAssertGreaterThan(abs(fill - lattice), 0.4, "\(color) lattice would not show on its fill.")
        }
    }

    // MARK: - Strength

    /// The lightest setting is exactly what shipped before strength existed, and
    /// every step up uses bigger blocks.
    func testBlockSizeNeverDropsBelowTheOldDefaultAndGrowsWithStrength() {
        for side in [20, 80, 150, 400, 2000] as [CGFloat] {
            let legacy = min(40, max(10, side * 0.12))
            XCTAssertEqual(RedactionStrength.blockSize(shortSide: side, strength: 0), legacy, accuracy: 0.001)

            var previous = legacy
            for strength in stride(from: 0.25, through: 1.0, by: 0.25) {
                let size = RedactionStrength.blockSize(shortSide: side, strength: strength)
                XCTAssertGreaterThanOrEqual(size, previous, "side \(side), strength \(strength)")
                previous = size
            }
        }
        XCTAssertGreaterThan(
            RedactionStrength.blockSize(shortSide: 400, strength: RedactionStrength.standard),
            RedactionStrength.blockSize(shortSide: 400, strength: 0),
            "The default is stronger than the old fixed setting."
        )
    }

    func testStrengthSnapsToStepsInsideItsRange() {
        XCTAssertEqual(RedactionStrength.clamped(-3), 0)
        XCTAssertEqual(RedactionStrength.clamped(9), 1)
        XCTAssertEqual(RedactionStrength.clamped(0.61), 0.5)
        XCTAssertEqual(RedactionStrength.clamped(0.66), 0.75)
    }

    /// A stronger pixelate leaves fewer distinct blocks across the same region.
    func testStrongerPixelateLeavesLessDetail() async throws {
        let image = gradientImage()
        var levels: [Double: Int] = [:]
        for strength in [0.0, 1.0] {
            let spec = RedactionSpec(rect: region, style: .pixelate, color: .black, isEnabled: true, strength: strength)
            let result = try await render(spec, over: image)
            levels[strength] = Set((52..<148).map { result.pixel($0, 100)[0] }).count
        }
        let light = try XCTUnwrap(levels[0.0])
        let strong = try XCTUnwrap(levels[1.0])
        XCTAssertGreaterThan(light, strong, "light \(light) blocks, strong \(strong) blocks")
    }

    /// Two strengths in one export each get their own pass.
    func testRegionsWithDifferentStrengthsAreBothObscured() async throws {
        let left = RedactionSpec(
            rect: CGRect(x: 0.05, y: 0.25, width: 0.4, height: 0.5),
            style: .pixelate, color: .black, isEnabled: true, strength: 0
        )
        let right = RedactionSpec(
            rect: CGRect(x: 0.55, y: 0.25, width: 0.4, height: 0.5),
            style: .pixelate, color: .black, isEnabled: true, strength: 1
        )
        let rendered = await ImageRedactor().redact(image: gradientImage(), specs: [left, right])
        let result = try Bitmap(XCTUnwrap(rendered))
        let leftLevels = Set((14..<86).map { result.pixel($0, 100)[0] }).count
        let rightLevels = Set((114..<186).map { result.pixel($0, 100)[0] }).count
        XCTAssertLessThan(leftLevels, 40, "The light region was left as a smooth gradient.")
        XCTAssertLessThan(rightLevels, leftLevels, "The strong region should have fewer blocks than the light one.")
    }

    /// Portrait iPhone photos are stored sideways with an orientation flag.  The
    /// Core Image styles must land where the box was drawn, not where that spot
    /// sits in the unrotated sensor data.
    func testBlurLandsOnTheBoxForARotatedPhoto() async throws {
        let sensor = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { ctx in
            for row in 0..<100 {
                for column in 0..<200 {
                    ((row + column).isMultiple(of: 2) ? UIColor.black : UIColor.white).setFill()
                    ctx.fill(CGRect(x: column, y: row, width: 1, height: 1))
                }
            }
        }
        let portrait = UIImage(cgImage: try XCTUnwrap(sensor.cgImage), scale: 1, orientation: .right)
        XCTAssertEqual(portrait.size, CGSize(width: 100, height: 200))

        for style in [RedactionStyle.blur, .pixelate] {
            let top = RedactionSpec(rect: CGRect(x: 0, y: 0, width: 1, height: 0.3), style: style, color: .black, isEnabled: true)
            let rendered = await ImageRedactor().redact(image: portrait, specs: [top])
            let result = try Bitmap(XCTUnwrap(rendered))

            let insideA = Int(result.pixel(50, 30)[0]), insideB = Int(result.pixel(51, 30)[0])
            XCTAssertLessThan(abs(insideA - insideB), 40, "\(style): the top of the photo is still a crisp checkerboard.")
            let outsideA = Int(result.pixel(50, 150)[0]), outsideB = Int(result.pixel(51, 150)[0])
            XCTAssertGreaterThan(abs(outsideA - outsideB), 200, "\(style): the rest of the photo must be untouched.")
        }
    }

    /// A region dragged out to the photo's edge must be obscured right up to the
    /// last pixel.  Mosaic blocks that straddle the edge used to come out
    /// transparent (their sample point is outside the image), and the blur
    /// faded into them.
    func testPixelateAndBlurReachTheVeryEdgeOfThePhoto() async throws {
        // 203 is prime, so whatever the block size, the edge blocks are partial.
        let side = 203
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            for row in 0..<side {
                for column in 0..<side {
                    ((row + column).isMultiple(of: 2) ? UIColor.black : UIColor.white).setFill()
                    ctx.fill(CGRect(x: column, y: row, width: 1, height: 1))
                }
            }
        }
        let wholePhoto = CGRect(x: 0, y: 0, width: 1, height: 1)

        for style in [RedactionStyle.pixelate, .blur] {
            for strength in [0.0, 0.5, 1.0] {
                let spec = RedactionSpec(rect: wholePhoto, style: style, color: .black, isEnabled: true, strength: strength)
                let exported = try await render(spec, over: image)
                let block = RedactionStrength.blockSize(
                    forNormalizedRects: [wholePhoto], pixelSize: image.size, strength: strength
                )
                let layer = await ImageRedactor().previewLayer(style, blockSize: block, of: image)
                let preview = try Bitmap(XCTUnwrap(layer))

                for (name, bitmap) in [("export", exported), ("preview", preview)] {
                    let label = "\(name) \(style) @ \(strength)"
                    // The four outermost rows and columns of the photo.
                    for line in [0, side - 1] {
                        let row = (0..<side).map { bitmap.pixel($0, line) }
                        let column = (0..<side).map { bitmap.pixel(line, $0) }
                        for (edgeName, pixels) in [("row \(line)", row), ("column \(line)", column)] {
                            XCTAssertTrue(pixels.allSatisfy { $0[3] == 255 }, "\(label), \(edgeName): see-through pixels.")
                            // The source flips black/white at every pixel.  A mosaic
                            // changes once per block at most; a blur barely at all.
                            let flips = zip(pixels, pixels.dropFirst())
                                .filter { abs(Int($0[0]) - Int($1[0])) > 200 }.count
                            XCTAssertLessThan(flips, side / 8, "\(label), \(edgeName): \(flips) hard edges — the checkerboard survives.")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Live preview

    /// The editor masks `previewLayer` to a region.  Inside the region that has
    /// to be the same pixels the export produces, or the preview is a lie.
    func testPreviewLayerMatchesTheExportInsideTheRegion() async throws {
        let image = gradientImage()
        for style in [RedactionStyle.pixelate, .blur] {
            for strength in [0.0, 0.5, 1.0] {
                let spec = RedactionSpec(rect: region, style: style, color: .black, isEnabled: true, strength: strength)
                let exported = try await render(spec, over: image)

                let block = RedactionStrength.blockSize(
                    forNormalizedRects: [region], pixelSize: CGSize(width: 200, height: 200), strength: strength
                )
                let layer = await ImageRedactor().previewLayer(style, blockSize: block, of: image)
                let preview = try Bitmap(XCTUnwrap(layer))

                for y in stride(from: 54, to: 146, by: 7) {
                    for x in stride(from: 54, to: 146, by: 7) {
                        let difference = abs(Int(exported.pixel(x, y)[0]) - Int(preview.pixel(x, y)[0]))
                        XCTAssertLessThanOrEqual(difference, 2, "\(style) @ \(strength): (\(x), \(y)) differs by \(difference).")
                    }
                }
            }
        }
    }

    func testPreviewLayerExistsOnlyForStylesThatScramblePixels() async {
        let image = flatImage(.white)
        for style in RedactionStyle.allCases {
            let layer = await ImageRedactor().previewLayer(style, blockSize: 12, of: image)
            XCTAssertEqual(layer != nil, style.obscuresSourcePixels, "\(style)")
            if let layer { XCTAssertEqual(layer.size, image.size) }
        }
    }

    /// The preview image is capped at 2 400 px; the view model has to say how much
    /// bigger the export is, or pixel-sized effects would preview too coarse.
    func testViewModelReportsHowMuchLargerTheExportIsThanThePreview() async throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4800, height: 1200), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4800, height: 1200))
        }
        let viewModel = ScrubberViewModel(scanImage: { _ in [] })
        await viewModel.loadData(try XCTUnwrap(big.jpegData(compressionQuality: 0.8)))
        XCTAssertEqual(viewModel.exportScale, 2, accuracy: 0.01)

        let small = flatImage(.white)
        await viewModel.loadData(try XCTUnwrap(small.pngData()))
        XCTAssertEqual(viewModel.exportScale, 1, accuracy: 0.001)
    }

    // MARK: - View model

    func testChangingStrengthIsOneUndoStepAndOnlyAppliesToStylesThatUseIt() {
        let viewModel = ScrubberViewModel()
        viewModel.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        viewModel.addCustomRedaction(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        let blurred = viewModel.redactionRegions[0].id
        let solid = viewModel.redactionRegions[1].id
        viewModel.changeRedactionStyle(id: blurred, style: .blur)
        XCTAssertEqual(viewModel.redactionRegions[0].strength, RedactionStrength.standard)

        viewModel.bulkChangeRedactionStrength(ids: [blurred, solid], strength: 0.98)
        XCTAssertEqual(viewModel.redactionRegions[0].strength, 1, "Strength snaps to a step.")
        XCTAssertEqual(viewModel.redactionRegions[1].strength, RedactionStrength.standard, "Solid has no strength.")
        XCTAssertEqual(viewModel.redactionRegions[0].spec.strength, 1, "The renderer must receive it.")

        viewModel.undoRedaction()
        XCTAssertEqual(viewModel.redactionRegions[0].strength, RedactionStrength.standard)
        XCTAssertEqual(viewModel.redactionRegions[0].style, .blur, "One undo reverts the strength only.")
    }

    func testSettingTheSameStrengthDoesNotPushAnUndoStep() {
        let viewModel = ScrubberViewModel()
        viewModel.addCustomRedaction(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let id = viewModel.redactionRegions[0].id
        viewModel.changeRedactionStyle(id: id, style: .pixelate)
        viewModel.changeRedactionStrength(id: id, strength: RedactionStrength.standard)

        viewModel.undoRedaction()
        XCTAssertEqual(viewModel.redactionRegions[0].style, .solid, "The no-op strength change must not be on the stack.")
    }

    // MARK: - Helpers

    private var format: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return format
    }

    private func flatImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
    }

    /// A horizontal black-to-white ramp: every column is a different grey.
    private func gradientImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { ctx in
            for column in 0..<200 {
                UIColor(white: CGFloat(column) / 199, alpha: 1).setFill()
                ctx.fill(CGRect(x: column, y: 0, width: 1, height: 200))
            }
        }
    }

    private func render(_ spec: RedactionSpec, over image: UIImage) async throws -> Bitmap {
        let rendered = await ImageRedactor().redact(image: image, specs: [spec])
        return try Bitmap(XCTUnwrap(rendered))
    }

    private struct Bitmap {
        let width: Int
        let bytes: [UInt8]

        init(_ image: UIImage) throws {
            let cgImage = try XCTUnwrap(image.cgImage)
            width = cgImage.width
            var pixels = [UInt8](repeating: 0, count: 4 * cgImage.width * cgImage.height)
            let context = try XCTUnwrap(CGContext(
                data: &pixels,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 4 * cgImage.width,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            bytes = pixels
        }

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = 4 * (y * width + x)
            return Array(bytes[offset..<(offset + 4)])
        }
    }
}
