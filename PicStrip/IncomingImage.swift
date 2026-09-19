import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - IncomingImage

/// The untouched bytes of an image arriving by paste or drag and drop.
///
/// Importing as raw `Data` — never as `UIImage` — is the point: decoding and
/// re-encoding an incoming image would throw away the very metadata PicStrip
/// exists to show the user before stripping it.
nonisolated struct IncomingImage: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        // Files app, Photos, and other document providers hand over a file.
        FileRepresentation(importedContentType: .image) { received in
            IncomingImage(data: try Data(contentsOf: received.file))
        }
        // Safari, Messages, and the pasteboard hand over the bytes directly.
        DataRepresentation(importedContentType: .image) { data in
            IncomingImage(data: data)
        }
    }

    /// Reads a user-picked file off the main actor, holding its security scope
    /// only for the duration of the read.
    @concurrent
    static func read(securityScoped url: URL) async -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Paste

extension View {
    /// Accepts ⌘V / Edit ▸ Paste of an image anywhere in the view (hardware
    /// keyboards, iPad menu bar).  `pasteDestination` reached iOS in iOS 27; on
    /// earlier systems the on-screen `PasteButton` is the way in.
    @ViewBuilder
    func imagePasteDestination(_ action: @escaping ([IncomingImage]) -> Void) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            pasteDestination(for: IncomingImage.self, action: action)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Picker metadata

extension View {
    /// Tells the system photo picker to hand photos over with their location and
    /// caption metadata intact.
    ///
    /// iOS 27 lets an app ask the picker to strip those *before* delivery.
    /// PicStrip needs the opposite — it cannot show or audit what it never
    /// receives — so the choice is stated explicitly rather than left to the
    /// framework default.  Compiled out for SDKs that predate the API.
    @ViewBuilder
    func photosPickerKeepsMetadata() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27, *) {
            photosPickerMetadataOptions([])
        } else {
            self
        }
        #else
        self
        #endif
    }
}
