import Foundation
import ImageIO

/// Admission happens from ImageIO headers before any full bitmap is decoded.
/// These are conservative product limits, not a claim about an OS memory ceiling.
nonisolated struct ImageResourceBudget: Sendable {
    let maximumPixels: Double
    let maximumBytes: Int

    // Nominal camera resolutions are rounded: 5712×4284 is 24.47 MP and
    // 4032×3024 is 12.19 MP. Admit those without forcing a smaller copy.
    static let editor = ImageResourceBudget(maximumPixels: 25_000_000, maximumBytes: 128 * 1_024 * 1_024)
    static let background = ImageResourceBudget(maximumPixels: 13_000_000, maximumBytes: 64 * 1_024 * 1_024)
    static let shareExtension = ImageResourceBudget(maximumPixels: 6_500_000, maximumBytes: 48 * 1_024 * 1_024)

    enum AdmissionError: LocalizedError {
        case invalidImage, fileTooLarge, resolutionTooLarge
        var errorDescription: String? {
            switch self {
            case .invalidImage: String(localized: "The selected item could not be loaded as image data.")
            case .fileTooLarge: String(localized: "This image file is too large to process safely. Choose a smaller file.")
            case .resolutionTooLarge: String(localized: "This image is too large for this workflow. Open it in PicStrip to choose a smaller copy.")
            }
        }
    }

    func validate(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw AdmissionError.fileTooLarge }
        guard let size = ImageProcessor.pixelSize(of: data), size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else { throw AdmissionError.invalidImage }
        guard size.width * size.height <= maximumPixels else { throw AdmissionError.resolutionTooLarge }
    }

    func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= maximumBytes else { throw AdmissionError.fileTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw AdmissionError.fileTooLarge }
        return data
    }

    /// Only called after an explicit user choice. Metadata is preserved for review.
    static func smallerCopy(_ data: Data, maximumPixels: Double = 12_000_000) throws -> Data {
        guard let size = ImageProcessor.pixelSize(of: data), size.width > 0, size.height > 0 else {
            throw AdmissionError.invalidImage
        }
        // Leave a small margin for ImageIO's integer rounding of both edges.
        let factor = min(1, sqrt(maximumPixels * 0.995 / (size.width * size.height)))
        let edge = floor(max(size.width, size.height) * factor)
        guard let image = ImageProcessor.downsampledUIImage(from: data, maxPixelDimension: edge) else {
            throw AdmissionError.invalidImage
        }
        return try ImageProcessor.process(image: image, sourceData: data, preset: .highQualityJPEG,
                                          config: StripConfig(categoryEnabled: [:], fieldOverrides: [:])).data
    }
}
