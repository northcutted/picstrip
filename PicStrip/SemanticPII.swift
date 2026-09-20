import CoreGraphics
import Foundation
import FoundationModels

// MARK: - SemanticPII

/// Finds sensitive content no pattern can describe — people's names — by
/// asking Apple's **on-device** language model about the text OCR recognised.
///
/// Privacy contract, which every change here must keep:
/// - Only `SystemLanguageModel` is used.  It runs on the device.  The Private
///   Cloud Compute model must never be used: it would send the text off the
///   device and void every "nothing leaves your phone" promise the app makes.
/// - Nothing is downloaded on the app's behalf.  The model exists only where the
///   user has turned Apple Intelligence on; everywhere else this finds nothing.
/// - Main app only.  The share extension's memory ceiling has no room for it.
///
/// A struct of closures so the merge logic is testable without the model.
nonisolated struct SemanticPII: Sendable {

    struct Name: Equatable, Sendable {
        /// Index into the lines that were passed in.
        let line: Int
        /// The name as the model read it; verified against the line before use.
        let text: String
    }

    /// Returns no names when the model is unavailable, refuses, or fails.
    var findNames: @Sendable (_ lines: [String]) async -> [Name]
    /// Loads the model ahead of the first scan.  A cold model takes several
    /// seconds to answer; a warm one about two.
    var prewarm: @Sendable () -> Void = { }

    static let unavailable = SemanticPII(findNames: { _ in [] })

    static let live = SemanticPII(
        findNames: { await OnDeviceNameFinder.findNames(in: $0) },
        prewarm: { OnDeviceNameFinder.prewarm() }
    )
}

// MARK: - Merging

nonisolated enum SemanticPIIMerger {

    /// Pattern specificity of "the model says this is a name": useful, but well
    /// below anything a checksum or a strict format backs up.
    static let nameBaseScore = 0.62

    /// Adds `names` to `results` as `.personName` instances.
    ///
    /// The model is never trusted with geometry, and not with text either: a
    /// finding is kept only if the line exists and really contains the name, so a
    /// hallucinated name cannot put a box on the image.
    static func merge(
        names: [SemanticPII.Name],
        lines: [ScannedLine],
        into results: [DetectionResult]
    ) -> [DetectionResult] {
        var instances: [DetectedInstance] = []
        for name in names {
            let text = name.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lines.indices.contains(name.line),
                  (2...60).contains(text.count),
                  text.contains(where: \.isLetter),
                  let box = lines[name.line].boundingBox(of: text)
            else { continue }

            let alreadyFound = instances.contains {
                $0.boundingBox.intersection(box).width > 0.5 * min($0.boundingBox.width, box.width)
                    && abs($0.boundingBox.midY - box.midY) < box.height / 2
            }
            guard !alreadyFound else { continue }

            let score = min(0.99, max(0.05, nameBaseScore * Double(lines[name.line].confidence)))
            instances.append(DetectedInstance(snippet: text, boundingBox: box, score: score))
        }
        guard !instances.isEmpty else { return results }

        let score = instances.map(\.score).max() ?? nameBaseScore
        let names = DetectionResult(type: .personName, score: score, instances: instances)
        return PIIScanner.sorted(results.filter { $0.type != .personName } + [names])
    }
}

// MARK: - On-device model

@Generable
nonisolated struct FoundNames {
    @Guide(description: "Every name of a real person found in the lines. Empty when there are none.")
    var names: [FoundName]
}

@Generable
nonisolated struct FoundName {
    @Guide(description: "The number of the line the name is on.")
    var line: Int
    @Guide(description: "The person's name, copied exactly as it is written on that line.")
    var name: String
}

nonisolated enum OnDeviceNameFinder {

    /// Lines per request, and how many requests at most.  Keeps each prompt well
    /// inside the model's context window and bounds the time a scan can take.
    static let linesPerRequest = 40
    static let maximumRequests = 3
    /// The name pass must never hold a scan — and the save waiting on it — for
    /// long.  Generous enough for one cold start; a prewarmed model needs a fraction.
    static let timeout: Duration = .seconds(12)

    static let instructions = """
        You find the names of real people in text that was recognised from a photo or screenshot. \
        Each input line starts with its number. Return every person's name exactly as it is written, \
        with the number of the line it is on. Include full names, first names and surnames of people. \
        Do not return company, product, app, place or street names, usernames, email addresses, \
        job titles, or labels of the user interface. If there are no people's names, return an empty list.
        """

    static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        return model.availability == .available && model.supportsLocale()
    }

    static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    static func findNames(in lines: [String]) async -> [SemanticPII.Name] {
        guard isAvailable, !lines.isEmpty else { return [] }

        return await withTaskGroup(of: [SemanticPII.Name]?.self) { group in
            group.addTask { await queryModel(lines: lines) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    private static func queryModel(lines: [String]) async -> [SemanticPII.Name] {
        var found: [SemanticPII.Name] = []
        let numbered = lines.enumerated().map { (index: $0.offset, text: $0.element) }
        let chunks = stride(from: 0, to: numbered.count, by: linesPerRequest)
            .prefix(maximumRequests)
            .map { Array(numbered[$0..<min($0 + linesPerRequest, numbered.count)]) }

        for chunk in chunks {
            guard !Task.isCancelled else { break }
            let prompt = chunk.map { "\($0.index): \($0.text)" }.joined(separator: "\n")
            // A fresh session per chunk: no transcript is carried over, so the
            // context never grows and nothing about one chunk lingers into the next.
            let session = LanguageModelSession(instructions: instructions)
            // A refusal (guardrails), an unsupported language or an overflowing
            // context all mean the same thing here: no names from this chunk.
            guard let response = try? await session.respond(
                to: prompt, generating: FoundNames.self, options: options
            ) else { continue }
            found += response.content.names.map { SemanticPII.Name(line: $0.line, text: $0.name) }
        }
        return found
    }

    /// Greedy sampling: the same image should give the same names every time.
    private static var options: GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600)
        #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: 600)
        #endif
    }
}
