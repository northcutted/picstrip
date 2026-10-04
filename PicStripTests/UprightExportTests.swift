import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

/// An export turns the pixels upright in one decode (`ImageProcessor.uprightImage`)
/// instead of redrawing a decoded `UIImage`.  These pin down that every EXIF
/// orientation still comes out the way it is displayed, in the source's colour.
final class UprightExportTests: XCTestCase {

    /// The picture as it is meant to be seen: a quadrant of each colour.
    /// Each quadrant is a whole number of JPEG blocks, so a JPEG keeps its colours.
    private static let width = 64
    private static let height = 32
    private static let quadrants: [(x: Int, y: Int, rgb: [UInt8])] = [
        (16, 8, [255, 0, 0]),       // top left: red
        (48, 8, [0, 255, 0]),       // top right: green
        (16, 24, [0, 0, 255]),      // bottom left: blue
        (48, 24, [255, 255, 255])   // bottom right: white
    ]

    private static func displayed() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // CGContext is y-up: the "top" quadrants are drawn at the high y.
        let half = (width / 2, height / 2)
        for (index, quadrant) in quadrants.enumerated() {
            let rgb = quadrant.rgb.map { CGFloat($0) / 255 }
            context.setFillColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            let column = index % 2, row = index / 2
            context.fill(CGRect(x: column * half.0, y: (1 - row) * half.1, width: half.0, height: half.1))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// Pixels stored so that, tagged with `orientation`, they display as `displayed()`.
    private static func stored(for orientation: CGImagePropertyOrientation, as type: UTType) throws -> Data {
        let inverse: CGImagePropertyOrientation = switch orientation {
        case .right: .left
        case .left: .right
        default: orientation
        }
        let turned = CIImage(cgImage: try displayed()).oriented(inverse)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let pixels = try XCTUnwrap(CIContext().createCGImage(turned, from: turned.extent, format: .RGBA8, colorSpace: space))

        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        // A location too: UIKit ignores the orientation of a PNG that carries
        // one, and the export must still turn it as ImageIO, the scan and the
        // preview do.
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N"]
        ]
        if type == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func rgb(of image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // Draw so that pixel (x, y), counted from the top left, lands on the one-pixel context.
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(pixel.prefix(3))
    }

    private static func assertDisplaysUpright(_ image: CGImage, _ message: String) throws {
        XCTAssertEqual(image.width, width, message)
        XCTAssertEqual(image.height, height, message)
        for quadrant in quadrants {
            let found = try rgb(of: image, x: quadrant.x, y: quadrant.y)
            for (actual, expected) in zip(found, quadrant.rgb) {
                XCTAssertEqual(Double(actual), Double(expected), accuracy: 4, "\(message): pixel (\(quadrant.x), \(quadrant.y))")
            }
        }
    }

    private static func decoded(_ data: Data) throws -> (image: CGImage, properties: [CFString: Any]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, properties)
    }

    func testEveryEXIFOrientationIsExportedUpright() throws {
        for raw in UInt32(1)...8 {
            for type in [UTType.jpeg, .png] {
                let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
                let source = try Self.stored(for: orientation, as: type)
                let name = "orientation \(raw), \(type.identifier)"

                // The fixture itself, as the editor's preview shows it: the intended way up.
                let shown = try XCTUnwrap(ImageProcessor.downsampledUIImage(from: source)?.cgImage)
                try Self.assertDisplaysUpright(shown, "Preview, \(name)")

                for preset in [ExportPreset.losslessPNG, .highQualityJPEG] {
                    // `encode` also reads the output back and rejects any metadata left in it.
                    let export = try ExportPipeline.encode(source, plan: ExportPlan(preset: preset, metadata: .allEnabled))
                    let output = try Self.decoded(export.processed.data)
                    try Self.assertDisplaysUpright(output.image, "\(name) as \(export.type.identifier)")
                    XCTAssertEqual(output.properties[kCGImagePropertyOrientation] as? UInt32 ?? 1, 1,
                                   "Upright pixels must not be tagged to turn again (\(name)).")
                    XCTAssertNil(output.properties[kCGImagePropertyGPSDictionary], name)
                }
            }
        }
    }

