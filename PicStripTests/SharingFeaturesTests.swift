import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PicStrip

// MARK: - Helpers

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Timed out waiting for the view model.")
}

/// A small PNG, optionally carrying an EXIF user comment the way iOS marks screenshots.
private func makePNG(userComment: String? = nil) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    let cgImage = try XCTUnwrap(image.cgImage)
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [:]
    if let userComment {
        properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: userComment]
    }
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func fixture(_ name: String, _ ext: String) throws -> Data {
    let url = try XCTUnwrap(Bundle(for: PartialCoverTests.self).url(forResource: name, withExtension: ext))
    return try Data(contentsOf: url)
}

// MARK: - Partial covering

@MainActor
final class PartialCoverTests: XCTestCase {

    private func covered(_ type: PIIType, in text: String, match: String) -> String? {
        let range = (text as NSString).range(of: match)
        return PIIScanner.partialCoverRange(for: type, in: text, range: range).map { (text as NSString).substring(with: $0) }
    }

    func testANumberKeepsItsLastFourDigits() {
        XCTAssertEqual(covered(.creditCard, in: "Card 4111 1111 1111 1111 exp", match: "4111 1111 1111 1111"), "4111 1111 1111")
        XCTAssertEqual(covered(.phoneNumber, in: "Call (415) 555-0147", match: "(415) 555-0147"), "(415) 555")
        XCTAssertEqual(covered(.socialSecurityNumber, in: "SSN 123-45-6789", match: "123-45-6789"), "123-45")
        XCTAssertEqual(covered(.phoneNumber, in: "Call bob: 6185551234", match: "6185551234"), "618555")
    }

    func testAnEmailKeepsItsDomain() {
        XCTAssertEqual(covered(.email, in: "Mail alex.thornton@northwood.com now", match: "alex.thornton@northwood.com"), "alex.thornton")
        XCTAssertNil(covered(.email, in: "@northwood.com", match: "@northwood.com"))
    }

    func testTooShortOrTheWrongKindCannotBeShortened() {
        XCTAssertNil(covered(.phoneNumber, in: "1234", match: "1234"), "Nothing would be left to cover.")
        XCTAssertNil(covered(.link, in: "https://example.com/abcd", match: "https://example.com/abcd"))
        XCTAssertNil(covered(.face, in: "anything", match: "anything"))
    }

    /// The real scanner gives the email and phone number in the fixture a
    /// shorter box that starts where the full one does.
    func testTheScannerFindsTheShorterBox() async throws {
        let results = try await PIIScanner().scanImage(data: try fixture("test_pii", "png"))
        for type in [PIIType.email, .phoneNumber] {
            let instance = try XCTUnwrap(results.first { $0.type == type }?.instances.first, "\(type) should be found.")
            let partial = try XCTUnwrap(instance.partialBoundingBox, "\(type) should have a partial box.")
            XCTAssertLessThan(partial.width, instance.boundingBox.width * 0.95, "\(type): the partial box is shorter.")
            XCTAssertEqual(partial.minX, instance.boundingBox.minX, accuracy: 0.02, "\(type): it starts where the whole one does.")
        }
    }

    /// Where Vision only knows the whole word, the split leans toward covering.
    func testTheEstimatedSplitLeansTowardCovering() throws {
        let box = CGRect(x: 0.2, y: 0.4, width: 0.3, height: 0.05)
        let partial = try XCTUnwrap(PIIScanner.estimatedPartialBox(matchBox: box, coveredCharacters: 6, totalCharacters: 10))
        XCTAssertEqual(partial.minX, 0.2)
        XCTAssertGreaterThan(partial.width, 0.3 * 0.6, "A little more than the six covered characters.")
        XCTAssertLessThan(partial.width, 0.3 * 0.7, "Less than seven.")
        XCTAssertNil(PIIScanner.estimatedPartialBox(matchBox: box, coveredCharacters: 0, totalCharacters: 10))
        XCTAssertNil(PIIScanner.estimatedPartialBox(matchBox: box, coveredCharacters: 10, totalCharacters: 10))
    }

