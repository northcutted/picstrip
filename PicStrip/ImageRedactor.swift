import UIKit

// MARK: - ImageRedactor

/// Stateless service that burns black redaction boxes over detected PII regions.
///
/// The `DetectedInstance.boundingBox` values are normalised (0…1) with a
/// **top-left origin** (Y was already flipped in `PIIScanner`).  Multiplying
/// them by `image.size` — which is in UIKit *points* — maps them directly into
/// the `UIGraphicsImageRenderer` coordinate space, so the resulting black boxes
/// land on exactly the same pixels that the red highlight rectangles cover in the
/// SwiftUI overlay.
struct ImageRedactor {

    /// Burns opaque black rectangles over every supplied `DetectedInstance` and
    /// returns a new, flattened `UIImage`.
    ///
    /// - Parameters:
    ///   - image:     The source image.  Orientation is respected via
    ///                `imageRendererFormat`, which preserves the image's own scale
    ///                and colour space.
    ///   - instances: The PII bounding boxes to redact.
    /// - Returns: A new `UIImage` with all instances blacked out, or `nil` if the
    ///            renderer fails (extremely rare; only happens on severe memory pressure).
    func redact(image: UIImage, instances: [DetectedInstance]) async -> UIImage? {
        // Offload the renderer work off the calling actor.
        return await Task.detached(priority: .userInitiated) {
            let size   = image.size
            let format = image.imageRendererFormat   // preserves scale + colour space
            let renderer = UIGraphicsImageRenderer(size: size, format: format)

            return renderer.image { _ in
                // 1. Draw the original image at its natural size.
                image.draw(at: .zero)

                // 2. Stamp a filled black rectangle over each PII instance.
                UIColor.black.setFill()
                for instance in instances {
                    let box = instance.boundingBox
                    // boundingBox is normalised, top-left origin.
                    // Multiply by point size — the renderer's coordinate space.
                    let rect = CGRect(
                        x: box.minX   * size.width,
                        y: box.minY   * size.height,
                        width: box.width  * size.width,
                        height: box.height * size.height
                    )
                    UIRectFill(rect)
                }
            }
        }.value
    }
}
