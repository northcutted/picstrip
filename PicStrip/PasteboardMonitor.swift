import Observation
import UIKit

// MARK: - PasteboardMonitor

/// Tracks whether the system pasteboard currently holds an image, so the home
/// screen only offers Paste when there is something to paste.
///
/// Only asks *whether* an image is present (`UIPasteboard.hasImages`), which
/// never shows the "Allow Paste" prompt and never reads the content — the
/// `PasteButton` remains the only thing that does.  A stale answer is harmless:
/// the system control validates the pasteboard itself before it enables.
@Observable
@MainActor
final class PasteboardMonitor {

    private(set) var hasImage = false

    private let probe: @Sendable () -> Bool

    /// - Parameter probe: Injected so tests never touch the real pasteboard.
    init(probe: @escaping @Sendable () -> Bool = { UIPasteboard.general.hasImages }) {
        self.probe = probe
    }

    /// Re-checks the pasteboard.  The probe runs off the main actor because
    /// `hasImages` can stall while Universal Clipboard resolves a remote item.
    func refresh() async {
        hasImage = await Self.run(probe)
    }

    @concurrent
    nonisolated private static func run(_ probe: @Sendable () -> Bool) async -> Bool {
        probe()
    }
}
