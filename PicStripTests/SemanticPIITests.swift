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

// MARK: - Names arrive after the scan, and add to it

@MainActor
final class LateNameDetectionTests: XCTestCase {

    private let lines = [
        ScannedLine(text: "Call bob: 6185551234", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.05), confidence: 1)
    ]
    private let phone = DetectionResult(
        type: .phoneNumber, score: 0.7,
        instances: [DetectedInstance(snippet: "6185551234", boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.05), score: 0.7)]
    )

    private func imageData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { _ in }
        return try XCTUnwrap(image.pngData())
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for the view model.")
    }

    /// The scan is published — and editable, and saveable — before the language
    /// model has answered; its names are then added without rebuilding anything.
    func testNamesAreAddedLater_withoutDisturbingTheUsersEdits() async throws {
        let gate = NameGate()
        let phone = phone, lines = lines
        let viewModel = ScrubberViewModel(
            scan: { _, _ in ScanOutput(results: [phone], lines: lines) },
            semantic: SemanticPII(findNames: { _ in
                await gate.wait()
                return [SemanticPII.Name(line: 0, text: "bob")]
            }),
            objectSelection: .unsupported
        )

        await viewModel.loadData(try imageData())
        try await waitUntil { !viewModel.isScanningPII }
        XCTAssertEqual(viewModel.detectedPII.map(\.type), [.phoneNumber], "The scan must not wait for the model.")

        // The user edits while the model is still thinking.
        let phoneID = try XCTUnwrap(viewModel.redactionRegions.first?.id)
        viewModel.changeRedactionStyle(id: phoneID, style: .blur)
        viewModel.addCustomRedaction(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))

        await gate.open()
        try await waitUntil { viewModel.detectedPII.contains { $0.type == .personName } }

        XCTAssertEqual(viewModel.redactionRegions.map(\.type), [.phoneNumber, .personName, nil],
                       "Names join the detected regions, ahead of the custom ones.")
        XCTAssertEqual(viewModel.redactionRegions.first?.style, .blur, "The user's restyle must survive.")
        let name = try XCTUnwrap(viewModel.redactionRegions.first { $0.type == .personName })
        XCTAssertFalse(name.isEnabled, "Names are offered, not redacted unasked.")
        XCTAssertEqual(viewModel.typesToRedact, [.phoneNumber])

        // Undoing the user's own edits must not make the name region vanish.
        viewModel.undoRedaction()
        viewModel.undoRedaction()
        XCTAssertNotNil(viewModel.redactionRegions.first { $0.type == .personName })
    }

    func testNamesForAReplacedPhotoAreDropped() async throws {
        let gate = NameGate()
        let phone = phone, lines = lines
        let viewModel = ScrubberViewModel(
            scan: { _, _ in ScanOutput(results: [phone], lines: lines) },
            semantic: SemanticPII(findNames: { _ in
                await gate.wait()
                return [SemanticPII.Name(line: 0, text: "bob")]
            }),
            objectSelection: .unsupported
        )
        await viewModel.loadData(try imageData())
        try await waitUntil { !viewModel.isScanningPII }

        viewModel.clearState()
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(viewModel.detectedPII.isEmpty)
        XCTAssertTrue(viewModel.redactionRegions.isEmpty)
    }
}

/// Holds the fake model's answer back until the test lets it through.
private actor NameGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

// MARK: - Recognised lines

final class ScanOutputTests: XCTestCase {

    /// The name pass works from the lines the scan returns, so they must carry
    /// the text, and a box that hugs a substring rather than the whole line.
    func testScanReturnsRecognisedLinesWithSubstringGeometry() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test_pii", withExtension: "png"))
        let output = try await PIIScanner().scan(data: try Data(contentsOf: url))

        let line = try XCTUnwrap(output.lines.first { $0.text.localizedCaseInsensitiveContains("bob") })
        let box = try XCTUnwrap(line.boundingBox(of: "bob"))
        XCTAssertTrue(box.width > 0 && box.width < line.boundingBox.width, "\(box) should be narrower than its line.")
        XCTAssertFalse(output.results.contains { $0.type == .personName }, "The pattern scan never produces names itself.")
    }
}
