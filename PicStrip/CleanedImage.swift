import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The share representation is the encoded output, never the original image or
/// an untyped Data payload. A preview does not change a payload's content type.
nonisolated struct CleanedImage: Transferable, Sendable {
    let data: Data
    let type: UTType

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image) else { return nil }
        self.data = data
        self.type = type
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .exportingCondition { $0.type == .png }
            .suggestedFileName("PicStrip.png")
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .exportingCondition { $0.type == .jpeg }
            .suggestedFileName("PicStrip.jpg")
        DataRepresentation(exportedContentType: .heic) { $0.data }
            .exportingCondition { $0.type == .heic }
            .suggestedFileName("PicStrip.heic")
        DataRepresentation(exportedContentType: .heif) { $0.data }
            .exportingCondition { $0.type == .heif }
            .suggestedFileName("PicStrip.heif")
        // Less common original formats retain their image UTI and real extension
        // via a protected file instead of falling back to generic bytes.
        FileRepresentation(exportedContentType: .image) { image in
            let url = try PrivateFileStore.exports.write(image.data, extension: image.type.preferredFilenameExtension ?? "data")
            return SentTransferredFile(url)
        }
        .exportingCondition { ![UTType.png, .jpeg, .heic, .heif].contains($0.type) }
    }
}
