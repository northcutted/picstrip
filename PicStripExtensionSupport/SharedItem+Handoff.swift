import Foundation

// MARK: - SharedItem + Handoff

extension SharedItem {

    struct Handoff {
        /// The protected App Group file the app opens next.
        let url: URL
        /// Whether the notification that opens PicStrip was posted; when it
        /// was not, the user has to open the app themselves.
        let isAnnounced: Bool
    }

    /// "Edit in PicStrip": the original, metadata and all, in the protected,
    /// expiring App Group handoff the app opens next — a photo's bytes, or a
    /// video copied as a file for the video cleaner — then the notification
    /// that opens it.  Nothing is left behind if the task is cancelled first.
    func handOff() async throws -> Handoff {
        guard let store = PrivateFileStore.handoffs else { throw CocoaError(.fileWriteUnknown) }
        let now = Date()
        let url: URL
        switch kind {
        case .video(let typeIdentifier):
            url = try await copyVideo(typeIdentifier: typeIdentifier, into: store, now: now)
        case .photo(let typeIdentifier):
            url = try store.write(try await loadPhotoData(typeIdentifier: typeIdentifier), extension: "data", now: now)
        }
        guard !Task.isCancelled else {
            store.remove(url)
            throw CancellationError()
        }
        let isAnnounced = await EditHandoffNotification.post(isVideo: isVideo, expires: now.addingTimeInterval(store.lifetime))
        return Handoff(url: url, isAnnounced: isAnnounced)
    }
}
