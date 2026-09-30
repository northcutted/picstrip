import AVKit
import Photos
import PhotosUI
import SwiftUI

// MARK: - VideoCleanerView

/// Cleans a video picked from Photos: shows what hidden details it carried,
/// then saves or shares a copy without them.  The frames themselves are not
/// changed — the screen says so.
struct VideoCleanerView: View {
    let item: PhotosPickerItem

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.cleaning
    @State private var player: AVPlayer?
    @State private var saveState = SaveState.idle

    enum Phase {
        case cleaning
        case cleaned(Cleaned)
        case failed(String)
    }

    struct Cleaned {
        let source: URL
        let output: URL
        /// Location, device and date findings from the original — all gone from the copy.
        let removed: [VideoFinding]
        /// Whether the original's other metadata is gone from the copy too.
        let removedOther: Bool
    }

    enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .cleaning:
                    ProgressView("Cleaning video…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .cleaned(let cleaned):
                    cleanedView(cleaned)
                case .failed(let message):
                    ContentUnavailableView("Could not clean this video", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .navigationTitle("Clean Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("videoDoneButton")
                }
            }
        }
        .task { await clean() }
        .onDisappear(perform: discardFiles)
    }

    // MARK: Cleaned

    private func cleanedView(_ cleaned: Cleaned) -> some View {
        List {
            Section {
                VideoPlayer(player: player)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel("Cleaned video")
            }

            Section {
                let kinds = Dictionary(grouping: cleaned.removed, by: \.kind)
                if kinds.isEmpty && !cleaned.removedOther {
                    Label("No hidden details found", systemImage: "checkmark.seal")
                } else {
                    ForEach(VideoFinding.Kind.allCases.filter { kinds[$0] != nil && $0 != .other }, id: \.self) { kind in
                        removedRow(kind, values: kinds[kind]?.map(\.value) ?? [])
                    }
                    if cleaned.removedOther, kinds[.other] != nil {
                        removedRow(.other, values: [])
                    }
                }
            } header: {
                Text("Removed from the copy")
            }

            Section {
                Label("Faces and text in the video stay visible: PicStrip removes hidden details only.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                ShareLink(item: cleaned.output, preview: SharePreview("Cleaned video", image: Image(systemName: "video"))) {
                    Label("Share cleaned video", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("shareCleanedVideoButton")

                Button {
                    Task { await save(cleaned.output) }
                } label: {
                    Group {
                        switch saveState {
                        case .saving: ProgressView()
                        case .saved: Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                        default: Label("Save as New Video", systemImage: "plus.square.on.square")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(saveState == .saving || saveState == .saved)
                .accessibilityIdentifier("saveCleanedVideoButton")

                if case .failed(let message) = saveState {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func removedRow(_ kind: VideoFinding.Kind, values: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                let shown = values.map(Self.readable).filter { !$0.isEmpty }
                if !shown.isEmpty {
                    Text(shown.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Removed")
        }
        .accessibilityElement(children: .combine)
    }

    /// An ISO 6709 location ("+41.8781-087.6298+180.000/") as "41.8781, -87.6298".
    static func readable(_ value: String) -> String {
        let pattern = /^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)/
        guard let match = value.firstMatch(of: pattern),
              let latitude = Double(match.1), let longitude = Double(match.2)
        else { return value }
        return "\(latitude.formatted(.number.precision(.fractionLength(0...4)))), \(longitude.formatted(.number.precision(.fractionLength(0...4))))"
    }

    // MARK: Work

    private func clean() async {
        do {
            guard let video = try await item.loadTransferable(type: IncomingVideo.self) else {
                throw VideoCleaner.Failure.cannotExport
            }
            let found = try await VideoCleaner.findings(in: video.url)
            let output = try PrivateFileStore.exports.reserve(extension: "mov")
            try await VideoCleaner.clean(video.url, to: output)
            let otherLeft = try await VideoCleaner.findings(in: output).contains { $0.kind == .other }
            player = AVPlayer(url: output)
            phase = .cleaned(Cleaned(
                source: video.url, output: output,
                removed: found.filter { $0.kind != .other } + found.filter { $0.kind == .other }.prefix(1),
                removedOther: !otherLeft
            ))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save(_ url: URL) async {
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed(String(localized: "Photo library access was denied. Please enable it in Settings."))
            return
        }
        do {
            try await PhotoLibraryWriter.saveVideo(at: url)
            saveState = .saved
        } catch {
            saveState = .failed(String(localized: "Could not save to Photos: \(error.localizedDescription)"))
        }
    }

    /// Neither the copied original nor the cleaned copy outlives the screen.
    private func discardFiles() {
        player?.pause()
        if case .cleaned(let cleaned) = phase {
            PrivateFileStore.exports.remove(cleaned.source)
            PrivateFileStore.exports.remove(cleaned.output)
        }
    }
}
