// MARK: - LibrarySelection

/// What was picked in the library, sorted into the flow that suits it: one
/// photo to the editor, one video to the video cleaner, several photos to the
/// photo batch, and several videos — or photos and videos together — to one
/// batch for all of them.  Generic so the routing is tested without the picker.
nonisolated struct LibrarySelection<Item> {

    enum Route {
        case photo(Item)
        case video(Item)
        case photoBatch([Item])
        /// Videos, with any photos picked alongside them, in one batch.
        case mixedBatch(photos: [Item], videos: [Item])
    }

    let photos: [Item]
    let videos: [Item]

    /// `items` in the order picked, each marked as a video or not.
    init(_ items: [(item: Item, isVideo: Bool)]) {
        photos = items.filter { !$0.isVideo }.map(\.item)
        videos = items.filter(\.isVideo).map(\.item)
    }

    var route: Route {
        switch (photos.count, videos.count) {
        case (1, 0): .photo(photos[0])
        case (_, 0): .photoBatch(photos)
        case (0, 1): .video(videos[0])
        default: .mixedBatch(photos: photos, videos: videos)
        }
    }
}
