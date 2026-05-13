import Foundation
import ImageIO
import Vision

// MARK: - Errors

enum PIIScannerError: Error, LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return String(localized: "Could not decode the provided data into a valid image.")
        }
    }
}

// MARK: - Scanner

struct PIIScanner {

    func scanImage(data: Data) async throws -> [DetectionResult] {
        // Offload CPU-bound work off the calling thread.
        return try await Task.detached(priority: .userInitiated) {
            // Stage 1: Validate — ensures a meaningful error if the caller passes
            // non-image bytes before we hand anything to Vision.
            // CGImageSourceCreateWithData succeeds even for arbitrary byte sequences
            // (it creates a source with zero images), so we additionally verify that
            // at least one image frame is decodable. The decoded CGImage is discarded
            // immediately; the actual OCR uses VNImageRequestHandler(data:) below.
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
            else {
                throw PIIScannerError.invalidImageData
            }

            // Stage 2: Single-pass Vision — submit OCR, face, barcode, and
            // document-rectangle requests against ONE VNImageRequestHandler so
            // the source bytes are decoded and pre-processed exactly once.
            // Raw Data (not a pre-decoded CGImage) is passed so that
            // VNImageRequestHandler can read the EXIF orientation tag and return
            // bounding boxes in the visual coordinate space — the same space that
            // UIKit's display pipeline uses.
            let accurateTextRequest = Self.makeTextRequest(level: .accurate)
            let faceRequest         = VNDetectFaceRectanglesRequest()
            let barcodeRequest      = VNDetectBarcodesRequest()
            let rectangleRequest    = Self.makeDocumentRectangleRequest()

            let handler = VNImageRequestHandler(data: data, options: [:])
            // `try?` because a single sub-request (e.g. rectangle detection on
            // the simulator with no Neural Engine) failing shouldn't kill OCR.
            // Vision still populates each successful request's .results despite
            // a thrown perform, so partial outcomes are preserved.  The OCR
            // fast-fallback below covers the case where the accurate text
            // recogniser was the one that failed.
            try? handler.perform([accurateTextRequest, faceRequest, barcodeRequest, rectangleRequest])

            // Fast-text fallback — if accurate returned nothing (simulator CPU
            // path, heavily compressed image) retry text-only with the fast
            // model.  Face / barcode / rectangle results from the primary pass
            // are preserved, so this only re-pays the text inference cost.
            var observations = accurateTextRequest.results ?? []
            if observations.isEmpty {
                let fastRequest = Self.makeTextRequest(level: .fast)
                let fallbackHandler = VNImageRequestHandler(data: data, options: [:])
                try? fallbackHandler.perform([fastRequest])
                observations = fastRequest.results ?? []
            }

            let primaryLineContexts = Self.recognizedLineContexts(from: observations)
            let faceRects = (faceRequest.results ?? []).map { obs in
                Self.swiftUIBox(from: obs.boundingBox)
            }
            let barcodeContexts = Self.barcodeContexts(from: barcodeRequest.results ?? [])
            let documentRects: [CGRect] = (rectangleRequest.results ?? []).map { obs in
                Self.swiftUIBox(from: obs.boundingBox)
            }

            // Stage 3: Per-observation two-stage PII analysis with state tracking.
            var results = try Self.detectPII(in: observations)

            // Stage 4: Append visual detections (faces, barcodes).
            results.append(contentsOf: Self.faceResults(from: faceRects))
            results.append(contentsOf: Self.barcodeResults(from: barcodeContexts))

            // Stage 5: Document-region prioritisation — first apply the broad
            // rectangle prior, then classify likely cards/IDs/passports from the
            // combined OCR + face + barcode evidence Vision already produced.
            results = Self.applyDocumentBoost(results: results, documentRects: documentRects)
            results = Self.applyDocumentContext(
                results: results,
                documentRects: documentRects,
                faceRects: faceRects,
                barcodeContexts: barcodeContexts,
                textLines: primaryLineContexts
            )
            results = Self.resolveCreditCardPhoneConflicts(results)

            // Re-sort combined results: highest score first, alphabetical tiebreak.
            return results.sorted {
                $0.score != $1.score
                    ? $0.score > $1.score
                    : $0.type.description < $1.type.description
            }
        }.value
    }

    // MARK: - Private

