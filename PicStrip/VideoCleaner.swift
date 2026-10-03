import AVFoundation
import CoreTransferable
import ImageIO
import Photos
import UniformTypeIdentifiers

// MARK: - VideoCleaner

/// Removes the hidden details from a video without re-encoding it: where it was
/// filmed, the device and software, and the dates written into it.  The frames
/// are copied as they are — faces and text in a video stay visible.
nonisolated enum VideoCleaner {

    typealias Failure = VideoMetadataCleaner.Failure

    /// Every metadata item in the file, at the asset and the track level.
    static func findings(in url: URL) async throws -> [VideoFinding] {
        try await VideoMetadataCleaner.findings(in: url)
    }

    /// A random content identifier: the one metadata item a cleaned video keeps.
    static func newContentIdentifier() -> AVMetadataItem {
        VideoMetadataCleaner.newContentIdentifier()
    }

    /// What a metadata key describes; see `VideoMetadataCleaner.kind(ofKey:)`.
    static func kind(ofKey key: String) -> VideoFinding.Kind {
        VideoMetadataCleaner.kind(ofKey: key)
    }

    /// Writes a copy of `source` to `output` with no hidden details, except the
    /// items in `keeping` (a Live Photo's pairing identifier).  Fails closed: if
    /// a location, device or date survives, the copy is deleted and this throws.
    ///
    /// Without `videoComposition` the frames are copied as they are.  With one,
    /// they are drawn through it (faces covered) and encoded again, as HEVC
    /// where the video allows it.
    static func clean(
        _ source: URL,
        to output: URL,
        keeping: [AVMetadataItem] = [],
        videoComposition: AVVideoComposition? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await clean(
            AVURLAsset(url: source), audioMix: nil, to: output,
            keeping: keeping, videoComposition: videoComposition, progress: progress
        )
    }

    /// `clean` for an asset with its sound edited (`VideoAudioEditor`): `audioMix`
    /// silences the edited stretches, and the whole is encoded again — a mix
    /// cannot be applied to copied samples.
    static func clean(
        _ asset: AVAsset,
        audioMix: AVAudioMix?,
        to output: URL,
        keeping: [AVMetadataItem] = [],
        videoComposition: AVVideoComposition? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let copiesFrames = videoComposition == nil && audioMix == nil
        let preset = copiesFrames ? AVAssetExportPresetPassthrough : await reencodingPreset(for: asset)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure.cannotExport
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        VideoMetadataCleaner.applyPolicy(to: session, keeping: keeping)
        let type = VideoMetadataCleaner.fileType(for: session)
        let states = session.states(updateInterval: 0.25)
        let reporter = progress.map { report in
            Task {
                for await state in states {
                    if case .exporting(let exported) = state { report(exported.fractionCompleted) }
                }
            }
        }
        defer { reporter?.cancel() }
        try await session.export(to: output, as: type)
        try await VideoMetadataCleaner.verify(output)
    }

    /// HEVC at the best quality where the video can take it, else the best H.264.
    static func reencodingPreset(for asset: AVAsset) async -> String {
        let hevc = AVAssetExportPresetHEVCHighestQuality
        let supported = await AVAssetExportSession.compatibility(ofExportPreset: hevc, with: asset, outputFileType: .mov)
        return supported ? hevc : AVAssetExportPresetHighestQuality
    }
}

// MARK: - IncomingVideo

/// A video from the photo picker, copied into PicStrip's protected temporary
/// store for as long as it is open.
nonisolated struct IncomingVideo: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            return IncomingVideo(url: try PrivateFileStore.exports.adopt(received.file, extension: fileExtension))
        }
    }
}

// MARK: - LivePhotoCleaner

/// Keeps a Live Photo's motion: the paired video is cleaned like any other,
/// except for the identifier that pairs it with the still, which the still
/// gets back too.  The identifier is a random UUID; it says nothing about the
/// user, and without it Photos saves no Live Photo at all.
nonisolated enum LivePhotoCleaner {

    static let contentIdentifierKey = "17"

    /// The cleaned paired video, in the protected store.
    static func cleanPairedVideo(of livePhoto: PHLivePhoto) async throws -> (url: URL, identifier: String) {
        guard let resource = PHAssetResource.assetResources(for: livePhoto).first(where: { $0.type == .pairedVideo }) else {
            throw VideoCleaner.Failure.cannotExport
        }
        let original = try PrivateFileStore.exports.reserve(extension: "mov")
        defer { try? FileManager.default.removeItem(at: original) }
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: original, options: nil)

        let asset = AVURLAsset(url: original)
        let items = try await asset.load(.metadata)
        guard let identifierItem = items.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }),
              let identifier = try await identifierItem.load(.stringValue)
        else { throw VideoCleaner.Failure.cannotExport }

        let pairing = AVMutableMetadataItem()
        pairing.identifier = .quickTimeMetadataContentIdentifier
        pairing.value = identifier as NSString
        pairing.dataType = kCMMetadataBaseDataType_UTF8 as String

        let cleaned = try PrivateFileStore.exports.reserve(extension: "mov")
        try await VideoCleaner.clean(original, to: cleaned, keeping: [pairing])
        return (cleaned, identifier)
    }

    /// `photo` with the pairing identifier written back into its Apple maker
    /// note — the only field put back after cleaning.
    static func pairedStill(_ photo: Data, identifier: String) -> Data? {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: [contentIdentifierKey: identifier]
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
