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
    var format: ExportFormat { self == .photo ? .jpeg : .png }
}

extension ScrubberViewModel {
    func loadDemo() async {
        guard let data = SamplePhoto.makeData() else { return }
        await loadData(data, isDemo: true)
    }

    /// Presets choose quality and remove metadata. Region positions and styles survive.
    func applySharingPurpose(_ purpose: SharingPurpose) {
        stripConfig = .default
        selectedExportFormat = purpose.format
        typesToRedact = Set(detectedPII.map(\.type).filter(\.isRedactedByDefault))
    }
}
