import CoreGraphics
import Foundation

/// Recognizes a PEM block across OCR lines. Delimiters often lose hyphens or
/// confuse I/l/1, so geometry and surrounding base64 lines complete the region.
nonisolated enum PrivateKeyDetector {
    static func results(in source: [ScannedLine]) -> [DetectionResult] {
        let lines = source.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > min($0.boundingBox.height, $1.boundingBox.height) / 2 {
                return $0.boundingBox.minY < $1.boundingBox.minY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var covered: Set<Int> = []
        var instances: [DetectedInstance] = []
        for index in lines.indices where isBoundary(lines[index].text, begin: true) {
            var block = [index]
            var previous = index
            for next in lines.indices.dropFirst(index + 1).prefix(256) {
                guard follows(lines[next], after: lines[previous]) else { break }
                let ending = isBoundary(lines[next].text, begin: false)
                guard ending || isPayload(lines[next].text) else { break }
                block.append(next)
                previous = next
                if ending { break }
            }
            covered.formUnion(block)
            instances.append(instance(block.map { lines[$0] }))
        }

        // A clipped screenshot may retain only the END marker. Cover contiguous
        // payload above it instead of leaving the secret visible.
        for index in lines.indices where !covered.contains(index) && isBoundary(lines[index].text, begin: false) {
            var block = [index]
            var previous = index
            for prior in stride(from: index - 1, through: 0, by: -1).prefix(256) {
                guard isPayload(lines[prior].text), follows(lines[previous], after: lines[prior]) else { break }
                block.append(prior)
                previous = prior
            }
            instances.append(instance(block.map { lines[$0] }))
        }

        guard !instances.isEmpty else { return [] }
        return [DetectionResult(type: .genericPrivateKey, score: instances.map(\.score).max() ?? 0.8, instances: instances)]
    }

    private static func isBoundary(_ text: String, begin: Bool) -> Bool {
        let letters = text.uppercased().filter { $0.isLetter || $0 == "1" }
            .replacingOccurrences(of: "BEGLN", with: "BEGIN")
            .replacingOccurrences(of: "BEG1N", with: "BEGIN")
            .replacingOccurrences(of: "PRLVATE", with: "PRIVATE")
            .replacingOccurrences(of: "PR1VATE", with: "PRIVATE")
        return letters.hasPrefix(begin ? "BEGIN" : "END") && letters.hasSuffix("PRIVATEKEY")
    }

    private static func isPayload(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        if text.hasPrefix("Proc-Type:") || text.hasPrefix("DEK-Info:") { return true }
        guard compact.count >= 8,
              text.split(whereSeparator: \.isWhitespace).count <= max(2, compact.count / 20) else { return false }
        let base64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let valid = compact.unicodeScalars.filter { base64.contains($0) }.count
        return Double(valid) / Double(compact.unicodeScalars.count) >= 0.9
    }

    private static func follows(_ next: ScannedLine, after previous: ScannedLine) -> Bool {
        let gap = next.boundingBox.minY - previous.boundingBox.maxY
        let height = max(next.boundingBox.height, previous.boundingBox.height)
        let overlap = next.boundingBox.intersection(
            CGRect(x: previous.boundingBox.minX, y: next.boundingBox.minY, width: previous.boundingBox.width, height: next.boundingBox.height)
        ).width
        return gap >= -height / 2 && gap <= height * 3
            && overlap >= min(next.boundingBox.width, previous.boundingBox.width) * 0.3
    }

    private static func instance(_ lines: [ScannedLine]) -> DetectedInstance {
        let box = lines.reduce(CGRect.null) { $0.union($1.boundingBox) }
            .insetBy(dx: -0.004, dy: -0.003)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return DetectedInstance(
            snippet: String(localized: "Private key block"), boundingBox: box,
            score: 0.96 * Double(lines.map(\.confidence).min() ?? 0.8)
        )
    }
}
