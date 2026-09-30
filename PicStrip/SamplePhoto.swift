import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Generated locally from fictional details. It never reads the photo library.
enum SamplePhoto {
    static func makeData() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1500), format: format).image { context in
            UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1500))
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 75, y: 75, width: 1050, height: 1350), cornerRadius: 40).fill()
            func line(_ text: String, _ y: CGFloat, size: CGFloat = 34, bold: Bool = false) {
                (text as NSString).draw(in: CGRect(x: 125, y: y, width: 950, height: 160), withAttributes: [
                    .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                    .foregroundColor: UIColor(red: 0.10, green: 0.16, blue: 0.25, alpha: 1)
                ])
            }
            line("WEEKEND PLANS", 135, size: 58, bold: true)
            line("A fictional PicStrip sample", 225, size: 30)
            line("Reservation for Alex Example", 365, size: 40, bold: true)
            line("alex@example.com", 470, size: 42)
            line("+1 (202) 555-0147", 560, size: 42)
            line("Meet at the city garden", 750, size: 40, bold: true)
            line("Saturday, 10:30 AM", 830, size: 36)
            line("Bring a camera. Share the moment.", 1030, size: 36)
            line("Keep the contact details private.", 1110, size: 36)
            line("DEMO • NOT A REAL RESERVATION", 1290, size: 25, bold: true)
        }
        guard let cgImage = image.cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // Deliberately fictional coordinates and camera details demonstrate metadata removal.
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
                                           kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Fictional sample camera"]
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// What an image is being shared as.  Each purpose picks a format and which
/// findings are covered straight away; everything stays editable.
enum SharingPurpose: String, CaseIterable, Identifiable {
    case photo, screenshot, document
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photo: String(localized: "Everyday photo")
        case .screenshot: String(localized: "Screenshot")
        case .document: String(localized: "Document")
        }
    }

    /// What choosing it does, in one line.
    var summary: String {
        switch self {
        case .photo: String(localized: "A smaller JPEG. Covers what is found; names stay your choice.")
        case .screenshot: String(localized: "A sharp PNG for text. Covers what is found; names stay your choice.")
        case .document: String(localized: "A sharp PNG. Covers everything found, names included.")
        }
    }

    var symbolName: String {
        switch self {
        case .photo: "photo"
        case .screenshot: "camera.viewfinder"
        case .document: "doc.text"
        }
    }

    var format: ExportFormat { self == .photo ? .jpeg : .png }

    /// Whether findings of `type` are covered as soon as they are found.  On a
    /// letter or an ID the names are the point, so documents cover them too.
    func coversByDefault(_ type: PIIType) -> Bool {
        self == .document || type.isRedactedByDefault
    }

    /// The likeliest purpose for an image: a document-camera scan is a document,
    /// and iOS writes "Screenshot" into the EXIF user comment of its screenshots.
    nonisolated static func detect(properties: [CFString: Any]?, hints: ScanHints) -> SharingPurpose {
        if hints.wholeImageIsDocument { return .document }
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let comment = exif?[kCGImagePropertyExifUserComment] as? String,
           comment.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Screenshot") == .orderedSame {
            return .screenshot
        }
        return .photo
    }
}

extension ScrubberViewModel {
    func loadDemo() async {
        guard let data = SamplePhoto.makeData() else { return }
        await loadData(data, isDemo: true)
    }

    /// Presets choose quality and remove metadata. Region positions and styles survive.
    func applySharingPurpose(_ purpose: SharingPurpose) {
        stripConfig = .default
        sharingPurpose = purpose
        selectedExportFormat = purpose.format
        typesToRedact = Set(detectedPII.map(\.type).filter(purpose.coversByDefault))
    }
}