    /// A cover placed on the preview of a turned PNG with a location — which
    /// UIKit alone would show unturned — lands on the same part of the export.
    func testCoversLandWhereTheyWerePlacedOnATurnedPNGWithALocation() async throws {
        for orientation in [CGImagePropertyOrientation.right, .left, .down] {
            let source = try Self.stored(for: orientation, as: .png)
            let image = try XCTUnwrap(ImageProcessor.orientedImage(from: source))
            // The top left quadrant, as displayed: red.
            let cover = RedactionSpec(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), style: .solid, color: .black, isEnabled: true)
            let rendered = await ImageRedactor().redact(image: image, specs: [cover])
            let redacted = try XCTUnwrap(rendered)
            let export = try ImageProcessor.process(image: redacted, sourceData: source, preset: .losslessPNG, config: .allEnabled)
            let output = try Self.decoded(export.data).image
            let name = "orientation \(orientation.rawValue)"
            XCTAssertEqual(output.width, Self.width, name)
            XCTAssertEqual(output.height, Self.height, name)
            let expected = [(16, 8, [UInt8](repeating: 0, count: 3))] + Self.quadrants.dropFirst().map { ($0.x, $0.y, $0.rgb) }
            for (x, y, rgb) in expected {
                for (actual, wanted) in zip(try Self.rgb(of: output, x: x, y: y), rgb) {
                    XCTAssertEqual(Double(actual), Double(wanted), accuracy: 4, "\(name): pixel (\(x), \(y))")
                }
            }
        }
    }

    /// The upright bitmap must be the one UIKit's own redraw makes, pixel for pixel.
    func testUprightBitmapMatchesUIKitsRedraw() throws {
        for spaceName in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try XCTUnwrap(CGColorSpace(name: spaceName))
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            for x in 0..<96 {
                context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(x) / 96, 0.3, 1 - CGFloat(x) / 96, 1]) ?? CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: x, y: (x * 7) % 64, width: 1, height: 64 - (x * 7) % 64))
            }
            let pixels = try XCTUnwrap(context.makeImage())
            for raw in UInt32(2)...8 {
                let output = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: raw] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))

                let shown = try XCTUnwrap(UIImage(data: output as Data))
                let format = shown.imageRendererFormat
                format.opaque = true
                let redraw = try XCTUnwrap(UIGraphicsImageRenderer(size: shown.size, format: format).image { _ in
                    shown.draw(in: CGRect(origin: .zero, size: shown.size))
                }.cgImage)
                let upright = try XCTUnwrap(ImageProcessor.uprightImage(from: output as Data))
                let name = "\(spaceName), orientation \(raw)"
                XCTAssertEqual(upright.colorSpace?.name, redraw.colorSpace?.name, name)
                XCTAssertEqual(upright.bitsPerComponent, redraw.bitsPerComponent, name)
                XCTAssertEqual(try Self.bytes(of: upright), try Self.bytes(of: redraw), name)
            }
        }
    }

    private static func bytes(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 4 * image.width * image.height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 4 * image.width,
            space: try XCTUnwrap(image.colorSpace), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// Encodes one solid image of `space` and `bitsPerComponent`, stored sideways.
    private static func sideways(
        space: CGColorSpace, bitsPerComponent: Int, type: UTType
    ) throws -> Data {
        var info = CGImageAlphaInfo.noneSkipLast.rawValue
        if bitsPerComponent == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
            space: space, bitmapInfo: info
        ))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0.9, 0.2, 0.1, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyOrientation: 6 as UInt32
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testTurningUprightKeepsColourSpaceAndBitDepth() throws {
        let cases: [(name: String, space: CFString, bits: Int, source: UTType, preset: ExportPreset, depth: Int)] = [
            ("Display P3, 8-bit JPEG", CGColorSpace.displayP3, 8, .jpeg, .highQualityJPEG, 8),
            ("Display P3, 16-bit PNG", CGColorSpace.displayP3, 16, .png, .losslessPNG, 16),
            ("HDR (PQ) HEIC", CGColorSpace.itur_2100_PQ, 16, .heic, .heicOriginal, 10)
        ]
        for item in cases {
            let space = try XCTUnwrap(CGColorSpace(name: item.space))
            let source = try Self.sideways(space: space, bitsPerComponent: item.bits, type: item.source)
            let sourceDepth = try Self.decoded(source).image.bitsPerComponent

            let upright = try XCTUnwrap(ImageProcessor.uprightImage(from: source), item.name)
            XCTAssertEqual(upright.width, 20, item.name)
            XCTAssertEqual(upright.height, 40, item.name)
            XCTAssertEqual(upright.colorSpace?.name, item.space, item.name)
            // 10-bit HDR is widened to 16 bits for the encoder; nothing is ever narrowed.
            XCTAssertGreaterThanOrEqual(upright.bitsPerComponent, sourceDepth, item.name)

            let export: VerifiedExport
            do {
                export = try ExportPipeline.encode(source, plan: ExportPlan(preset: item.preset, metadata: .allEnabled))
            } catch {
                XCTFail("\(item.name): \(error)")
                continue
            }
            let output = try Self.decoded(export.processed.data)
            XCTAssertEqual(output.image.width, 20, item.name)
            XCTAssertEqual(output.image.colorSpace?.name, item.space, item.name)
            XCTAssertEqual(output.properties[kCGImagePropertyDepth] as? Int, item.depth, item.name)
        }
    }
}
