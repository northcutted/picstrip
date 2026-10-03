import UniformTypeIdentifiers

// MARK: - SharedItemKind

/// What a shared item is, from the types its item provider registered, sorted
/// the way the app's library picker sorts them: a Live Photo carries a movie
/// too, but it is a photo.
///
/// Each case keeps the concrete type to load.  Loading by an abstract type
/// such as `public.image` silently never calls back when the provider only
/// registered concrete ones, which Photos always does.  The registered types
/// are ordered by fidelity, so the first that fits is the best; asking the
/// provider rather than probing a fixed list also covers WebP, HEIF, TIFF,
/// GIF, AVIF, RAW and every movie format.
nonisolated enum SharedItemKind: Equatable, Sendable {
    case photo(typeIdentifier: String)
    case video(typeIdentifier: String)

    /// `nil` when the item is neither a photo nor a video.
    init?(registeredTypeIdentifiers identifiers: [String]) {
        let types = identifiers.map { (identifier: $0, type: UTType($0)) }
        if let image = types.first(where: { $0.type?.conforms(to: .image) == true }) {
            self = .photo(typeIdentifier: image.identifier)
        } else if !types.contains(where: { $0.type?.conforms(to: .livePhoto) == true }),
                  let movie = types.first(where: { $0.type?.conforms(to: .movie) == true }) {
            self = .video(typeIdentifier: movie.identifier)
        } else {
            return nil
        }
    }

    var isVideo: Bool {
        if case .video = self { true } else { false }
    }

    /// The extension a copy of a video of this type is written with: one
    /// `PrivateFileStore` keeps for videos, so the app opens the handoff as a
    /// video.  Other formats (3GPP, say) are written as `.mov`, a name
    /// AVFoundation opens any file of the MPEG-4 family under.
    static func videoFileExtension(for typeIdentifier: String) -> String {
        let preferred = UTType(typeIdentifier)?.preferredFilenameExtension?.lowercased() ?? "mov"
        return PrivateFileStore.videoExtensions.contains(preferred) ? preferred : "mov"
    }
}
