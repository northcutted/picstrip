import XCTest
import UIKit
@testable import PicStrip

@MainActor
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

    /// Renders a solid-colour UIImage and returns its PNG data.
    private func solidColorImageData(color: UIColor = .white,
                                     size: CGSize = CGSize(width: 100, height: 100)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!
    }

    // MARK: - Error handling

    /// Passing garbage bytes must throw `PIIScannerError.invalidImageData` rather
    /// than crashing or silently returning an empty result.
    func testInvalidImageDataThrows() async {
        let garbage = Data("this is not an image".utf8)
        do {
            _ = try await PIIScanner().scanImage(data: garbage)
            XCTFail("Expected PIIScannerError.invalidImageData to be thrown.")
        } catch PIIScannerError.invalidImageData {
            // Expected path — pass.
        } catch {
            XCTFail("Unexpected error type thrown: \(error)")
        }
    }

    /// An empty `Data` value must also throw `invalidImageData`.
    func testEmptyDataThrows() async {
        do {
            _ = try await PIIScanner().scanImage(data: Data())
            XCTFail("Expected PIIScannerError.invalidImageData to be thrown.")
        } catch PIIScannerError.invalidImageData {
            // Expected path — pass.
        } catch {
            XCTFail("Unexpected error type thrown: \(error)")
        }
    }

    // MARK: - Blank image (no text)

    /// A plain white image contains no text; the scanner must return an empty array
    /// rather than crashing or emitting false positives.
    func testBlankImageReturnsNoResults() async throws {
        let data = solidColorImageData()
        let results = try await PIIScanner().scanImage(data: data)
        XCTAssertTrue(results.isEmpty,
            "A blank white image should produce zero detection results, got: \(results.map(\.type.description))")
    }

    // MARK: - Coordinate helpers (unit tests — no Vision pipeline required)

    /// `swiftUIBox` must flip the Y axis: Vision's bottom-left origin becomes
    /// SwiftUI's top-left origin.
    ///
    /// Given a Vision box at y=0.1, height=0.2, the flipped y should be:
    ///   1.0 - 0.1 - 0.2 = 0.7
    func testSwiftUIBoxFlipsYAxis() {
        let visionBox = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2)
        let result = PIIScanner.swiftUIBox(from: visionBox)

        XCTAssertEqual(result.origin.x, 0.1, accuracy: 1e-6, "X must be unchanged.")
        XCTAssertEqual(result.origin.y, 0.7, accuracy: 1e-6,
            "Y must be flipped: 1 - 0.1 - 0.2 = 0.7")
        XCTAssertEqual(result.width,  0.5, accuracy: 1e-6, "Width must be unchanged.")
        XCTAssertEqual(result.height, 0.2, accuracy: 1e-6, "Height must be unchanged.")
    }

    /// A Vision box that sits at the very bottom of the image (y=0, height=0.1)
    /// should flip to the very top (y=0.9).
    func testSwiftUIBoxBottomEdge() {
        let visionBox = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.1)
        let result = PIIScanner.swiftUIBox(from: visionBox)
        XCTAssertEqual(result.origin.y, 0.9, accuracy: 1e-6,
            "Bottom Vision rect (y=0) should become top SwiftUI rect (y=0.9).")
    }

    /// A Vision box filling the full image frame must round-trip to a full-frame
    /// SwiftUI box.
    func testSwiftUIBoxFullFrame() {
        let visionBox = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let result = PIIScanner.swiftUIBox(from: visionBox)
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 1, height: 1),
            "A full-frame Vision box must produce a full-frame SwiftUI box.")
    }

    // MARK: - Snippet helpers (unit tests — no Vision pipeline required)

    /// Strings within the limit must be returned verbatim (after trimming).
    func testSnippetShortString() {
        XCTAssertEqual(PIIScanner.snippet("hello"), "hello")
        XCTAssertEqual(PIIScanner.snippet("  trimmed  "), "trimmed")
    }

    /// Strings longer than 60 characters must be truncated with a trailing ellipsis.
    func testSnippetTruncation() {
        let longString = String(repeating: "a", count: 70)
        let result = PIIScanner.snippet(longString)
        XCTAssertEqual(result.count, 60,
            "Truncated snippet must be exactly 60 characters (59 chars + ellipsis).")
        XCTAssertTrue(result.hasSuffix("…"),
            "Truncated snippet must end with '…'.")
    }

    /// The default max is 60; passing a custom max must be respected.
    func testSnippetCustomMax() {
        let input = String(repeating: "x", count: 20)
        let result = PIIScanner.snippet(input, max: 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    /// An NSRange with `NSNotFound` location must return an empty string gracefully.
    func testSnippetFromInvalidRange() {
        let result = PIIScanner.snippet(from: "some text", nsRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(result, "", "An invalid NSRange must produce an empty snippet, not a crash.")
    }

    /// An NSRange that extends beyond the string bounds must return empty gracefully.
    func testSnippetFromOutOfBoundsRange() {
        let result = PIIScanner.snippet(from: "short", nsRange: NSRange(location: 100, length: 5))
        XCTAssertEqual(result, "", "An out-of-bounds NSRange must produce an empty snippet, not a crash.")
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

    // MARK: - Result deduplication

    /// Running the scanner twice on the same image must not return more instances
    /// than a single run — i.e. the internal deduplication logic is stable.
    func testScannerResultsAreStable() async throws {
        let data = try loadTestImageData(named: "test_list", extension: "png")
        let run1 = try await PIIScanner().scanImage(data: data)
        let run2 = try await PIIScanner().scanImage(data: data)

        // Same types detected on both runs.
        let types1 = Set(run1.map(\.type))
        let types2 = Set(run2.map(\.type))
        XCTAssertEqual(types1, types2, "Detected PII types must be deterministic across runs.")

        // Instance counts must not grow between runs (deduplication must fire).
        for type_ in types1 {
            let count1 = run1.first(where: { $0.type == type_ })?.instances.count ?? 0
            let count2 = run2.first(where: { $0.type == type_ })?.instances.count ?? 0
            XCTAssertEqual(count1, count2,
                "Instance count for \(type_.description) must be identical on every run (got \(count1) vs \(count2)).")
        }
    }

    // MARK: - Score ordering

    /// Results must be sorted highest-score first.
    func testResultsAreSortedByScoreDescending() async throws {
        let data = try loadTestImageData(named: "test_list", extension: "png")
        let results = try await PIIScanner().scanImage(data: data)
        guard results.count > 1 else { return }

        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThanOrEqual(
                results[i].score, results[i + 1].score,
                "Result at index \(i) (score \(results[i].score)) must be >= result at index \(i+1) (score \(results[i+1].score))."
            )
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

    // MARK: - Luhn validation

    /// Known Luhn-valid card numbers should validate; corrupting any single digit
    /// must break the checksum.  Filtering by Luhn is intentionally NOT done in the
    /// scanner (OCR may corrupt digits on a real card); this is a pure unit test of
    /// the helper used as a confidence booster.
    func testLuhnValidation() {
        // Visa, Mastercard, Amex, Discover test numbers — all Luhn-valid.
        XCTAssertTrue(PIIScanner.passesLuhn(digits: "4111111111111111"),
                      "Standard Visa test number must Luhn-validate")
        XCTAssertTrue(PIIScanner.passesLuhn(digits: "5500005555555559"),
                      "Mastercard test number must Luhn-validate")
        XCTAssertTrue(PIIScanner.passesLuhn(digits: "378282246310005"),
                      "Amex 15-digit test number must Luhn-validate")
        XCTAssertTrue(PIIScanner.passesLuhn(digits: "6011000000000004"),
                      "Discover test number must Luhn-validate")

        // Same numbers reformatted with separators must still validate.
        XCTAssertTrue(PIIScanner.passesLuhn(digits: "4111-1111-1111-1111"),
                      "Luhn helper must ignore dashes between digits")
        XCTAssertTrue(PIIScanner.passesLuhn(digits: "4111 1111 1111 1111"),
                      "Luhn helper must ignore spaces between digits")

        // Corrupted digit — must not pass.
        XCTAssertFalse(PIIScanner.passesLuhn(digits: "4111111111111112"),
                       "Single-digit corruption must fail the Luhn check")

        // Too short / too long for any real card.
        XCTAssertFalse(PIIScanner.passesLuhn(digits: "4111"),
                       "Strings shorter than 12 digits cannot pass")
        XCTAssertFalse(PIIScanner.passesLuhn(digits: "41111111111111111111"),
                       "Strings longer than 19 digits cannot pass")
    }

    // MARK: - Document-region boost

    /// Detections whose centre falls inside a detected document rectangle must
    /// have their score boosted.  Detections outside any document rectangle must
    /// retain their original score.
    func testApplyDocumentBoost_boostsOnlyInsideDetections() {
        let insideInstance = DetectedInstance(
            snippet: "AB1234567890123",
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.05),
            score: 0.80
        )
        let outsideInstance = DetectedInstance(
            snippet: "ZZ9999999999999",
            boundingBox: CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.05),
            score: 0.80
        )
        let input = [
            DetectionResult(
                type: .governmentID,
                score: 0.80,
                instances: [insideInstance, outsideInstance]
            )
        ]
        // A document rectangle covering roughly the middle 60 % of the image —
        // contains insideInstance, excludes outsideInstance.
        let docRect = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

        let boosted = PIIScanner.applyDocumentBoost(results: input, documentRects: [docRect])
        let resultInstances = boosted.first?.instances ?? []
        XCTAssertEqual(resultInstances.count, 2)

        let inside = resultInstances.first { $0.snippet == "AB1234567890123" }
        let outside = resultInstances.first { $0.snippet == "ZZ9999999999999" }
        XCTAssertNotNil(inside)
        XCTAssertNotNil(outside)
        XCTAssertGreaterThan(inside?.score ?? 0, 0.80,
                             "Detection whose centre lies inside the document rect must have its score boosted")
        XCTAssertLessThanOrEqual(inside?.score ?? 0, 0.99,
                                 "Boosted score is clamped at 0.99")
        XCTAssertEqual(outside?.score, 0.80,
                       "Detection outside any document rect must retain its original score")
    }

    /// Document boost only applies to ID-like types — a phone number that
    /// happens to sit on a document should not be boosted (it would skew
    /// risk ordering by promoting medium-risk detections above critical ones).
    func testApplyDocumentBoost_skipsNonBoostableTypes() {
        let phoneInstance = DetectedInstance(
            snippet: "555-867-5309",
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.05),
            score: 0.72
        )
        let input = [
            DetectionResult(
                type: .phoneNumber,
                score: 0.72,
                instances: [phoneInstance]
            )
        ]
        let docRect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)

        let boosted = PIIScanner.applyDocumentBoost(results: input, documentRects: [docRect])
        XCTAssertEqual(boosted.first?.instances.first?.score, 0.72,
                       "Non-boostable types (.phoneNumber) must keep their original score even when inside a document rect")
    }

    /// When no document rectangles are detected the boost helper must return
    /// the input unchanged.
    func testApplyDocumentBoost_noopWithNoDocumentRects() {
        let instance = DetectedInstance(
            snippet: "AB1234567890123",
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.05),
            score: 0.80
        )
        let input = [
            DetectionResult(type: .governmentID, score: 0.80, instances: [instance])
        ]
        let boosted = PIIScanner.applyDocumentBoost(results: input, documentRects: [])
        XCTAssertEqual(boosted.first?.instances.first?.score, 0.80,
                       "Empty document-rects list must leave scores untouched")
    }

    // MARK: - Document context

    func testApplyDocumentContextAddsWholeCreditCardAndDampensIncompatibleIDs() {
        let cardRect = CGRect(x: 0.1, y: 0.25, width: 0.8, height: 0.5)
        let cardNumber = DetectedInstance(
            snippet: "4111 1111 1111 1111",
            boundingBox: CGRect(x: 0.22, y: 0.48, width: 0.45, height: 0.06),
            score: 0.88
        )
        let ambiguousID = DetectedInstance(
            snippet: "123456789",
            boundingBox: CGRect(x: 0.2, y: 0.35, width: 0.22, height: 0.05),
            score: 0.82
        )
        let results = [
            DetectionResult(type: .creditCard, score: 0.88, instances: [cardNumber]),
            DetectionResult(type: .governmentID, score: 0.82, instances: [ambiguousID])
        ]
        let lines = [
            PIIScanner.RecognizedLineContext(
                text: "VISA",
                boundingBox: CGRect(x: 0.18, y: 0.30, width: 0.12, height: 0.05),
                confidence: 0.96
            ),
            PIIScanner.RecognizedLineContext(
                text: "VALID THRU 12/29",
                boundingBox: CGRect(x: 0.22, y: 0.62, width: 0.24, height: 0.05),
                confidence: 0.94
            )
        ]

        let contextual = PIIScanner.applyDocumentContext(
            results: results,
            documentRects: [cardRect],
            faceRects: [],
            barcodeContexts: [],
            textLines: lines
        )

        let creditCard = contextual.first { $0.type == .creditCard }
        XCTAssertTrue(
            creditCard?.instances.contains(where: { $0.subtype == .creditCardDocument && $0.boundingBox == cardRect }) ?? false,
            "A strong credit-card context should add a whole-card redaction region")
        XCTAssertGreaterThan(
            creditCard?.instances.first(where: { $0.snippet == cardNumber.snippet })?.score ?? 0,
            cardNumber.score,
            "Card-number evidence inside a credit-card context should be boosted")

        let dampenedID = contextual
            .first { $0.type == .governmentID }?
            .instances
            .first { $0.snippet == ambiguousID.snippet }
        XCTAssertLessThan(dampenedID?.score ?? 1, ambiguousID.score,
                          "Known credit-card context should dampen incompatible ID-like false positives inside the card")
    }

    func testInferDocumentContextsDetectsDriversLicenseFromFacePDF417AndLabels() {
        let cardRect = CGRect(x: 0.08, y: 0.22, width: 0.84, height: 0.52)
        let results = [
            DetectionResult(
                type: .dateOfBirth,
                score: 0.78,
                instances: [
                    DetectedInstance(
                        snippet: "01/02/1980",
                        boundingBox: CGRect(x: 0.45, y: 0.45, width: 0.18, height: 0.05),
                        score: 0.78
                    )
                ]
            )
        ]
        let lines = [
            PIIScanner.RecognizedLineContext(
                text: "DRIVER LICENSE",
                boundingBox: CGRect(x: 0.36, y: 0.27, width: 0.28, height: 0.05),
                confidence: 0.95
            ),
            PIIScanner.RecognizedLineContext(
                text: "DOB 01/02/1980",
                boundingBox: CGRect(x: 0.42, y: 0.45, width: 0.24, height: 0.05),
                confidence: 0.93
            )
        ]
        let barcode = PIIScanner.BarcodeContext(
            boundingBox: CGRect(x: 0.18, y: 0.62, width: 0.58, height: 0.08),
            symbology: "PDF417",
            payload: nil
        )

        let contexts = PIIScanner.inferDocumentContexts(
            results: results,
            documentRects: [cardRect],
            faceRects: [CGRect(x: 0.16, y: 0.34, width: 0.18, height: 0.22)],
            barcodeContexts: [barcode],
            textLines: lines
        )

        XCTAssertEqual(contexts.first?.kind, .driversLicense)
        XCTAssertEqual(contexts.first?.boundingBox, cardRect)
    }
}