    func testARegionSwitchesBetweenWholeAndPartialAndUndoes() throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        let full = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.05)
        let partial = CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.05)
        model.typesToRedact = [.creditCard]
        model.detectedPII = [DetectionResult(type: .creditCard, score: 0.9, instances: [
            DetectedInstance(snippet: "4111 1111 1111 1111", boundingBox: full, partialBoundingBox: partial, score: 0.9)
        ])]
        let id = try XCTUnwrap(model.redactionRegions.first?.id)
        XCTAssertNotNil(model.redactionRegions.first?.partialCoverLabel)

        model.setPartialCover(id: id, true)
        XCTAssertEqual(model.redactionRegions.first?.rect, partial)
        XCTAssertEqual(model.redactionRegions.first?.isPartial, true)

        model.setPartialCover(id: id, false)
        XCTAssertEqual(model.redactionRegions.first?.rect, full)

        model.undoRedaction()
        XCTAssertEqual(model.redactionRegions.first?.rect, partial)
    }

    func testRescoringKeepsThePartialBox() {
        let instance = DetectedInstance(snippet: "x", boundingBox: .zero, partialBoundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), score: 0.5)
        XCTAssertEqual(instance.withScore(0.9).partialBoundingBox, instance.partialBoundingBox)
        XCTAssertEqual(instance.withScore(0.9).score, 0.9)
    }
}

// MARK: - Sharing purposes

@MainActor
final class SharingPurposeTests: XCTestCase {

    func testAScreenshotIsRecognisedByItsUserComment() throws {
        let screenshot = try XCTUnwrap(SourceProperties(imageData: try makePNG(userComment: "Screenshot")))
        XCTAssertEqual(SharingPurpose.detect(properties: screenshot.dictionary, hints: .none), .screenshot)
        let plain = try XCTUnwrap(SourceProperties(imageData: try makePNG()))
        XCTAssertEqual(SharingPurpose.detect(properties: plain.dictionary, hints: .none), .photo)
        XCTAssertEqual(SharingPurpose.detect(properties: nil, hints: .scannedDocument), .document)
    }

    func testOnlyDocumentsCoverNamesStraightAway() {
        XCTAssertTrue(SharingPurpose.document.coversByDefault(.personName))
        XCTAssertFalse(SharingPurpose.photo.coversByDefault(.personName))
        XCTAssertFalse(SharingPurpose.screenshot.coversByDefault(.personName))
        for purpose in SharingPurpose.allCases {
            XCTAssertTrue(purpose.coversByDefault(.email))
            XCTAssertTrue(purpose.coversByDefault(.alwaysCover))
        }
    }

    /// Loading a screenshot picks the Screenshot purpose and its lossless format by itself.
    func testLoadingAScreenshotChoosesTheScreenshotPurpose() async throws {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        await model.loadData(try makePNG(userComment: "Screenshot"))
        try await waitUntil { model.sharingPurpose == .screenshot }
        XCTAssertEqual(model.selectedExportFormat, .png)

        await model.loadData(try makePNG())
        try await waitUntil { model.sharingPurpose == .photo }
        XCTAssertEqual(model.selectedExportFormat, .jpeg)
    }

    func testChoosingAPurposeUpdatesTheSelection() {
        let model = ScrubberViewModel(scanImage: { _ in [] })
        model.detectedPII = [DetectionResult(type: .personName, score: 0.8, instances: []),
                             DetectionResult(type: .email, score: 0.9, instances: [])]
        model.applySharingPurpose(.document)
        XCTAssertEqual(model.sharingPurpose, .document)
        XCTAssertEqual(model.typesToRedact, [.personName, .email])
        model.applySharingPurpose(.screenshot)
        XCTAssertEqual(model.typesToRedact, [.email])
        XCTAssertEqual(model.selectedExportFormat, .png)
    }
}

