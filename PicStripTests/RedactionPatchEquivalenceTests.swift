@testable import PicStrip
import CoreImage
import UIKit
import XCTest

/// `ImageRedactor` scrambles only the regions now, instead of the whole photo
/// blended in through a mask.  The pixels must be the ones the full-frame
/// version produced: this keeps that version as the reference.
final class RedactionPatchEquivalenceTests: XCTestCase {

    /// A photo-like picture: smooth gradients under sharp text and lines.
    private func busyImage(orientation: UIImage.Orientation) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 640, height: 420)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for x in stride(from: 0, to: Int(size.width), by: 4) {
                UIColor(hue: CGFloat(x) / size.width, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 4, height: size.height))
            }
            for row in 0..<12 {
                ("4111 1111 1111 1111  alex@example.com  +1 202 555 0147" as NSString).draw(
                    at: CGPoint(x: 10, y: 8 + row * 34),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.black]
                )
            }
        }
        return UIImage(cgImage: try XCTUnwrap(image.cgImage), scale: 1, orientation: orientation)
    }

    private let specs = [
        RedactionSpec(rect: CGRect(x: 0.05, y: 0.08, width: 0.30, height: 0.12), style: .pixelate, color: .black, isEnabled: true, strength: 0),
        RedactionSpec(rect: CGRect(x: 0.20, y: 0.15, width: 0.25, height: 0.20), style: .blur, color: .black, isEnabled: true, strength: 0.5),
        RedactionSpec(rect: CGRect(x: 0.55, y: 0.40, width: 0.30, height: 0.25), style: .blur, color: .black, isEnabled: true, strength: 1),
        RedactionSpec(rect: CGRect(x: 0.60, y: 0.50, width: 0.20, height: 0.30), style: .pixelate, color: .black, isEnabled: true, strength: 1),
        // Fractional edges, and one region running off the photo's corner.
        RedactionSpec(rect: CGRect(x: 0.1013, y: 0.7021, width: 0.2117, height: 0.0937), style: .pixelate, color: .black, isEnabled: true, strength: 0.5),
        RedactionSpec(rect: CGRect(x: 0.85, y: 0.85, width: 0.15, height: 0.15), style: .blur, color: .black, isEnabled: true, strength: 0.25)
    ]

    func testScramblingOnlyTheRegionsMatchesTheFullFrameRender() async throws {
        for orientation in [UIImage.Orientation.up, .right] {
            let image = try busyImage(orientation: orientation)
            let rendered = await ImageRedactor().redact(image: image, specs: specs)
            let actual = try Pixels(XCTUnwrap(rendered))
            let expected = try Pixels(XCTUnwrap(Self.fullFrameRedaction(of: image, specs: specs)))
            XCTAssertEqual(actual.width, expected.width)
            XCTAssertEqual(actual.height, expected.height)

            var worst = 0
            var off = 0
            for index in 0..<actual.bytes.count {
                let difference = abs(Int(actual.bytes[index]) - Int(expected.bytes[index]))
                worst = max(worst, difference)
                if difference > 2 { off += 1 }
            }
            // Rounding may differ by a level here and there; the picture may not.
            XCTAssertLessThanOrEqual(worst, 3, "\(orientation): a pixel differs by \(worst) levels.")
            XCTAssertEqual(off, 0, "\(orientation): \(off) channel values differ by more than 2 levels.")
        }
    }

    // MARK: - The full-frame render, as `ImageRedactor` did it before

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private static func fullFrameRedaction(of image: UIImage, specs: [RedactionSpec]) -> UIImage? {
        var working = image
        for style in [RedactionStyle.pixelate, .blur] {
            let styled = specs.filter { $0.style.scramblePass == style }
            for strength in Set(styled.map(\.passStrength)).sorted() {
                let group = styled.filter { $0.passStrength == strength }
                guard let obscured = fullFrame(style, strength: strength, to: working, specs: group) else { return nil }
                working = obscured
            }
        }
        let renderer = UIGraphicsImageRenderer(size: image.size, format: image.imageRendererFormat)
        return renderer.image { _ in working.draw(at: .zero) }
    }

    private static func fullFrame(_ style: RedactionStyle, strength: Double, to image: UIImage, specs: [RedactionSpec]) -> UIImage? {
        guard let base = CIImage(image: image) else { return nil }
        let exif: CGImagePropertyOrientation = image.imageOrientation == .right ? .right : .up
        let turned = base.oriented(exif)
        let ciImage = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
        let extent = ciImage.extent
        let rects = specs.map { spec in
            CGRect(x: spec.rect.minX * extent.width, y: (1 - spec.rect.maxY) * extent.height,
                   width: spec.rect.width * extent.width, height: spec.rect.height * extent.height)
        }
        let blockSize = RedactionStrength.blockSize(forNormalizedRects: specs.map(\.rect), pixelSize: extent.size, strength: strength)
        guard let obscured = ImageRedactor.obscuredLayer(style, blockSize: blockSize, of: ciImage) else { return nil }
        var mask = CIImage(color: .clear).cropped(to: extent)
        for rect in rects {
            mask = CIImage(color: .white).cropped(to: rect).composited(over: mask)
        }
        let blend = CIFilter(name: "CIBlendWithMask")
        blend?.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
        blend?.setValue(obscured, forKey: kCIInputImageKey)
        blend?.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let result = blend?.outputImage, let cgImage = context.createCGImage(result, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: UIImage) throws {
            let cgImage = try XCTUnwrap(image.cgImage)
            width = cgImage.width
            height = cgImage.height
            var pixels = [UInt8](repeating: 0, count: 4 * width * height)
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4 * width,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = pixels
        }
    }
}
