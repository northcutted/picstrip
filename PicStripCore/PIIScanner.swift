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

            // Stage 3: Per-observation two-stage PII analysis with state tracking.
            var results = try Self.detectPII(in: observations)

            // Stage 4: Append visual detections (faces, barcodes).
            results.append(contentsOf: Self.faceResults(from: faceRequest.results ?? []))
            results.append(contentsOf: Self.barcodeResults(from: barcodeRequest.results ?? []))

            // Stage 5: Document-region prioritisation — boost ID-like detections
            // whose bounding box falls inside a detected document quad.
            let documentRects: [CGRect] = (rectangleRequest.results ?? []).map { obs in
                Self.swiftUIBox(from: obs.boundingBox)
            }
            results = Self.applyDocumentBoost(results: results, documentRects: documentRects)

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

    nonisolated private static func detectPII(
        in observations: [VNRecognizedTextObservation]
    ) throws -> [DetectionResult] {

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
            baseScore: Double,
            ocrConfidence: Float,
            instance: DetectedInstance
        ) {
            let instanceScore = baseScore * Double(ocrConfidence)
            let scoredInstance = DetectedInstance(
                snippet: instance.snippet,
                boundingBox: instance.boundingBox,
                score: instanceScore
            )

            if var existing = resultsDict[type] {
                if !existing.instances.contains(scoredInstance) {
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

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }

            let text    = candidate.string
            let nsRange = NSRange(text.startIndex..., in: text)

            // ── OCR confidence for this observation ──────────────────────────
            // Vision's per-candidate confidence reflects how certain the OCR engine
            // is about the text recognition itself (0.0–1.0). We multiply each
            // rule's base score by this value so matches in sharp, well-lit text
            // score higher than the same pattern in blurry or rotated text.
            let ocrConfidence: Float = candidate.confidence

            // ── Coordinate conversion ────────────────────────────────────────
            // Vision's boundingBox is normalised (0…1) with a BOTTOM-LEFT origin.
            // We flip the Y axis here so stored boxes use SwiftUI's top-left system:
            //   flippedY = 1 - originY - height
            let visionBox  = observation.boundingBox
            let lineBounds = Self.swiftUIBox(from: visionBox)

            // ── Heuristic state tracker ──────────────────────────────────────
            // If we stashed a credential label from the previous observation,
            // treat this entire observation as the credential value.
            if let label = pendingCredentialLabel {
                pendingCredentialLabel = nil
                let snippet = Self.snippet(text, max: 60)
                // Base score 0.65: cross-observation heuristic; structurally weaker.
                record(.unstructuredCredential,
                       baseScore: 0.65,
                       ocrConfidence: ocrConfidence,
                       instance: DetectedInstance(snippet: "\(label) \(snippet)", boundingBox: lineBounds, score: 0))
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
                    var effectiveBaseScore = rule.baseScore
                    if rule.type == .creditCard, Self.passesLuhn(digits: snippet) {
                        effectiveBaseScore = min(0.99, rule.baseScore + 0.05)
                    }

                    record(rule.type,
                           baseScore: effectiveBaseScore,
                           ocrConfidence: ocrConfidence,
                           instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0))
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
                           instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0))
                case .address:
                    // Base 0.68: NLP + address grammar; context-dependent.
                    record(.address, baseScore: 0.68, ocrConfidence: ocrConfidence,
                           instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0))
                case .link:
                    if let url = match.url, url.scheme == "mailto" {
                        // Base 0.75 for mailto: links — lower than the regex (0.93)
                        // so a prior regex hit on the same email won't be downgraded.
                        record(.email, baseScore: 0.75, ocrConfidence: ocrConfidence,
                               instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0))
                    } else {
                        // Base 0.52: generic link — appears in many non-sensitive contexts.
                        record(.link, baseScore: 0.52, ocrConfidence: ocrConfidence,
                               instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0))
                    }
                default:
                    break
                }
            }

            // ── Orphan label check ───────────────────────────────────────────
            // If neither stage matched, check whether this observation is a bare
            // credential keyword with no accompanying value. If so, stash it so
            // the next observation is treated as the password.
            if !stageAMatched && !stageBMatched {
                if orphanLabelRegex.firstMatch(in: text, options: [], range: nsRange) != nil {
                    pendingCredentialLabel = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
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

    // MARK: - Visual detection helpers

    /// Maps `VNFaceObservation`s from the single-pass handler into one
    /// `DetectionResult`.  Face results carry a fixed score of 0.99 — the
    /// dedicated ML model is highly reliable and the result needs no
    /// OCR-confidence weighting.
    nonisolated static func faceResults(from observations: [VNFaceObservation]) -> [DetectionResult] {
        guard !observations.isEmpty else { return [] }
        let instances = observations.map { obs in
            DetectedInstance(
                snippet: String(localized: "Face detected"),
                boundingBox: swiftUIBox(from: obs.boundingBox),
                score: 0.99
            )
        }
        return [DetectionResult(type: .face, score: 0.99, instances: instances)]
    }

    /// Maps `VNBarcodeObservation`s from the single-pass handler into one
    /// `DetectionResult`.  The decoded payload is placed in the snippet.
    nonisolated static func barcodeResults(from observations: [VNBarcodeObservation]) -> [DetectionResult] {
        guard !observations.isEmpty else { return [] }
        var instances: [DetectedInstance] = []
        for obs in observations {
            let payload  = obs.payloadStringValue ?? String(localized: "Encoded barcode")
            let instance = DetectedInstance(
                snippet: snippet(payload, max: 60),
                boundingBox: swiftUIBox(from: obs.boundingBox),
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

    // MARK: - Luhn validation

    /// Validates a string of decimal digits against the Luhn checksum.  Used as a
    /// *confidence booster* for credit card matches (a Luhn-valid 16-digit string
    /// is much more likely a real card than a non-validating one).  Filtering by
    /// Luhn is intentionally avoided — OCR may corrupt a single digit on an
    /// otherwise-real card and we'd rather flag than miss.
    nonisolated static func passesLuhn(digits: String) -> Bool {
        let raw = digits.filter(\.isNumber)
        guard raw.count >= 12, raw.count <= 19 else { return false }
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
