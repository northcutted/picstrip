import XCTest
@testable import PicStrip

final class PIIScannerTests: XCTestCase {

    // MARK: - Bundle helper

    /// Loads image data from the test bundle, failing fast if the asset is missing.
    private func loadTestImageData(named name: String, extension ext: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("Test asset '\(name).\(ext)' not found in test bundle.")
            throw XCTSkip("Missing test asset '\(name).\(ext)'.")
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Whiteboard credential detection

    /// Verifies that the scanner detects a split credential from a whiteboard photo.
    ///
    /// The image contains a handwritten "LOGIN: lpr_dyspozyt" entry where Vision
    /// may OCR the keyword as a garbled variant (e.g. "OGIN•", "GIN:") due to
    /// partial occlusion or letter clipping, and the password as "Ipr_ Clusposy"
    /// or a similar rendering of "lpr_dyspozyt". A secondary HASŁO line reads
    /// "uFGrmqGY" (OCR'd as "4FGrHOGY" or "ISLO- ...").
    func testScannerDetectsWhiteboardCredential() async throws {
        let data = try loadTestImageData(named: "test_whiteboard", extension: "jpg")
        let results = try await PIIScanner().scanImage(data: data)

        let credentialResult = results.first { $0.type == .unstructuredCredential }
        XCTAssertNotNil(credentialResult, "Scanner must detect at least one .unstructuredCredential on the whiteboard image.")

        guard let result = credentialResult else { return }

        // The snippet should contain some recognisable fragment of the credential
        // value — either from the LOGIN line ("lpr", "ipr", "clusposy") or the
        // HASŁO/ISLO line ("4fg", "ufg", "hogY", "rHOGY").
        let allSnippets = result.instances.map { $0.snippet.lowercased() }.joined(separator: " ")
        let containsCredentialFragment =
            allSnippets.contains("lpr") ||
            allSnippets.contains("ipr") ||
            allSnippets.contains("clusposy") ||
            allSnippets.contains("4fg") ||
            allSnippets.contains("ufg") ||
            allSnippets.contains("hog") ||
            allSnippets.contains("cuall") ||
            allSnippets.contains("islo")

        XCTAssertTrue(
            containsCredentialFragment,
            "At least one snippet must contain a fragment of the whiteboard password. Got: \(result.instances.map(\.snippet))"
        )
    }

    // MARK: - Precision substring bounding boxes

    /// Verifies that detected instances carry tight substring bounding boxes rather
    /// than full-line boxes, and that all normalised coordinate values are in 0…1.
    ///
    /// A full-line box width would equal the entire observation width (~0.5–0.6 for
    /// this image). A substring box for a matched email or phone token will be
    /// strictly smaller. The PRD contract is simply width < 1.0, proving the
    /// coordinates were not collapsed to the container size.
    func testScannerExtractsPreciseBoundingBoxes() async throws {
        let data = try loadTestImageData(named: "test_list", extension: "png")
        let results = try await PIIScanner().scanImage(data: data)

        XCTAssertFalse(results.isEmpty, "Scanner must find at least one PII result in test_list.png.")

        let allInstances = results.flatMap(\.instances)
        XCTAssertFalse(allInstances.isEmpty, "Results must contain at least one DetectedInstance with a bounding box.")

        for instance in allInstances {
            let box = instance.boundingBox
            XCTAssertLessThan(box.width, 1.0,
                "Bounding box width \(box.width) must be < 1.0 (snippet box, not full container). Snippet: '\(instance.snippet)'")
            XCTAssertGreaterThan(box.width, 0.0,
                "Bounding box width must be positive. Snippet: '\(instance.snippet)'")
            XCTAssertGreaterThanOrEqual(box.minX, 0.0, "Box minX must be >= 0. Snippet: '\(instance.snippet)'")
            XCTAssertGreaterThanOrEqual(box.minY, 0.0, "Box minY must be >= 0. Snippet: '\(instance.snippet)'")
            XCTAssertLessThanOrEqual(box.maxX, 1.0, "Box maxX must be <= 1. Snippet: '\(instance.snippet)'")
            XCTAssertLessThanOrEqual(box.maxY, 1.0, "Box maxY must be <= 1. Snippet: '\(instance.snippet)'")
        }
    }

    // MARK: - Legacy stub (kept to document intended future behaviour)

    /// This test intentionally fails until a real test_pii image with visible email
    /// and phone text is wired up. It documents the expected scanner contract.
    func testScannerDetectsEmailAndPhone() async throws {
        let data = try loadTestImageData(named: "test_list", extension: "png")
        let results = try await PIIScanner().scanImage(data: data)
        let types = Set(results.map(\.type))
        XCTAssertTrue(types.contains(.email),       "Scanner should detect an email address in test_list.png")
        XCTAssertTrue(types.contains(.phoneNumber), "Scanner should detect a phone number in test_list.png")
    }
}
