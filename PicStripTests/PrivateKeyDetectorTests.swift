import CoreGraphics
import XCTest
@testable import PicStrip

final class PrivateKeyDetectorTests: XCTestCase {
    private func lines(_ values: [String]) -> [ScannedLine] {
        values.enumerated().map {
            ScannedLine(text: $0.element, boundingBox: CGRect(x: 0.1, y: 0.1 + Double($0.offset) * 0.05, width: 0.7, height: 0.03), confidence: 0.95)
        }
    }

    func testPEMRedactionCoversHeaderEveryPayloadLineAndFooter() throws {
        let source = lines([
            "-----BEGIN RSA PRIVATE KEY-----",
            "MIIEpAIBAAKCAQEAw6ZmQkLCvqD3O9BcCFOHjQA",
            "QWxwaGFCZXRhR2FtbWFEZWx0YUVwc2lsb24=",
            "-----END RSA PRIVATE KEY-----"
        ])
        let block = try XCTUnwrap(PrivateKeyDetector.results(in: source).first?.instances.first)
        for line in source { XCTAssertTrue(block.boundingBox.contains(line.boundingBox)) }
        XCTAssertFalse(block.snippet.contains("MIIEp"))
    }

    func testOCRDamagedDelimitersStillCoverPayload() throws {
        let source = lines(["BEGlN PR1VATE KEY", "MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQ", "END PRIVATE KEY"])
        let block = try XCTUnwrap(PrivateKeyDetector.results(in: source).first?.instances.first)
        XCTAssertTrue(block.boundingBox.contains(source[1].boundingBox))
    }

    func testClippedHeaderStillProtectsPayloadBeforeEndMarker() throws {
        let source = lines(["QWxwaGFCZXRhR2FtbWFEZWx0YUVwc2lsb24=", "-----END PRIVATE KEY-----"])
        let block = try XCTUnwrap(PrivateKeyDetector.results(in: source).first?.instances.first)
        XCTAssertTrue(block.boundingBox.contains(source[0].boundingBox))
    }

    func testPublicKeyAndUnrelatedTextDoNotTriggerPrivateKeyRule() {
        XCTAssertTrue(PrivateKeyDetector.results(in: lines(["BEGIN PUBLIC KEY", "QWxwaGFCZXRhR2FtbWE=", "END PUBLIC KEY"])).isEmpty)
        XCTAssertTrue(PrivateKeyDetector.results(in: lines(["Private keys must be kept safe", "A normal paragraph"])).isEmpty)
    }
}
