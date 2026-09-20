import XCTest
@testable import PicStrip

// MARK: - Merging model findings

final class SemanticPIIMergerTests: XCTestCase {

    private let lines = [
        ScannedLine(text: "Email Larry Page: larry@mail.net", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.64, height: 0.05), confidence: 1),
        ScannedLine(text: "Call bob: 6185551234", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.05), confidence: 0.5)
    ]
    private let email = DetectionResult(
        type: .email, score: 0.93,
        instances: [DetectedInstance(snippet: "larry@mail.net", boundingBox: CGRect(x: 0.44, y: 0.2, width: 0.3, height: 0.05), score: 0.93)]
    )

    func testMerge_addsANameBoxedToItsOwnWords() throws {
        let merged = SemanticPIIMerger.merge(
            names: [SemanticPII.Name(line: 0, text: "Larry Page")], lines: lines, into: [email]
        )

        let names = try XCTUnwrap(merged.first { $0.type == .personName })
        let instance = try XCTUnwrap(names.instances.first)
        XCTAssertEqual(instance.snippet, "Larry Page")
        // "Larry Page" is characters 6..<16 of a 32-character line 0.64 wide starting at 0.1.
        XCTAssertEqual(instance.boundingBox.minX, 0.1 + 0.64 * 6 / 32, accuracy: 0.001)
        XCTAssertEqual(instance.boundingBox.width, 0.64 * 10 / 32, accuracy: 0.001)
        XCTAssertEqual(instance.score, SemanticPIIMerger.nameBaseScore, accuracy: 0.001)
        XCTAssertNotNil(merged.first { $0.type == .email }, "Pattern findings must be kept.")
        XCTAssertEqual(merged.first?.type, .email, "Results stay sorted by score.")
    }

    func testMerge_scoresByOCRConfidence_andMatchesCaseInsensitively() throws {
        let merged = SemanticPIIMerger.merge(names: [SemanticPII.Name(line: 1, text: "Bob")], lines: lines, into: [])
        let instance = try XCTUnwrap(merged.first?.instances.first)
        XCTAssertEqual(instance.score, SemanticPIIMerger.nameBaseScore * 0.5, accuracy: 0.001)
    }

    /// The model is not trusted: a name that is not on the line it points at —
    /// or a line that does not exist — must never become a box on the image.
    func testMerge_dropsHallucinatedFindings() {
        let merged = SemanticPIIMerger.merge(
            names: [
                SemanticPII.Name(line: 0, text: "Sergey Brin"),   // not on that line
                SemanticPII.Name(line: 7, text: "Larry Page"),    // no such line
                SemanticPII.Name(line: -1, text: "Larry Page"),
                SemanticPII.Name(line: 0, text: "L"),             // too short
                SemanticPII.Name(line: 1, text: "6185551234")     // not a name: no letters
            ],
            lines: lines, into: [email]
        )
        XCTAssertNil(merged.first { $0.type == .personName })
        XCTAssertEqual(merged.count, 1)
    }

    func testMerge_reportsTheSameNameOnce() {
        let merged = SemanticPIIMerger.merge(
            names: [SemanticPII.Name(line: 0, text: "Larry Page"), SemanticPII.Name(line: 0, text: "larry page")],
            lines: lines, into: []
        )
        XCTAssertEqual(merged.first?.instances.count, 1)
    }
}

// MARK: - Names are listed, not redacted, by default

@MainActor
final class PersonNameDefaultsTests: XCTestCase {

    func testNamesAreDetectedButNotPreselected() async throws {
        let name = DetectionResult(
            type: .personName, score: 0.6,
            instances: [DetectedInstance(snippet: "Larry Page", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05), score: 0.6)]
        )
        let phone = DetectionResult(
            type: .phoneNumber, score: 0.7,
            instances: [DetectedInstance(snippet: "6185551234", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.05), score: 0.7)]
        )
        let viewModel = ScrubberViewModel(scanImage: { _ in [name, phone] })
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { _ in }

        await viewModel.loadData(try XCTUnwrap(image.pngData()))
        for _ in 0..<200 where viewModel.isScanningPII { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(Set(viewModel.detectedPII.map(\.type)), [.personName, .phoneNumber])
        XCTAssertEqual(viewModel.typesToRedact, [.phoneNumber], "Names are offered, not blacked out unasked.")
        let nameRegion = try XCTUnwrap(viewModel.redactionRegions.first { $0.type == .personName })
        XCTAssertFalse(nameRegion.isEnabled)
        XCTAssertTrue(try XCTUnwrap(viewModel.redactionRegions.first { $0.type == .phoneNumber }).isEnabled)
    }

    func testOnlyNamesAreOffByDefault() {
        XCTAssertEqual(PIIType.allCases.filter { !$0.isRedactedByDefault }, [.personName])
        XCTAssertEqual(PIIType.personName.riskLevel, .low)
    }
}

// MARK: - Composition

final class LiveScanCompositionTests: XCTestCase {

    /// The model only ever sees recognised text, and an unavailable model
    /// changes nothing about the pattern scan.
    func testLiveScan_withoutTheModel_equalsThePatternScan() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let data = try Data(contentsOf: url)

        let plain = try await PIIScanner().scanImage(data: data)
        let composed = try await ScrubberViewModel.liveScan(data: data, hints: .none, semantic: .unavailable)

        XCTAssertEqual(composed.map(\.type), plain.map(\.type))
    }

    func testLiveScan_feedsRecognisedLinesToTheModel_andBoxesItsNames() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let data = try Data(contentsOf: url)
        let semantic = SemanticPII(findNames: { lines in
            guard let index = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("bob") }) else { return [] }
            return [SemanticPII.Name(line: index, text: "bob")]
        })

        let results = try await ScrubberViewModel.liveScan(data: data, hints: .none, semantic: semantic)

        let names = try XCTUnwrap(results.first { $0.type == .personName }, "OCR should have read the line with \u{201C}bob\u{201D}.")
        let box = try XCTUnwrap(names.instances.first?.boundingBox)
        XCTAssertTrue(box.width > 0 && box.width < 0.3, "The box should hug the name, not the line: \(box)")
    }
}
