import AVFoundation
import Foundation

// MARK: - VideoFinding

/// One piece of hidden information found in a video.
nonisolated struct VideoFinding: Identifiable, Hashable, Sendable {
    enum Kind: Int, Comparable, CaseIterable, Sendable {
        case location, device, date, other

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .location: String(localized: "Location")
            case .device: String(localized: "Device and software")
            case .date: String(localized: "Date recorded")
            case .other: String(localized: "Other details")
            }
        }

        var symbolName: String {
            switch self {
            case .location: "location.fill"
            case .device: "iphone.gen2"
            case .date: "calendar"
            case .other: "tag.fill"
            }
        }
    }

    let id: Int
    let kind: Kind
    let value: String
}

// MARK: - VideoMetadataCleaner

/// What a cleaned video keeps of its hidden details, and the check that
/// nothing identifying is left.  Shared by the app's video cleaner, the Share
/// Extension and the Shortcuts action, so a video gets the same treatment
/// wherever it is cleaned.  `clean` is the whole job when the frames are
/// copied as they are; `VideoCleaner` applies the same policy and check when
/// it covers faces and encodes the video again.
nonisolated enum VideoMetadataCleaner {

    enum Failure: LocalizedError {
        case cannotExport
        case detailsRemain

        var errorDescription: String? {
            switch self {
            case .cannotExport:
                String(localized: "This video could not be cleaned.")
            case .detailsRemain:
                String(localized: "Hidden details could not be removed from this video, so it was not kept.")
            }
        }
    }

    /// Every metadata item in the file, at the asset and the track level.
    static func findings(in url: URL) async throws -> [VideoFinding] {
        let asset = AVURLAsset(url: url)
        var items = try await asset.load(.metadata)
        for track in try await asset.load(.tracks) {
            items += try await track.load(.metadata)
        }
        var findings: [VideoFinding] = []
        for item in items {
            let key = item.identifier?.rawValue ?? ""
            var value = (try? await item.load(.stringValue)) ?? ""
            if value.isEmpty, let date = try? await item.load(.dateValue) {
                value = date.formatted(date: .abbreviated, time: .shortened)
            }
            findings.append(VideoFinding(id: findings.count, kind: kind(ofKey: key), value: value))
        }
        return findings.sorted { $0.kind < $1.kind }
    }

    /// A random content identifier: the one metadata item a cleaned video keeps.
    static func newContentIdentifier() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.value = UUID().uuidString as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// What a metadata key describes, from its identifier — QuickTime metadata
    /// (`mdta/com.apple.quicktime.location.ISO6709`) or user data (`udta/%A9xyz`).
    static func kind(ofKey key: String) -> VideoFinding.Kind {
        let key = key.lowercased()
        if key.contains("location") || key.contains("%a9xyz") || key.hasSuffix("/loci") { return .location }
        if [".make", ".model", ".software", "%a9mak", "%a9mod", "%a9swr", "%a9too"].contains(where: key.contains) { return .device }
        if key.contains("creationdate") || key.contains("%a9day") || key.hasSuffix(".date") { return .date }
        return .other
    }

    /// Sets what `session` writes: only the items in `keeping` (a Live Photo's
    /// pairing identifier), or a new random identifier, at the file level, and
    /// nothing identifying at the track level.
    static func applyPolicy(to session: AVAssetExportSession, keeping: [AVMetadataItem] = []) {
        // A non-empty list replaces the file's own metadata — an empty one is
        // read as "keep it all" — so a plain video gets a new random identifier,
        // tied to nothing.  The filter drops identifying items from the tracks.
        session.metadata = keeping.isEmpty ? [newContentIdentifier()] : keeping
        session.metadataItemFilter = .forSharing()
    }

    /// QuickTime where the session can write it, else what it can.
    static func fileType(for session: AVAssetExportSession) -> AVFileType {
        session.supportedFileTypes.contains(.mov) ? .mov : (session.supportedFileTypes.first ?? .mov)
    }

    /// Reads `output` back and fails closed: if a location, device or date
    /// survived, or the copy cannot be read, it is deleted and this throws.
    static func verify(_ output: URL) async throws {
        let left: [VideoFinding]
        do {
            left = try await findings(in: output).filter { $0.kind != .other }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        guard left.isEmpty else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.detailsRemain
        }
    }

    /// Writes a copy of `source` to `output` without its hidden details: the
    /// frames and sound are copied as they are, not encoded again, so faces and
    /// text stay visible.  Fails closed like `verify`; a failed export leaves no file.
    static func clean(_ source: URL, to output: URL, keeping: [AVMetadataItem] = []) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.cannotExport
        }
        applyPolicy(to: session, keeping: keeping)
        do {
            try await session.export(to: output, as: fileType(for: session))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        try await verify(output)
    }
}
