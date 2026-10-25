import CoreImage
import UIKit
import XCTest
@testable import PicStrip

@MainActor
final class RedactionShapeTests: XCTestCase {
    private let box = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    func testEveryStyleKeepsTheOvalCornersUntouched() async throws {
        let image = checkerboard()
        let original = try pixels(image)
        for style in RedactionStyle.allCases {
            let spec = RedactionSpec(rect: box, style: style, color: .red, isEnabled: true, shape: .oval)
            let renderedImage = await ImageRedactor().redact(image: image, specs: [spec])
            let rendered = try XCTUnwrap(renderedImage)
            let result = try pixels(rendered)
            for (x, y) in [(22, 22), (177, 22), (22, 177), (177, 177), (5, 100)] {
                XCTAssertEqual(pixel(result, x, y), pixel(original, x, y), "\(style) leaked outside the oval")
            }
            let changed = (70..<130).reduce(0) { total, y in
                total + (70..<130).filter { pixel(result, $0, y) != pixel(original, $0, y) }.count
            }
            XCTAssertGreaterThan(changed, 500, "\(style) must actually cover the oval")
        }
    }

    func testCustomOutlineUsesTopLeftCoordinatesForPaintAndScramble() async throws {
        let image = checkerboard()
        let original = try pixels(image)
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        for style in [RedactionStyle.solid, .crosshatch, .pixelate, .blur, .emoji] {
            let spec = RedactionSpec(rect: box, style: style, color: .red, isEnabled: true, shape: .custom, vertices: triangle)
            let renderedImage = await ImageRedactor().redact(image: image, specs: [spec])
            let output = try XCTUnwrap(renderedImage)
            let result = try pixels(output)
            XCTAssertEqual(pixel(result, 160, 160), pixel(original, 160, 160), "The lower-right is outside: \(style)")
            let changed = (40..<70).reduce(0) { count, y in
                count + (40..<70).filter { pixel(result, $0, y) != pixel(original, $0, y) }.count
            }
            XCTAssertGreaterThan(changed, 100, "The upper-left is inside: \(style)")
        }
    }

    func testOppositeWindingOutlinesOverlapWithoutMakingAHole() async throws {
        let image = checkerboard()
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let specs = [points, points.reversed().map { $0 }].map {
            RedactionSpec(rect: box, style: .pixelate, color: .black, isEnabled: true, shape: .custom, vertices: $0)
        }
        let renderedImage = await ImageRedactor().redact(image: image, specs: specs)
        let output = try XCTUnwrap(renderedImage)
        let singleImage = await ImageRedactor().redact(image: image, specs: [specs[0]])
        let single = try XCTUnwrap(singleImage)
        XCTAssertTrue(try pixels(output) == pixels(single), "Opposite winding must give the same mask as one outline")
        XCTAssertFalse(try pixels(output) == pixels(image), "The overlapped region must be obscured")
    }

    func testSquareAndCircleUseEqualPixelSidesOnPortraitImages() {
        for shape in [RedactionShape.square, .circle] {
            let result = shape.constrained(CGRect(x: 0.85, y: 0.8, width: 0.2, height: 0.15),
                                           imageSize: CGSize(width: 400, height: 800))
            XCTAssertEqual(result.width * 400, result.height * 800, accuracy: 0.001)
            XCTAssertLessThanOrEqual(result.maxX, 1)
            XCTAssertLessThanOrEqual(result.maxY, 1)
            XCTAssertGreaterThanOrEqual(result.minX, 0)
        }
    }

    func testLongTracesKeepTheirBeginningAndCurrentEndpoint() {
        var points: [CGPoint] = []
        for index in 0...1000 {
            let angle = CGFloat(index) * .pi / 500
            let point = CGPoint(x: 0.5 + 0.4 * cos(angle), y: 0.5 + 0.4 * sin(angle))
            RedactionShape.append(point, to: &points, minimumDistance: 0)
            XCTAssertLessThanOrEqual(points.count, 256)
            XCTAssertEqual(points.last, point)
        }
        XCTAssertEqual(points.first, CGPoint(x: 0.9, y: 0.5))
        XCTAssertTrue(RedactionShape.validVertices(points))
    }

    func testShapeAndOutlineChangesUndoAndInvalidateTheRenderKey() async throws {
        let model = ScrubberViewModel()
        model.addCustomRedaction(rect: box)
        let id = try XCTUnwrap(model.redactionRegions.first?.id)
        let original = model.redactionRegions
        model.changeRedactionShape(id: id, shape: .oval)
        XCTAssertNotEqual(original.map(\.spec), model.redactionRegions.map(\.spec))
        model.undoRedaction()
        XCTAssertEqual(model.redactionRegions, original)
        model.redoRedaction()
        XCTAssertEqual(model.redactionRegions.first?.shape, .oval)
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        model.changeRedactionOutline(id: id, vertices: points)
        model.beginRedactionUpdate(id: id)
        model.updateRedactionRegion(id: id, rect: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.4))
        XCTAssertEqual(model.redactionRegions.first?.vertices, points)
        model.undoRedaction()
        XCTAssertEqual(model.redactionRegions.first?.rect, box)
        model.undoRedaction()
        XCTAssertEqual(model.redactionRegions.first?.shape, .oval)
    }

    func testInvalidOutlinesAreRejectedWithoutAnUndoEntry() async {
        let model = ScrubberViewModel()
        model.addCustomRedaction(rect: box)
        guard let id = model.redactionRegions.first?.id else { return XCTFail("No region") }
        let before = model.redactionRegions
        for points in [[CGPoint.zero], [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 0)],
                       [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 1, y: 1), CGPoint.zero]] {
            model.changeRedactionOutline(id: id, vertices: points)
            XCTAssertEqual(model.redactionRegions, before)
        }
        model.undoRedaction()
        XCTAssertTrue(model.redactionRegions.isEmpty)
    }

    func testVideoUsesTheSameCustomMaskAsPhotos() throws {
        let source = checkerboard()
        let image = try XCTUnwrap(CIImage(image: source))
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        var track = FaceTrack(id: 1, samples: [.init(time: 0, box: box)], isDrawn: true)
        track.shape = .custom
        track.vertices = triangle
        let plan = VideoRedactor.Plan(faces: [.init(track: track, style: .solid)])
        let result = VideoRedactor.render(image, at: 0, plan: plan, glyphs: [:])
        let rendered = try XCTUnwrap(CIContext().createCGImage(result, from: image.extent))
        let data = try pixels(UIImage(cgImage: rendered))
        let original = try pixels(source)
        XCTAssertEqual(pixel(original, 160, 162), [255, 255, 255, 255])
        XCTAssertEqual(pixel(data, 160, 162), pixel(original, 160, 162), "Outside the triangle stays visible")
        XCTAssertEqual(pixel(original, 52, 50), [255, 255, 255, 255])
        XCTAssertEqual(pixel(data, 52, 50), [0, 0, 0, 255], "The triangle covers an originally white pixel")
    }

    private func checkerboard() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.black.setFill()
            for y in stride(from: 0, to: 200, by: 2) {
                for x in stride(from: (y / 2).isMultiple(of: 2) ? 0 : 2, to: 200, by: 4) {
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 200 * 200 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        return bytes
    }

    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
        Array(bytes[(y * 200 + x) * 4..<(y * 200 + x) * 4 + 4])
    }
}
