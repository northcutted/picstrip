import Photos

// MARK: - PhotoLibraryWriter

/// The one place PicStrip writes to the photo library.
///
/// PhotoKit runs a change block on its own serial queue.  A closure written
/// inside a `@MainActor` type is inferred `@MainActor`, and Swift 6 checks that
/// at run time — so a change block written in the view model or the share
/// extension's view controller traps the moment PhotoKit calls it.  Closures
/// formed here are `nonisolated`, which is what PhotoKit needs.  Keep every
/// `performChanges` call in this file.
nonisolated enum PhotoLibraryWriter {

    /// Adds `data` to the library as a new photo and, when `original` is given,
    /// deletes that asset in the same change (the system asks the user first).
    static func save(_ data: Data, deleting original: PHAsset? = nil) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            if let original {
                PHAssetChangeRequest.deleteAssets([original] as NSArray)
            }
        }
    }
}