    /// Builds a `VNRecognizeTextRequest` configured for credential-safe OCR.
    nonisolated private static func makeTextRequest(level: VNRequestTextRecognitionLevel) -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        // Disable language correction so Vision preserves raw credential
        // characters rather than autocorrecting them into dictionary words.
        req.usesLanguageCorrection = false
        // Let Vision pick the best model for whatever language(s) appear in
        // the image — important for passwords and non-English labels.
        req.automaticallyDetectsLanguage = true
        // Bias the on-device OCR model toward terse credential/document labels
        // that are common on cards and IDs but easy to misread as ordinary words.
        req.customWords = [
            "DOB", "D.O.B.", "EXP", "CVV", "CVC", "VALID THRU",
            "DRIVER LICENSE", "DRIVERS LICENSE", "DRIVING LICENCE",
            "DL", "LIC", "ID", "PASSPORT", "NATIONALITY",
            "VISA", "MASTERCARD", "AMEX", "DISCOVER", "DEBIT", "CREDIT",
            "PDF417", "MRZ"
        ]
        return req
    }

    /// Builds a `VNDetectRectanglesRequest` tuned for document/ID-card detection.
    /// Aspect ratio band covers everything from portrait phone screenshots through
    /// landscape credit cards / passports.  Minimum size of 15 % filters out small
    /// incidental rectangles (icons, buttons).
    nonisolated private static func makeDocumentRectangleRequest() -> VNDetectRectanglesRequest {
        let req = VNDetectRectanglesRequest()
        req.minimumAspectRatio  = 0.5
        req.maximumAspectRatio  = 2.0
        req.minimumSize         = 0.15
        req.minimumConfidence   = 0.6
        req.maximumObservations = 5
        return req
    }

    /// Analyses each OCR observation individually, preserving bounding-box
    /// associations and tracking heuristic credential state across observations.
    nonisolated private static let nativeDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue |
            NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
            NSTextCheckingResult.CheckingType.address.rawValue
    )

    nonisolated private struct OCRLine {
        let observation: VNRecognizedTextObservation
        let candidate: VNRecognizedText
        let rank: Int
        let text: String
        let confidence: Float
        let visionBox: CGRect
        let lineBounds: CGRect
    }

    nonisolated struct RecognizedLineContext: Hashable {
        let text: String
        let boundingBox: CGRect
        let confidence: Float
    }

    nonisolated struct BarcodeContext: Hashable {
        let boundingBox: CGRect
        let symbology: String
        let payload: String?

        var isPDF417: Bool {
            symbology.localizedCaseInsensitiveContains("pdf417")
        }
    }

    nonisolated enum DocumentContextKind: Hashable {
        case creditCard
        case driversLicense
        case identityDocument
        case passport

        var type: PIIType {
            switch self {
            case .creditCard:       return .creditCard
            case .driversLicense,
                 .identityDocument,
                 .passport:         return .governmentID
            }
        }

        var subtype: PIISubtype {
            switch self {
            case .creditCard:       return .creditCardDocument
            case .driversLicense:   return .driversLicenseDocument
            case .identityDocument: return .identityDocument
            case .passport:         return .passportDocument
            }
        }

        var snippet: String {
            switch self {
            case .creditCard:       return String(localized: "Credit card detected")
            case .driversLicense:   return String(localized: "Driver license detected")
            case .identityDocument: return String(localized: "Identity document detected")
            case .passport:         return String(localized: "Passport detected")
            }
        }

        var boostableTypes: Set<PIIType> {
            switch self {
            case .creditCard:
                return [.creditCard, .dateOfBirth]
            case .driversLicense:
                return [.governmentID, .dateOfBirth, .address, .face, .barcode]
            case .identityDocument:
                return [.governmentID, .socialSecurityNumber, .nationalInsuranceNumber, .dateOfBirth, .address, .face, .barcode]
            case .passport:
                return [.governmentID, .dateOfBirth, .face]
            }
        }

        var dampenedTypes: Set<PIIType> {
            switch self {
            case .creditCard:
                return [.governmentID, .socialSecurityNumber, .nationalInsuranceNumber, .iban, .abaRoutingNumber, .swiftBIC, .vehicleIdentificationNumber, .licensePlate]
            case .driversLicense,
                 .identityDocument,
                 .passport:
                return [.creditCard, .iban, .abaRoutingNumber, .swiftBIC, .cryptoWallet]
            }
        }
    }

    nonisolated struct DocumentContext: Hashable {
        let kind: DocumentContextKind
        let boundingBox: CGRect
        let score: Double
    }

    nonisolated private struct SpatialLabelRule {
        let type: PIIType
        let subtype: PIISubtype?
        let labelRegex: NSRegularExpression
        let valueRegex: NSRegularExpression
        let baseScore: Double
    }

    nonisolated private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            fatalError("Invalid scanner regex: \(error)")
        }
    }

    /// Label/value rules for cases where OCR splits "DOB:" and the value into
    /// separate observations. These mirror the high-precision keyword-anchored
    /// registry rules, but search nearby lines instead of requiring one line.
    nonisolated private static let spatialLabelRules: [SpatialLabelRule] = [
        SpatialLabelRule(
            type: .dateOfBirth,
            subtype: nil,
            labelRegex: regex(#"(?i)\b(?:DOB|D\.?O\.?B\.?|date\s+of\s+birth|birth\s*date|birthday|born(?:\s+on)?)\b"#),
            valueRegex: regex(#"\b(?:(?:0?[1-9]|1[0-2])[\/\-](?:0?[1-9]|[12]\d|3[01])[\/\-](?:19|20)\d{2}|(?:19|20)\d{2}[\/\-](?:0?[1-9]|1[0-2])[\/\-](?:0?[1-9]|[12]\d|3[01]))\b"#),
            baseScore: 0.78
        ),
        SpatialLabelRule(
            type: .swiftBIC,
            subtype: nil,
            labelRegex: regex(#"(?i)\b(?:swift|bic)(?:\s*/\s*(?:bic|swift))?(?:\s+(?:code|number|num\.?|no\.?))?\b"#),
            valueRegex: regex(#"\b[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b"#),
            baseScore: 0.84
        ),
        SpatialLabelRule(
            type: .abaRoutingNumber,
            subtype: nil,
            labelRegex: regex(#"(?i)\b(?:routing|ABA)(?:\s+(?:number|num\.?|no\.?))?\b"#),
            valueRegex: regex(#"\b\d{9}\b"#),
            baseScore: 0.81
        ),
        SpatialLabelRule(
            type: .governmentID,
            subtype: .usPassport,
            labelRegex: regex(#"(?i)\bpassport(?:\s*(?:#|number|num\.?|no\.?))?\b"#),
            valueRegex: regex(#"\b[A-Z]?\d{8,9}\b"#),
            baseScore: 0.78
        ),
        SpatialLabelRule(
            type: .licensePlate,
            subtype: nil,
            labelRegex: regex(#"(?i)\b(?:licen[sc]e\s+plate|plate\s+(?:num(?:ber)?|no\.?|#)|lp|vehicle\s+tag|reg(?:istration)?\s+plate)\b"#),
            valueRegex: regex(#"\b[A-Z0-9]{2,4}[\ \-]?[A-Z0-9]{1,4}(?:[\ \-]?[A-Z0-9]{1,3})?\b"#),
            baseScore: 0.66
        )
    ]

    nonisolated private static func detectPII(
        in observations: [VNRecognizedTextObservation]
    ) throws -> [DetectionResult] {

        let primaryLines = observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let visionBox = observation.boundingBox
            return OCRLine(
                observation: observation,
                candidate: candidate,
                rank: 0,
                text: candidate.string,
                confidence: candidate.confidence,
                visionBox: visionBox,
                lineBounds: swiftUIBox(from: visionBox)
            )
        }.sorted(by: readingOrder)

        let candidateLines = observations.flatMap { observation -> [OCRLine] in
            let visionBox = observation.boundingBox
            return observation.topCandidates(5).enumerated().map { rank, candidate in
                OCRLine(
                    observation: observation,
                    candidate: candidate,
                    rank: rank,
                    text: candidate.string,
                    confidence: candidate.confidence,
                    visionBox: visionBox,
                    lineBounds: swiftUIBox(from: visionBox)
                )
            }
        }.sorted(by: readingOrder)

        // Keyed by PIIType so repeated hits across observations accumulate
        // into a single DetectionResult with an ever-growing `instances` array.
        var resultsDict: [PIIType: DetectionResult] = [:]

        /// Appends a DetectedInstance to an existing result or creates a fresh one.
        ///
        /// Score computation:
        ///   finalScore = baseScore × ocrConfidence
        ///
        /// If the type already has a result, the result's top-level `score` is
        /// upgraded when the new instance score is higher — fixing the previous bug
        /// where whichever detector fired first permanently owned the confidence level.
        /// This also resolves the email race: if NSDataDetector fires at base 0.75
        /// before the regex (base 0.93), the regex pass will correctly win.
        ///
        /// Duplicate instances (same snippet + boundingBox) are silently dropped
        /// to prevent double-counting when both detectors match the same text.
        func record(
            _ type: PIIType,
            subtype: PIISubtype? = nil,
            baseScore: Double,
            ocrConfidence: Float,
            instance: DetectedInstance,
            candidateRank: Int,
            lineBounds: CGRect,
            spatialEvidence: Bool = false
        ) {
            let instanceScore = Self.confidenceScore(
                type: type,
                subtype: subtype ?? instance.subtype,
                baseScore: baseScore,
                ocrConfidence: ocrConfidence,
                candidateRank: candidateRank,
                snippet: instance.snippet,
                boundingBox: instance.boundingBox,
                lineBounds: lineBounds,
                spatialEvidence: spatialEvidence
            )
            let scoredInstance = DetectedInstance(
                snippet: instance.snippet,
                subtype: subtype ?? instance.subtype,
                boundingBox: instance.boundingBox,
                score: instanceScore
            )

            if var existing = resultsDict[type] {
                if let duplicateIndex = existing.instances.firstIndex(where: {
                    $0.subtype == scoredInstance.subtype &&
                    Self.representsSameRegion($0.boundingBox, scoredInstance.boundingBox)
                }) {
                    if scoredInstance.score > existing.instances[duplicateIndex].score {
                        existing.instances[duplicateIndex] = scoredInstance
                    }
                } else if !existing.instances.contains(scoredInstance) {
                    existing.instances.append(scoredInstance)
                }
                // Upgrade the result-level score if this detection is stronger.
                if instanceScore > existing.score {
                    existing.score = instanceScore
                }
                resultsDict[type] = existing
            } else {
                resultsDict[type] = DetectionResult(
                    type: type,
                    score: instanceScore,
                    instances: [scoredInstance]
                )
            }
        }

        // Orphan-label regex: matches an observation that IS a credential keyword
        // (possibly garbled by Vision) but has no value on the same line.
        // When we see this, we stash the label and treat the NEXT observation as
        // the password value — handling whiteboard splits across two text lines.
        let orphanLabelRegex = try NSRegularExpression(
            pattern: #"(?i)^[a-z0-9 ]{0,12}(?:login|log ?in|pass(?:word)?|pwd|user(?:name)?|cred(?:ential)?s?|ha[sś][łl]o|haslo|islo|iso|g?in|ogin|0g ?in|min)\s*[*•:.\-=]?\s*$"#
        )

        // Cross-observation state: non-nil when we have seen a bare credential
        // keyword and are waiting for the next observation to supply the value.
        var pendingCredentialLabel: String?

        for line in candidateLines {
            let candidate = line.candidate
            let text    = line.text
            let nsRange = NSRange(text.startIndex..., in: text)

            // ── OCR confidence for this observation ──────────────────────────
            // Vision's per-candidate confidence reflects how certain the OCR engine
            // is about the text recognition itself (0.0–1.0). We multiply each
            // rule's base score by this value so matches in sharp, well-lit text
            // score higher than the same pattern in blurry or rotated text.
            let ocrConfidence: Float = line.confidence

            // ── Coordinate conversion ────────────────────────────────────────
            // Vision's boundingBox is normalised (0…1) with a BOTTOM-LEFT origin.
            // We flip the Y axis here so stored boxes use SwiftUI's top-left system:
            //   flippedY = 1 - originY - height
            let visionBox  = line.visionBox
            let lineBounds = line.lineBounds

            // ── Heuristic state tracker ──────────────────────────────────────
            // If we stashed a credential label from the previous observation,
            // treat this entire observation as the credential value.
            if line.rank == 0, let label = pendingCredentialLabel {
                pendingCredentialLabel = nil
                let snippet = Self.snippet(text, max: 60)
                // Base score 0.65: cross-observation heuristic; structurally weaker.
                record(.unstructuredCredential,
                       baseScore: 0.65,
                       ocrConfidence: ocrConfidence,
                       instance: DetectedInstance(snippet: "\(label) \(snippet)", boundingBox: lineBounds, score: 0),
                       candidateRank: line.rank,
                       lineBounds: lineBounds,
                       spatialEvidence: true)
                // Don't skip the remaining analysis — the password line might
                // also contain independently detectable PII (e.g., an email).
            }

            // ── Stage B: Rules engine (runs FIRST) ───────────────────────────
            // The regex rules run before NSDataDetector so that structurally
            // tighter patterns (e.g. email regex base 0.93) are recorded first.
            // For overlapping types (email) the NSDataDetector pass may then
            // try to record at a lower base score — but record() will not
            // downgrade an already-higher score, so the regex result wins.
            var stageBMatched = false
            for rule in DetectionRegistry.allRules {
                let matches = rule.regex.matches(in: text, options: [], range: nsRange)
                for match in matches {
                    stageBMatched = true

                    // Prefer capture group 1 (e.g., the value after "password:");
                    // fall back to the full match range.
                    let valueRange = match.numberOfRanges > 1
                        ? match.range(at: 1)
                        : match.range

                    let box     = Self.substringBox(candidate: candidate,
                                                    nsRange: valueRange,
                                                    in: text,
                                                    fallback: visionBox)
                    let snippet = Self.snippet(from: text, nsRange: valueRange)

                    // Luhn-boost: a structurally valid credit-card pattern that ALSO
                    // passes the Luhn checksum is dramatically more likely to be a
                    // real card.  Bump the base score by 0.05 (capped at 0.99) so
                    // the user sees a higher confidence on a clean read; non-Luhn
                    // matches keep the original score rather than being rejected,
                    // since OCR may corrupt one digit on a real card.
                    let effectiveBaseScore = Self.adjustedBaseScore(for: rule, snippet: snippet)

                    record(rule.type,
                           subtype: rule.subtype,
                           baseScore: effectiveBaseScore,
                           ocrConfidence: ocrConfidence,
                           instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0),
                           candidateRank: line.rank,
                           lineBounds: lineBounds)
                }
            }

            // ── Stage A: Native NSDataDetector ───────────────────────────────
            // Runs after the regex pass. For types also covered by a regex rule
            // (email), record() will not downgrade a stronger score already set.
            var stageAMatched = false
            nativeDetector?.enumerateMatches(in: text, options: [], range: nsRange) { match, _, _ in
                guard let match else { return }
                stageAMatched = true

                // Attempt a tight substring box; fall back to the observation line box.
                let box     = Self.substringBox(candidate: candidate,
                                                nsRange: match.range,
                                                in: text,
                                                fallback: visionBox)
                let snippet = Self.snippet(from: text, nsRange: match.range)

                switch match.resultType {
                case .phoneNumber:
                    // Base 0.72: NLP-based; good but not structurally verifiable.
                    record(.phoneNumber, baseScore: 0.72, ocrConfidence: ocrConfidence,
                           instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0),
                           candidateRank: line.rank,
                           lineBounds: lineBounds)
                case .address:
                    // Base 0.68: NLP + address grammar; context-dependent.
                    record(.address, baseScore: 0.68, ocrConfidence: ocrConfidence,
                           instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0),
                           candidateRank: line.rank,
                           lineBounds: lineBounds)
                case .link:
                    if let url = match.url, url.scheme == "mailto" {
                        // Base 0.75 for mailto: links — lower than the regex (0.93)
                        // so a prior regex hit on the same email won't be downgraded.
                        record(.email, baseScore: 0.75, ocrConfidence: ocrConfidence,
                               instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0),
                               candidateRank: line.rank,
                               lineBounds: lineBounds)
                    } else {
                        // Base 0.52: generic link — appears in many non-sensitive contexts.
                        record(.link, baseScore: 0.52, ocrConfidence: ocrConfidence,
                               instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0),
                               candidateRank: line.rank,
                               lineBounds: lineBounds)
                    }
                default:
                    break
                }
            }

            // ── Orphan label check ───────────────────────────────────────────
            // If neither stage matched, check whether this observation is a bare
            // credential keyword with no accompanying value. If so, stash it so
            // the next observation is treated as the password.
            if line.rank == 0, !stageAMatched && !stageBMatched {
                if orphanLabelRegex.firstMatch(in: text, options: [], range: nsRange) != nil {
                    pendingCredentialLabel = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        for labelLine in primaryLines {
            let labelText = labelLine.text
            let labelRange = NSRange(labelText.startIndex..., in: labelText)

            for rule in spatialLabelRules where rule.labelRegex.firstMatch(in: labelText, options: [], range: labelRange) != nil {
                guard let value = nearestValueLine(for: labelLine, in: primaryLines, using: rule.valueRegex) else {
                    continue
                }
                let snippet = Self.snippet(from: value.line.text, nsRange: value.range)
                guard !snippet.isEmpty else { continue }

                let box = Self.substringBox(
                    candidate: value.line.candidate,
                    nsRange: value.range,
                    in: value.line.text,
                    fallback: value.line.visionBox
                )

                let effectiveBaseScore = Self.adjustedBaseScore(
                    type: rule.type,
                    subtype: rule.subtype,
                    baseScore: rule.baseScore,
                    snippet: snippet
                )
                record(rule.type,
                       subtype: rule.subtype,
                       baseScore: effectiveBaseScore,
                       ocrConfidence: min(labelLine.confidence, value.line.confidence),
                       instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0),
                       candidateRank: value.line.rank,
                       lineBounds: value.line.lineBounds,
                       spatialEvidence: true)
            }
        }

        // Sort: highest score first, alphabetical description as tiebreaker.
        return resultsDict.values.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.type.description < $1.type.description
        }
    }

    private enum ChecksumState {
        case valid
        case invalid
        case unknown
    }

    /// Computes the final visible confidence for a detected instance.
    ///
    /// The scanner still starts from each rule's calibrated base score, but this
    /// layer keeps the result from feeling static by folding in evidence that
    /// changes from image to image: OCR confidence, whether the match came from
    /// an alternate OCR candidate, how much usable geometry Vision gave us, and
    /// whether the value was found through nearby label/value context.
    nonisolated static func confidenceScore(
        type: PIIType,
        subtype: PIISubtype?,
        baseScore: Double,
        ocrConfidence: Float,
        candidateRank: Int,
        snippet: String,
        boundingBox: CGRect,
        lineBounds: CGRect,
        spatialEvidence: Bool = false
    ) -> Double {
        var score = baseScore * Double(ocrConfidence)
        score *= candidateRankFactor(candidateRank)
        score *= geometryFactor(for: boundingBox, lineBounds: lineBounds)
        score *= ambiguityFactor(type: type, subtype: subtype, snippet: snippet)
        if spatialEvidence {
            score *= 1.06
        }
        return min(0.99, max(0.05, score))
    }

    nonisolated private static func candidateRankFactor(_ rank: Int) -> Double {
        switch rank {
        case 0: return 1.0
        case 1: return 0.93
        case 2: return 0.87
        case 3: return 0.81
        default: return 0.75
        }
    }

    nonisolated private static func geometryFactor(for boundingBox: CGRect, lineBounds: CGRect) -> Double {
        guard boundingBox.width > 0, boundingBox.height > 0 else { return 0.78 }

        var factor = 1.0
        let area = boundingBox.width * boundingBox.height
        if boundingBox.height < 0.010 || boundingBox.width < 0.020 {
            factor *= 0.88
        } else if boundingBox.height >= 0.024 && area >= 0.002 {
            factor *= 1.03
        }

        let lineArea = max(lineBounds.width * lineBounds.height, 0.0001)
        let coverage = area / lineArea
        if coverage < 0.025 {
            factor *= 0.94
        } else if coverage > 0.30 {
            factor *= 1.02
        }

        return min(1.05, max(0.78, factor))
    }

    nonisolated private static func ambiguityFactor(
        type: PIIType,
        subtype: PIISubtype?,
        snippet: String
    ) -> Double {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitCount = trimmed.filter(\.isNumber).count
        let alphanumericCount = trimmed.filter { $0.isLetter || $0.isNumber }.count

        switch type {
        case .dateOfBirth:
            return 0.96
        case .licensePlate:
            return alphanumericCount < 5 ? 0.86 : 1.0
        case .link:
            return trimmed.localizedCaseInsensitiveContains("://") ? 1.02 : 0.94
        case .governmentID:
            if subtype == nil && digitCount <= 9 {
                return 0.92
            }
            return 1.0
        case .creditCard:
            return passesLuhn(digits: trimmed) ? 1.02 : 0.96
        case .phoneNumber:
            if isLikelyCreditCardNumber(trimmed) {
                return 0.32
            }
            return digitCount < 10 ? 0.92 : 1.0
        default:
            return 1.0
        }
    }

    nonisolated private static func readingOrder(_ lhs: OCRLine, _ rhs: OCRLine) -> Bool {
        let yDelta = abs(lhs.lineBounds.midY - rhs.lineBounds.midY)
        if yDelta > 0.02 {
            return lhs.lineBounds.midY < rhs.lineBounds.midY
        }
        if abs(lhs.lineBounds.minX - rhs.lineBounds.minX) > 0.01 {
            return lhs.lineBounds.minX < rhs.lineBounds.minX
        }
        return lhs.rank < rhs.rank
    }

    nonisolated private static func nearestValueLine(
        for labelLine: OCRLine,
        in lines: [OCRLine],
        using valueRegex: NSRegularExpression
    ) -> (line: OCRLine, range: NSRange)? {
        var best: (line: OCRLine, range: NSRange, distance: CGFloat)?

        for line in lines {
            guard line.observation !== labelLine.observation else { continue }

            let verticalDelta = line.lineBounds.midY - labelLine.lineBounds.midY
            let sameRow = abs(verticalDelta) <= max(0.035, labelLine.lineBounds.height * 1.4)
                && line.lineBounds.midX >= labelLine.lineBounds.midX
            let nearbyBelow = verticalDelta >= -0.01
                && verticalDelta <= 0.18
                && abs(line.lineBounds.midX - labelLine.lineBounds.midX) <= 0.55
            guard sameRow || nearbyBelow else { continue }

            let text = line.text
            let range = NSRange(text.startIndex..., in: text)
            guard let match = valueRegex.firstMatch(in: text, options: [], range: range) else {
                continue
            }

            let dx = max(0, line.lineBounds.minX - labelLine.lineBounds.maxX)
            let dy = max(0, verticalDelta)
            let distance = (dx * dx) + (dy * dy * 4)
            if best == nil || distance < best!.distance {
                best = (line, match.range, distance)
            }
        }

        guard let best else { return nil }
        return (best.line, best.range)
    }

    nonisolated private static func representsSameRegion(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return false }
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smallerArea > 0 else { return false }
        return (intersection.width * intersection.height) / smallerArea >= 0.88
    }

    nonisolated static func adjustedBaseScore(for rule: DetectionRule, snippet: String) -> Double {
        adjustedBaseScore(type: rule.type, subtype: rule.subtype, baseScore: rule.baseScore, snippet: snippet)
    }

    nonisolated static func adjustedBaseScore(
        type: PIIType,
        subtype: PIISubtype?,
        baseScore: Double,
        snippet: String
    ) -> Double {
        if type == .creditCard {
            return passesLuhn(digits: snippet) ? min(0.99, baseScore + 0.05) : baseScore
        }

        let state = checksumState(type: type, subtype: subtype, snippet: snippet)
        switch state {
        case .valid:
            return min(0.99, baseScore + 0.05)
        case .invalid:
            return max(0.35, baseScore * 0.82)
        case .unknown:
            return baseScore
        }
    }

    nonisolated private static func checksumState(
        type: PIIType,
        subtype: PIISubtype?,
        snippet: String
    ) -> ChecksumState {
        switch type {
        case .iban:
            return isValidIBAN(snippet) ? .valid : .invalid
        case .abaRoutingNumber:
            return isValidABARoutingNumber(snippet) ? .valid : .invalid
        case .vehicleIdentificationNumber:
            return isValidVIN(snippet) ? .valid : .invalid
        case .governmentID:
            switch subtype {
            case .brazilianCPF:
                return isValidCPF(snippet) ? .valid : .invalid
            case .canadianSIN:
                return passesLuhn(digits: digitsOnly(snippet), allowedLengths: [9]) ? .valid : .invalid
            case .polishPESEL:
                return isValidPESEL(snippet) ? .valid : .invalid
            case .chineseResidentID:
                return isValidChineseResidentID(snippet) ? .valid : .invalid
            default:
                return .unknown
            }
        default:
            return .unknown
        }
    }

    nonisolated private static func digitsOnly(_ value: String) -> String {
        value.compactMap(\.wholeNumberValue).map(String.init).joined()
    }

    nonisolated private static func isValidIBAN(_ value: String) -> Bool {
        let cleaned = value.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count >= 15, cleaned.count <= 34 else { return false }
        guard cleaned.prefix(2).allSatisfy(\.isLetter),
              cleaned.dropFirst(2).prefix(2).allSatisfy(\.isNumber)
        else { return false }

        let rearranged = cleaned.dropFirst(4) + cleaned.prefix(4)
        var remainder = 0
        for char in rearranged {
            if let digit = char.wholeNumberValue {
                remainder = (remainder * 10 + digit) % 97
            } else if let scalar = char.unicodeScalars.first,
                      scalar.value >= 65, scalar.value <= 90 {
                let value = Int(scalar.value - 55)
                remainder = (remainder * 100 + value) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    nonisolated private static func isValidABARoutingNumber(_ value: String) -> Bool {
        let digits = digitsOnly(value).compactMap(\.wholeNumberValue)
        guard digits.count == 9 else { return false }
        let checksum =
            3 * (digits[0] + digits[3] + digits[6]) +
            7 * (digits[1] + digits[4] + digits[7]) +
            digits[2] + digits[5] + digits[8]
        return checksum.isMultiple(of: 10)
    }

    nonisolated private static func isValidVIN(_ value: String) -> Bool {
        let vin = value.uppercased().filter { $0.isLetter || $0.isNumber }
        guard vin.count == 17, !vin.contains("I"), !vin.contains("O"), !vin.contains("Q") else {
            return false
        }

        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        var sum = 0
        for (index, char) in vin.enumerated() {
            guard let value = vinTransliterationValue(char) else { return false }
            sum += value * weights[index]
        }
        let remainder = sum % 11
        let expected = remainder == 10 ? "X" : String(remainder)
        let checkIndex = vin.index(vin.startIndex, offsetBy: 8)
        return String(vin[checkIndex]) == expected
    }

    nonisolated private static func vinTransliterationValue(_ char: Character) -> Int? {
        if let digit = char.wholeNumberValue { return digit }
        switch char {
        case "A", "J": return 1
        case "B", "K", "S": return 2
        case "C", "L", "T": return 3
        case "D", "M", "U": return 4
        case "E", "N", "V": return 5
        case "F", "W": return 6
        case "G", "P", "X": return 7
        case "H", "Y": return 8
        case "R", "Z": return 9
        default: return nil
        }
    }

    nonisolated private static func isValidCPF(_ value: String) -> Bool {
        let digits = digitsOnly(value).compactMap(\.wholeNumberValue)
        guard digits.count == 11, Set(digits).count > 1 else { return false }

        func checkDigit(prefixCount: Int) -> Int {
            let weights = Array(stride(from: prefixCount + 1, through: 2, by: -1))
            let sum = zip(digits.prefix(prefixCount), weights).map(*).reduce(0, +)
            let remainder = (sum * 10) % 11
            return remainder == 10 ? 0 : remainder
        }

        return digits[9] == checkDigit(prefixCount: 9) &&
            digits[10] == checkDigit(prefixCount: 10)
    }

    nonisolated private static func isValidPESEL(_ value: String) -> Bool {
        let digits = digitsOnly(value).compactMap(\.wholeNumberValue)
        guard digits.count == 11 else { return false }
        let weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
        let sum = zip(digits.prefix(10), weights).map(*).reduce(0, +)
        let check = (10 - (sum % 10)) % 10
        return digits[10] == check
    }

    nonisolated private static func isValidChineseResidentID(_ value: String) -> Bool {
        let cleaned = value.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count == 18 else { return false }
        let body = cleaned.prefix(17)
        let digits = body.compactMap(\.wholeNumberValue)
        guard digits.count == 17 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let codes = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]
        let sum = zip(digits, weights).map(*).reduce(0, +)
        return String(cleaned.last!) == codes[sum % 11]
    }

    // MARK: - Visual detection helpers

    /// Maps `VNFaceObservation`s from the single-pass handler into one
    /// `DetectionResult`.  Face results carry a fixed score of 0.99 — the
    /// dedicated ML model is highly reliable and the result needs no
    /// OCR-confidence weighting.
    nonisolated static func recognizedLineContexts(
        from observations: [VNRecognizedTextObservation]
    ) -> [RecognizedLineContext] {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLineContext(
                text: candidate.string,
                boundingBox: swiftUIBox(from: observation.boundingBox),
                confidence: candidate.confidence
            )
        }.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
                return $0.boundingBox.midY < $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
    }

    nonisolated static func barcodeContexts(from observations: [VNBarcodeObservation]) -> [BarcodeContext] {
        observations.map { obs in
            BarcodeContext(
                boundingBox: swiftUIBox(from: obs.boundingBox),
                symbology: String(describing: obs.symbology),
                payload: obs.payloadStringValue
            )
        }
    }

    nonisolated static func faceResults(from rects: [CGRect]) -> [DetectionResult] {
        guard !rects.isEmpty else { return [] }
        let instances = rects.map { rect in
            DetectedInstance(
                snippet: String(localized: "Face detected"),
                boundingBox: rect,
                score: 0.99
            )
        }
        return [DetectionResult(type: .face, score: 0.99, instances: instances)]
    }

    /// Maps `VNBarcodeObservation`s from the single-pass handler into one
    /// `DetectionResult`.  The decoded payload is placed in the snippet.
    nonisolated static func barcodeResults(from contexts: [BarcodeContext]) -> [DetectionResult] {
        guard !contexts.isEmpty else { return [] }
        var instances: [DetectedInstance] = []
        for context in contexts {
            let payload = context.payload ?? String(localized: "Encoded barcode")
            let instance = DetectedInstance(
                snippet: snippet(payload, max: 60),
                boundingBox: context.boundingBox,
                score: 0.99
            )
            if !instances.contains(instance) {
                instances.append(instance)
            }
        }
        guard !instances.isEmpty else { return [] }
        return [DetectionResult(type: .barcode, score: 0.99, instances: instances)]
    }

    // MARK: - Document region boost

    /// PII types that meaningfully benefit from "is on a document/ID card" context.
    /// A 9-digit number floating in random text is ambiguous; the same number on a
    /// detected document quad is much more likely to be a real ID.
    nonisolated static let documentBoostableTypes: Set<PIIType> = [
        .creditCard,
        .governmentID,
        .socialSecurityNumber,
        .nationalInsuranceNumber,
        .dateOfBirth,
        .iban,
        .abaRoutingNumber,
        .swiftBIC,
        .vehicleIdentificationNumber,
        .licensePlate
    ]

    /// Multiplier applied to the instance score when the instance bounding box
    /// falls inside a detected document rectangle.  Chosen so a clean 0.85 base
    /// (e.g. a regional DL) bumps to ~0.97 — confidence the user can see — without
    /// taking weaker matches above 1.0.
    nonisolated static let documentBoostFactor: Double = 1.15

    nonisolated static let documentContextBoostFactor: Double = 1.12
    nonisolated static let documentContextDampenFactor: Double = 0.68

    /// Returns a copy of `results` with each ID-like instance's score multiplied
    /// when its bounding box falls inside one of the supplied `documentRects`.
    /// Scores are clamped to `0.99` so they remain comparable to fixed-confidence
    /// face/barcode results.
    nonisolated static func applyDocumentBoost(
        results: [DetectionResult],
        documentRects: [CGRect]
    ) -> [DetectionResult] {
        guard !documentRects.isEmpty else { return results }

        return results.map { result -> DetectionResult in
            guard documentBoostableTypes.contains(result.type) else { return result }

            var boostedMax = result.score
            let boostedInstances: [DetectedInstance] = result.instances.map { inst in
                let centre = CGPoint(x: inst.boundingBox.midX, y: inst.boundingBox.midY)
                let inside = documentRects.contains { $0.contains(centre) }
                guard inside else { return inst }
                let newScore = min(0.99, inst.score * documentBoostFactor)
                if newScore > boostedMax { boostedMax = newScore }
                return DetectedInstance(
                    snippet: inst.snippet,
                    subtype: inst.subtype,
                    boundingBox: inst.boundingBox,
                    score: newScore
                )
            }

            return DetectionResult(
                type: result.type,
                score: boostedMax,
                instances: boostedInstances
            )
        }
    }

    nonisolated static func applyDocumentContext(
        results: [DetectionResult],
        documentRects: [CGRect],
        faceRects: [CGRect],
        barcodeContexts: [BarcodeContext],
        textLines: [RecognizedLineContext]
    ) -> [DetectionResult] {
        let contexts = inferDocumentContexts(
            results: results,
            documentRects: documentRects,
            faceRects: faceRects,
            barcodeContexts: barcodeContexts,
            textLines: textLines
        )
        guard !contexts.isEmpty else { return results }

        var updated = results.map { result -> DetectionResult in
            var maxScore = 0.0
            let adjustedInstances = result.instances.map { instance -> DetectedInstance in
                let containingContexts = contexts.filter { context in
                    Self.rect(context.boundingBox, containsCentreOf: instance.boundingBox)
                }
                guard !containingContexts.isEmpty else {
                    maxScore = max(maxScore, instance.score)
                    return instance
                }

                let shouldBoost = containingContexts.contains { $0.kind.boostableTypes.contains(result.type) }
                let shouldDampen = !shouldBoost && containingContexts.contains { $0.kind.dampenedTypes.contains(result.type) }
                let newScore: Double
                if shouldBoost {
                    newScore = min(0.99, instance.score * documentContextBoostFactor)
                } else if shouldDampen {
                    newScore = max(0.25, instance.score * documentContextDampenFactor)
                } else {
                    newScore = instance.score
                }

                maxScore = max(maxScore, newScore)
                return DetectedInstance(
                    snippet: instance.snippet,
                    subtype: instance.subtype,
                    boundingBox: instance.boundingBox,
                    score: newScore
                )
            }

            let resultScore = adjustedInstances.isEmpty ? result.score : maxScore
            return DetectionResult(type: result.type, score: resultScore, instances: adjustedInstances)
        }

        for context in contexts {
            let instance = DetectedInstance(
                snippet: context.kind.snippet,
                subtype: context.kind.subtype,
                boundingBox: context.boundingBox,
                score: context.score
            )
            Self.append(instance, type: context.kind.type, to: &updated)
        }

        return updated
    }

    nonisolated static func resolveCreditCardPhoneConflicts(_ results: [DetectionResult]) -> [DetectionResult] {
        guard
            let cardResult = results.first(where: { $0.type == .creditCard }),
            let phoneIndex = results.firstIndex(where: { $0.type == .phoneNumber })
        else {
            return results
        }

        var resolved = results
        var phoneResult = resolved[phoneIndex]
        let adjustedPhoneInstances = phoneResult.instances.compactMap { phone -> DetectedInstance? in
            let sameDigitsAsCard = cardResult.instances.contains { card in
                Self.instancesRepresentSameDigits(phone, card)
            }
            if sameDigitsAsCard {
                return nil
            }

            let overlapsCard = cardResult.instances.contains { card in
                Self.representsSameRegion(phone.boundingBox, card.boundingBox)
            }
            guard overlapsCard else { return phone }

            let dampenedScore = min(phone.score, max(0.20, phone.score * 0.35))
            guard dampenedScore >= 0.30 else { return nil }
            return DetectedInstance(
                snippet: phone.snippet,
                subtype: phone.subtype,
                boundingBox: phone.boundingBox,
                score: dampenedScore
            )
        }

        if adjustedPhoneInstances.isEmpty {
            resolved.remove(at: phoneIndex)
        } else {
            phoneResult.instances = adjustedPhoneInstances
            phoneResult.score = adjustedPhoneInstances.map(\.score).max() ?? phoneResult.score
            resolved[phoneIndex] = phoneResult
        }
        return resolved
    }

    nonisolated static func inferDocumentContexts(
        results: [DetectionResult],
        documentRects: [CGRect],
        faceRects: [CGRect],
        barcodeContexts: [BarcodeContext],
        textLines: [RecognizedLineContext]
    ) -> [DocumentContext] {
        let candidateRects = documentRects.filter { rect in
            rect.width > 0.08 && rect.height > 0.08
        }
        guard !candidateRects.isEmpty else { return [] }

        var contexts: [DocumentContext] = []
        for rect in candidateRects {
            let text = textLines
                .filter { Self.rect(rect, containsCentreOf: $0.boundingBox) || rect.intersects($0.boundingBox) }
                .map(\.text)
                .joined(separator: " ")
            let lowercasedText = text.lowercased()

            let hasFace = faceRects.contains { Self.rect(rect, containsCentreOf: $0) || rect.intersects($0) }
            let containedBarcodes = barcodeContexts.filter { Self.rect(rect, containsCentreOf: $0.boundingBox) || rect.intersects($0.boundingBox) }
            let hasBarcode = !containedBarcodes.isEmpty
            let hasPDF417 = containedBarcodes.contains(where: \.isPDF417)

            let cardAspect = Self.aspectRatio(of: rect)
            let cardLike = (1.35...1.9).contains(cardAspect)
            let pageLike = (0.65...1.35).contains(cardAspect) || (1.9...3.0).contains(cardAspect)

            let hasCreditCardNumber = Self.result(.creditCard, in: results, intersects: rect)
                || Self.creditCardLikeRegex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
            let hasExpiry = Self.expiryRegex.firstMatch(in: lowercasedText, options: [], range: NSRange(lowercasedText.startIndex..., in: lowercasedText)) != nil
            let hasCardBrand = Self.cardBrandRegex.firstMatch(in: lowercasedText, options: [], range: NSRange(lowercasedText.startIndex..., in: lowercasedText)) != nil

            let hasDLKeyword = Self.driverLicenseKeywordRegex.firstMatch(in: lowercasedText, options: [], range: NSRange(lowercasedText.startIndex..., in: lowercasedText)) != nil
            let hasIDKeyword = Self.identityKeywordRegex.firstMatch(in: lowercasedText, options: [], range: NSRange(lowercasedText.startIndex..., in: lowercasedText)) != nil
            let hasPassportKeyword = Self.passportKeywordRegex.firstMatch(in: lowercasedText, options: [], range: NSRange(lowercasedText.startIndex..., in: lowercasedText)) != nil
            let hasMRZ = Self.mrzRegex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil

            let hasDOB = Self.result(.dateOfBirth, in: results, intersects: rect)
            let hasAddress = Self.result(.address, in: results, intersects: rect)
            let hasGovID = Self.result(.governmentID, in: results, intersects: rect)
                || Self.result(.socialSecurityNumber, in: results, intersects: rect)
                || Self.result(.nationalInsuranceNumber, in: results, intersects: rect)

            var scored: [(DocumentContextKind, Double)] = []

            var creditCardScore = 0.0
            if cardLike { creditCardScore += 0.22 }
            if hasCreditCardNumber { creditCardScore += 0.46 }
            if hasExpiry { creditCardScore += 0.14 }
            if hasCardBrand { creditCardScore += 0.10 }
            if !hasFace { creditCardScore += 0.04 }
            if creditCardScore >= 0.58 {
                scored.append((.creditCard, min(0.97, creditCardScore)))
            }

            var driverLicenseScore = 0.0
            if cardLike { driverLicenseScore += 0.18 }
            if hasFace { driverLicenseScore += 0.22 }
            if hasPDF417 { driverLicenseScore += 0.24 }
            if hasDLKeyword { driverLicenseScore += 0.26 }
            if hasGovID { driverLicenseScore += 0.12 }
            if hasDOB { driverLicenseScore += 0.10 }
            if hasAddress { driverLicenseScore += 0.08 }
            if driverLicenseScore >= 0.56 {
                scored.append((.driversLicense, min(0.98, driverLicenseScore)))
            }

            var passportScore = 0.0
            if pageLike { passportScore += 0.10 }
            if hasPassportKeyword { passportScore += 0.34 }
            if hasMRZ { passportScore += 0.30 }
            if hasFace { passportScore += 0.18 }
            if hasDOB || hasGovID { passportScore += 0.08 }
            if passportScore >= 0.56 {
                scored.append((.passport, min(0.98, passportScore)))
            }

            var identityScore = 0.0
            if cardLike || pageLike { identityScore += 0.16 }
            if hasFace { identityScore += 0.20 }
            if hasIDKeyword { identityScore += 0.20 }
            if hasGovID { identityScore += 0.18 }
            if hasDOB { identityScore += 0.10 }
            if hasAddress { identityScore += 0.07 }
            if hasBarcode { identityScore += 0.08 }
            if identityScore >= 0.56 {
                scored.append((.identityDocument, min(0.95, identityScore)))
            }

            guard let best = scored.max(by: { $0.1 < $1.1 }) else { continue }
            let context = DocumentContext(kind: best.0, boundingBox: rect, score: best.1)
            if !contexts.contains(where: {
                $0.kind == context.kind && Self.representsSameRegion($0.boundingBox, context.boundingBox)
            }) {
                contexts.append(context)
            }
        }
        return contexts
    }

    nonisolated private static let creditCardLikeRegex = regex(#"\b(?:\d[ -]?){13,19}\b"#)
    nonisolated private static let expiryRegex = regex(#"(?i)\b(?:exp(?:iry|ires)?|valid\s*(?:thru|through)|good\s*thru)?\s*(?:0[1-9]|1[0-2])\s*[\/\-]\s*(?:\d{2}|\d{4})\b"#)
    nonisolated private static let cardBrandRegex = regex(#"(?i)\b(?:visa|master\s*card|mastercard|amex|american\s+express|discover|debit|credit)\b"#)
    nonisolated private static let driverLicenseKeywordRegex = regex(#"(?i)\b(?:driver'?s?\s+licen[sc]e|driving\s+licen[sc]e|driver\s+id|licen[sc]e\s*(?:no|num|number|#)|\bDL\b|\bLIC\b)\b"#)
    nonisolated private static let identityKeywordRegex = regex(#"(?i)\b(?:identity\s+card|identification\s+card|national\s+id|state\s+id|id\s*(?:no|num|number|#)|document\s*(?:no|num|number|#))\b"#)
    nonisolated private static let passportKeywordRegex = regex(#"(?i)\bpassport\b"#)
    nonisolated private static let mrzRegex = regex(#"\b[PA-Z0-9<]{1,2}<[A-Z0-9<]{20,}\b"#)

    nonisolated private static func append(
        _ instance: DetectedInstance,
        type: PIIType,
        to results: inout [DetectionResult]
    ) {
        if let index = results.firstIndex(where: { $0.type == type }) {
            if !results[index].instances.contains(where: {
                $0.subtype == instance.subtype && Self.representsSameRegion($0.boundingBox, instance.boundingBox)
            }) {
                results[index].instances.append(instance)
            }
            results[index].score = max(results[index].score, instance.score)
        } else {
            results.append(DetectionResult(type: type, score: instance.score, instances: [instance]))
        }
    }

    nonisolated private static func result(_ type: PIIType, in results: [DetectionResult], intersects rect: CGRect) -> Bool {
        results.first(where: { $0.type == type })?.instances.contains { instance in
            Self.rect(rect, containsCentreOf: instance.boundingBox) || rect.intersects(instance.boundingBox)
        } ?? false
    }

    nonisolated private static func rect(_ rect: CGRect, containsCentreOf child: CGRect) -> Bool {
        rect.contains(CGPoint(x: child.midX, y: child.midY))
    }

    nonisolated private static func aspectRatio(of rect: CGRect) -> CGFloat {
        let width = max(rect.width, 0.0001)
        let height = max(rect.height, 0.0001)
        return max(width, height) / min(width, height)
    }

    nonisolated private static func instancesRepresentSameDigits(
        _ lhs: DetectedInstance,
        _ rhs: DetectedInstance
    ) -> Bool {
        let lhsDigits = digitsOnly(lhs.snippet)
        let rhsDigits = digitsOnly(rhs.snippet)
        guard !lhsDigits.isEmpty, !rhsDigits.isEmpty else { return false }
        return lhsDigits == rhsDigits || lhsDigits.contains(rhsDigits) || rhsDigits.contains(lhsDigits)
    }

    nonisolated private static func isLikelyCreditCardNumber(_ value: String) -> Bool {
        let digits = digitsOnly(value)
        guard (13...19).contains(digits.count),
              passesLuhn(digits: digits),
              hasCreditCardIssuerPrefix(digits)
        else {
            return false
        }
        return true
    }

    nonisolated private static func hasCreditCardIssuerPrefix(_ digits: String) -> Bool {
        guard let first = digits.first?.wholeNumberValue else { return false }
        if first == 4 { return true }

        let prefix2 = Int(String(digits.prefix(2))) ?? -1
        if (34...37).contains(prefix2) || (51...55).contains(prefix2) || prefix2 == 65 {
            return true
        }

        let prefix4 = Int(String(digits.prefix(4))) ?? -1
        if prefix4 == 6011 { return true }

        let prefix6 = Int(String(digits.prefix(6))) ?? -1
        return (222100...272099).contains(prefix6)
    }

    // MARK: - Luhn validation

    /// Validates a string of decimal digits against the Luhn checksum.  Used as a
    /// *confidence booster* for credit card matches (a Luhn-valid 16-digit string
    /// is much more likely a real card than a non-validating one).  Filtering by
    /// Luhn is intentionally avoided — OCR may corrupt a single digit on an
    /// otherwise-real card and we'd rather flag than miss.
    nonisolated static func passesLuhn(digits: String) -> Bool {
        let raw = digits.filter(\.isNumber)
        guard raw.count >= 12, raw.count <= 19 else { return false }
        return passesLuhn(digits: raw, allowedLengths: Set(12...19))
    }

    nonisolated private static func passesLuhn(digits: String, allowedLengths: Set<Int>) -> Bool {
        let raw = digits.filter(\.isNumber)
        guard allowedLengths.contains(raw.count) else { return false }
        var sum = 0
        for (offset, char) in raw.reversed().enumerated() {
            guard let digit = char.wholeNumberValue else { return false }
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += (doubled > 9) ? (doubled - 9) : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    // MARK: - Coordinate helpers

    /// Converts a Vision bottom-left-origin normalised rect to a SwiftUI
    /// top-left-origin normalised rect.
    ///
    /// `internal` (not `private`) so the test suite can verify the Y-flip math
    /// without going through the full Vision pipeline.
    nonisolated static func swiftUIBox(from visionBox: CGRect) -> CGRect {
        CGRect(
            x: visionBox.origin.x,
            y: 1.0 - visionBox.origin.y - visionBox.height,
            width: visionBox.width,
            height: visionBox.height
        )
    }

    /// Returns a tight normalised bounding box for a matched substring within a
    /// `VNRecognizedText` candidate, falling back to the full observation box when
    /// the Vision API cannot supply character-level geometry.
    ///
    /// - Parameters:
    ///   - candidate: The `VNRecognizedText` whose `boundingBox(for:)` API is called.
    ///   - nsRange:   The `NSRange` of the matched substring within `text`.
    ///   - text:      The full string of the candidate.
    ///   - fallback:  The Vision-coordinate observation bounding box used when the
    ///                substring API fails.
    nonisolated private static func substringBox(
        candidate: VNRecognizedText,
        nsRange: NSRange,
        in text: String,
        fallback: CGRect
    ) -> CGRect {
        guard
            nsRange.location != NSNotFound,
            let swiftRange = Range(nsRange, in: text),
            let visionSubBox = try? candidate.boundingBox(for: swiftRange)
        else {
            return swiftUIBox(from: fallback)
        }
        // VNRectangleObservation returns a quadrilateral in Vision coordinates;
        // convert its bounding rect to SwiftUI coordinates.
        return swiftUIBox(from: visionSubBox.boundingBox)
    }

    // MARK: - Snippet helpers

    /// Extracts and truncates a substring identified by an `NSRange`.
    ///
    /// `internal` for testability.
    nonisolated static func snippet(from text: String, nsRange: NSRange) -> String {
        guard
            nsRange.location != NSNotFound,
            let swiftRange = Range(nsRange, in: text)
        else { return "" }
        return snippet(String(text[swiftRange]))
    }

    /// Truncates a raw string to at most `max` visible characters.
    ///
    /// `internal` for testability.
    nonisolated static func snippet(_ raw: String, max: Int = 60) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}
