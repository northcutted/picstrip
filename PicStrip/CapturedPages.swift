import UIKit
import VisionKit

// MARK: - CapturedPages

/// Images captured inside the app, handed to the view model as encoded bytes.
///
/// Pages are produced one at a time, on demand: a twenty-page scan held as
/// decoded bitmaps would cost hundreds of megabytes, while the batch loop only
/// ever needs one page in memory.
///
/// A closure rather than a VisionKit type so the pipeline can be tested with
/// in-memory pages, and so any later capture source can feed the same path.
struct CapturedPages: Sendable {
    let count: Int
    /// What is known about every page (a document scan is a document edge to edge).
    var hints: ScanHints = .none
    /// Encoded bytes of the page at `index`; `nil` when it cannot be produced.
    let data: @Sendable (Int) async -> Data?
}

// MARK: - ScannedDocument

/// Holds a finished document-camera scan for as long as its pages are needed.
/// Releasing it (the view model drops its batch sources) releases the scan.
final class ScannedDocument {
    private let scan: VNDocumentCameraScan

    init(scan: VNDocumentCameraScan) {
        self.scan = scan
    }

    var pages: CapturedPages {
        CapturedPages(count: scan.pageCount, hints: .scannedDocument) { [self] index in
            await pageData(at: index)
        }
    }

    private func pageData(at index: Int) async -> Data? {
        guard index >= 0, index < scan.pageCount else { return nil }
        return await ScannedPageEncoder.encode(scan.imageOfPage(at: index))
    }
}

// MARK: - ScannedPageEncoder

nonisolated enum ScannedPageEncoder {

    /// Longest edge kept from a captured page.  Far above what text recognition
    /// needs, and it bounds memory should a device ever deliver larger pages.
    static let defaultMaxLongEdge: CGFloat = 4096

    /// Encodes a captured page as the bytes the rest of the pipeline works on.
    ///
    /// JPEG at high quality rather than PNG: a PNG of a full-resolution page
    /// takes about a second longer to write and is 10–30 MB, and JPEG carries
    /// the orientation tag that `ImageRequestHandler(data)` and ImageIO honour.
    /// The default export format is PNG, so a page is lossy-encoded at most once.
    @concurrent
    static func encode(_ image: UIImage, maxLongEdge: CGFloat = defaultMaxLongEdge) async -> Data? {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let longEdge = max(pixelSize.width, pixelSize.height)
        guard longEdge > maxLongEdge else {
            return image.jpegData(compressionQuality: 0.95)
        }

        let ratio = maxLongEdge / longEdge
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let target = CGSize(
            width: (pixelSize.width * ratio).rounded(.down),
            height: (pixelSize.height * ratio).rounded(.down)
        )
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.95)
    }
}
