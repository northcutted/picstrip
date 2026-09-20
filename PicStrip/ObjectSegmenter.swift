import CoreGraphics
import Foundation
import Vision

// MARK: - ObjectSelection

/// Tap an object to redact it.
///
/// Backed by Vision's iterative segmentation (iOS 27).  Its model is an asset
/// the *OS* downloads from Apple on request — it cannot be bundled with the
/// app — so nothing here ever starts that download by itself: the view model
/// asks the user first (see `ScrubberViewModel.selectObject(at:)`).  Only the
/// model travels; the photo is segmented on the device like everything else.
///
/// A struct of closures so the flow is testable without the model.
nonisolated struct ObjectSelection: Sendable {

    enum Availability: Equatable, Sendable {
        /// Older OS, or the model cannot run here.
        case unsupported
        /// Supported, but the OS has not downloaded the model yet.
        case needsDownload
        case ready
    }

    var availability: @Sendable () async -> Availability
    /// Asks the OS to download the model.  Only call with the user's consent.
    var downloadModel: @Sendable () async throws -> Void
    /// Bounding box (normalised, top-left origin) of the object under `point`
    /// (same space); `nil` when nothing distinct is there.
    var boundingBox: @Sendable (_ point: CGPoint, _ imageData: Data) async throws -> CGRect?

    static let unsupported = ObjectSelection(
        availability: { .unsupported },
        downloadModel: { },
        boundingBox: { _, _ in nil }
    )

    static var live: ObjectSelection {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            return ObjectSelection(
                availability: { await ObjectSegmenter.availability() },
                downloadModel: { try await ObjectSegmenter.downloadModel() },
                boundingBox: { try await ObjectSegmenter.boundingBox(ofObjectAt: $0, in: $1) }
            )
        }
        #endif
        return .unsupported
    }
}

// MARK: - Mask geometry

nonisolated enum SegmentationMask {

    /// Bounding box of the mask's foreground, normalised with a top-left origin.
    ///
    /// The mask is sampled on a grid of at most `maxSide` cells per edge — plenty
    /// for a rectangle, and it keeps a full-resolution mask from costing a
    /// full-resolution buffer.  Returns `nil` for an empty mask, and for one that
    /// covers almost the whole image: that is "the background", not an object.
    static func boundingBox(of mask: CGImage, threshold: UInt8 = 127, maxSide: Int = 256) -> CGRect? {
        let longest = max(mask.width, mask.height)
        guard longest > 0 else { return nil }
        let ratio = min(1, CGFloat(maxSide) / CGFloat(longest))
        let width = max(1, Int((CGFloat(mask.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(mask.height) * ratio).rounded()))

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] > threshold {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // Bitmap-context memory is top-row-first, so rows already count from the top.
        let box = CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
        guard box.width * box.height < 0.92 else { return nil }
        return box
    }
}

// MARK: - ObjectSegmenter (iOS 27)

#if compiler(>=6.4)
@available(iOS 27, *)
nonisolated enum ObjectSegmenter {

    static func availability() async -> ObjectSelection.Availability {
        let probe = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
        switch await probe.assetStatus {
        case .ready:    return .ready
        case .notReady: return .needsDownload
        case .error:    return .unsupported
        @unknown default: return .unsupported
        }
    }

    static func downloadModel() async throws {
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
        try await request.downloadAssets()
    }

    @concurrent
    static func boundingBox(ofObjectAt point: CGPoint, in imageData: Data) async throws -> CGRect? {
        // Vision's normalised space has a lower-left origin.
        let seed = NormalizedPoint(x: point.x, y: 1 - point.y)
        let request = GenerateIterativeSegmentationRequest(seedPoint: seed)
        request.qualityLevel = .balanced
        guard let observation = try await request.perform(on: imageData) else { return nil }
        return SegmentationMask.boundingBox(of: try observation.cgImage)
    }
}
#endif
