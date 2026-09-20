import AVFoundation
import ImageIO
import XCTest
@testable import PicStrip

// MARK: - ScannedPageEncoder

final class ScannedPageEncoderTests: XCTestCase {

    private func page(width: Int, height: Int, orientation: UIImage.Orientation = .up) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let cgImage = try XCTUnwrap(rendered.cgImage)
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }

    private func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testEncode_producesADecodableImageWithNoLocation() async throws {
        let encoded = await ScannedPageEncoder.encode(try page(width: 40, height: 60))
        let data = try XCTUnwrap(encoded)

        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size, CGSize(width: 40, height: 60))
        XCTAssertNil(properties(of: data)[kCGImagePropertyGPSDictionary])
    }

    /// Bounding boxes are computed from the encoded bytes, so a page the camera
    /// delivers rotated must still decode the right way up.
    func testEncode_keepsARotatedPageUpright() async throws {
        let sideways = try page(width: 60, height: 40, orientation: .right)
        XCTAssertEqual(sideways.size, CGSize(width: 40, height: 60), "Fixture must present as portrait.")

        let encoded = await ScannedPageEncoder.encode(sideways)
        let data = try XCTUnwrap(encoded)

        XCTAssertEqual(try XCTUnwrap(UIImage(data: data)).size, CGSize(width: 40, height: 60))
    }

    func testEncode_capsTheLongEdge() async throws {
        let encoded = await ScannedPageEncoder.encode(try page(width: 200, height: 400), maxLongEdge: 100)
        let data = try XCTUnwrap(encoded)

        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size, CGSize(width: 50, height: 100))
    }

    func testEncode_leavesPagesWithinTheCapAtFullSize() async throws {
        let encoded = await ScannedPageEncoder.encode(try page(width: 100, height: 50), maxLongEdge: 100)
        let data = try XCTUnwrap(encoded)

        XCTAssertEqual(try XCTUnwrap(UIImage(data: data)).size, CGSize(width: 100, height: 50))
    }
}

// MARK: - DocumentScanFlow

final class DocumentScanFlowTests: XCTestCase {

    func testStep_followsTheCameraPermission() {
        XCTAssertEqual(DocumentScanFlow.step(for: .authorized), .present)
        XCTAssertEqual(DocumentScanFlow.step(for: .notDetermined), .requestAccess)
        XCTAssertEqual(DocumentScanFlow.step(for: .denied), .explainDenied)
        XCTAssertEqual(DocumentScanFlow.step(for: .restricted), .explainDenied)
    }
}