// MARK: - Always Cover

@MainActor
final class AlwaysCoverTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("AlwaysCover-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testTermsAreKeptOnceAndRemembered() throws {
        let list = AlwaysCoverList(fileURL: fileURL)
        XCTAssertTrue(list.add("  Alex Thornton "))
        XCTAssertFalse(list.add("alex thornton"), "The same term, ignoring case, is not added twice.")
        XCTAssertFalse(list.add("A"), "One character would cover half the photo.")
        XCTAssertFalse(list.add("--"), "A term needs a letter or a digit.")
        XCTAssertEqual(list.terms, ["Alex Thornton"])

        XCTAssertEqual(AlwaysCoverList(fileURL: fileURL).terms, ["Alex Thornton"], "The list survives a relaunch.")
        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "The list stays out of backups.")

        list.remove(atOffsets: [0])
        XCTAssertEqual(AlwaysCoverList(fileURL: fileURL).terms, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "An empty list leaves no file behind.")
    }

    func testOnlyWholeWordsMatch() {
        let line = ScannedLine(text: "Also Al and al, but not Albert", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.1), confidence: 1)
        XCTAssertEqual(line.boundingBoxes(ofWord: "Al").count, 2)
        XCTAssertEqual(line.boundingBoxes(ofWord: "Albert").count, 1)
        XCTAssertTrue(line.boundingBoxes(ofWord: "bert").isEmpty)
    }

    func testTheMatcherFindsTermsInARealScan() async throws {
        let output = try await PIIScanner().scan(data: try fixture("test_pii", "png"))
        let results = AlwaysCoverMatcher.results(terms: ["Larry", "Chicago"], lines: output.lines)
        let instances = try XCTUnwrap(results.first { $0.type == .alwaysCover }?.instances)
        XCTAssertGreaterThanOrEqual(instances.count, 2)
        XCTAssertTrue(instances.allSatisfy { $0.score == AlwaysCoverMatcher.score })
    }

    /// A term added while a photo is open is covered in it straight away, and a
    /// term already on the list is covered as soon as the scan finishes.
    func testTermsAreCoveredInTheOpenPhoto() async throws {
        let list = AlwaysCoverList(fileURL: nil)
        list.add("Chicago")
        let lines = [
            ScannedLine(text: "Post office in Chicago", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.05), confidence: 1),
            ScannedLine(text: "Plate 7ABC123", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.05), confidence: 1)
        ]
        let model = ScrubberViewModel(
            scan: { _, _, _ in ScanOutput(results: [], lines: lines) },
            semantic: .unavailable, objectSelection: .unsupported, alwaysCoverList: list
        )
        await model.loadData(try makePNG())
        try await waitUntil { !model.isScanningPII && !model.detectedPII.isEmpty }
        XCTAssertEqual(model.detectedPII.first?.type, .alwaysCover)
        XCTAssertEqual(model.enabledRedactionRegions.count, 1)

        model.alwaysCover("7ABC123")
        XCTAssertEqual(list.terms, ["Chicago", "7ABC123"])
        XCTAssertEqual(model.detectedPII.first { $0.type == .alwaysCover }?.instances.count, 2)
        XCTAssertEqual(model.enabledRedactionRegions.count, 2)
        XCTAssertEqual(Set(model.redactionRegions.map(\.id)).count, model.redactionRegions.count, "Region ids stay unique.")
    }

    func testTheLiveCameraCoversTermsToo() async throws {
        let image = try XCTUnwrap(UIImage(data: try fixture("test_pii", "png"))?.cgImage)
        nonisolated(unsafe) let frame = try XCTUnwrap(LiveCameraFixture.pixelBuffer(from: image))
        let scan = await PIIScanner.liveScan(in: frame, alwaysCover: ["Chicago"])
        XCTAssertTrue(scan.detections.contains { $0.type == .alwaysCover })
    }
}
