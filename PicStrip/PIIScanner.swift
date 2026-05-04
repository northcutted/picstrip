import Foundation
import Vision
import ImageIO

// MARK: - Errors

enum PIIScannerError: Error, LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Could not decode the provided data into a valid image."
        }
    }
}

// MARK: - Scanner

struct PIIScanner {

    func scanImage(data: Data) async throws -> [DetectionResult] {
        // Offload CPU-bound work off the calling thread.
        return try await Task.detached(priority: .userInitiated) {
            // Stage 1: Image conversion
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw PIIScannerError.invalidImageData
            }

            // Stage 2: OCR via Vision — returns raw observations, not joined text.
            let observations = try Self.recognizeText(in: cgImage)

            // Stage 3: Per-observation two-stage PII analysis with state tracking.
            return try Self.detectPII(in: observations)
        }.value
    }

    // MARK: - Private

    /// Runs Vision OCR and returns the raw observation array so that each
    /// observation's `boundingBox` is still available for spatial highlighting.
    private static func recognizeText(in cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Disable language correction so Vision preserves raw password characters
        // rather than autocorrecting them into dictionary words.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return request.results ?? []
    }

    /// Analyses each OCR observation individually, preserving bounding-box
    /// associations and tracking heuristic credential state across observations.
    private static func detectPII(
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

        // Build the NSDataDetector once and reuse it across all observations.
        let detectorTypes: NSTextCheckingTypes =
            NSTextCheckingResult.CheckingType.link.rawValue |
            NSTextCheckingResult.CheckingType.phoneNumber.rawValue |
            NSTextCheckingResult.CheckingType.address.rawValue
        let detector = try NSDataDetector(types: detectorTypes)

        // Orphan-label regex: matches an observation that IS a credential keyword
        // (possibly garbled by Vision) but has no value on the same line.
        // When we see this, we stash the label and treat the NEXT observation as
        // the password value — handling whiteboard splits across two text lines.
        let orphanLabelRegex = try NSRegularExpression(
            pattern: #"(?i)^[a-z0-9 ]{0,12}(?:login|log ?in|pass(?:word)?|pwd|user(?:name)?|cred(?:ential)?s?|ha[sś][łl]o|haslo|islo|iso|g?in|ogin|0g ?in|min)\s*[*•:.\-=]?\s*$"#
        )

        // Cross-observation state: non-nil when we have seen a bare credential
        // keyword and are waiting for the next observation to supply the value.
        var pendingCredentialLabel: String? = nil

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
                    record(rule.type,
                           baseScore: rule.baseScore,
                           ocrConfidence: ocrConfidence,
                           instance: DetectedInstance(snippet: snippet, boundingBox: box, score: 0))
                }
            }

            // ── Stage A: Native NSDataDetector ───────────────────────────────
            // Runs after the regex pass. For types also covered by a regex rule
            // (email), record() will not downgrade a stronger score already set.
            var stageAMatched = false
            detector.enumerateMatches(in: text, options: [], range: nsRange) { match, _, _ in
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

    // MARK: - Coordinate helpers

    /// Converts a Vision bottom-left-origin normalised rect to a SwiftUI
    /// top-left-origin normalised rect.
    private static func swiftUIBox(from visionBox: CGRect) -> CGRect {
        CGRect(
            x:      visionBox.origin.x,
            y:      1.0 - visionBox.origin.y - visionBox.height,
            width:  visionBox.width,
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
    private static func substringBox(
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
    private static func snippet(from text: String, nsRange: NSRange) -> String {
        guard
            nsRange.location != NSNotFound,
            let swiftRange = Range(nsRange, in: text)
        else { return "" }
        return snippet(String(text[swiftRange]))
    }

    /// Truncates a raw string to at most `max` visible characters.
    private static func snippet(_ raw: String, max: Int = 60) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}
