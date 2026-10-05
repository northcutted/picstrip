import Observation
import StoreKit
import SwiftUI

// MARK: - ReviewPromptGate

/// When PicStrip may ask for an App Store rating, decided within one app session.
///
/// PicStrip keeps no preferences (see PrivacyInfo.xcprivacy), so there is no
/// launch count or save history to consult, and none is started for this: the
/// gate starts shut at every launch and is forgotten when the app quits.  It
/// opens only at a clean success — a cleaned copy saved to Photos, or a batch
/// that saved every item — once the session has seen PicStrip work more than once:
///
/// - the second clean success of the session, or
/// - a clean success once a second photo or video has been worked on (scanned
///   in the editor or the video screen, or saved by a batch).
///
/// So it never opens at launch or after a first save on its own.  A failure, a
/// warning or an incomplete scan sets both counts back to zero, so the request
/// never follows one.  It opens at most once per session; StoreKit then decides
/// whether to show anything (at most three times a year, never in TestFlight),
/// and that throttling — the system's, not PicStrip's — is the only memory
/// across launches.
nonisolated struct ReviewPromptGate: Equatable, Sendable {

    enum Event: Equatable, Sendable {
        /// A photo or video opened in PicStrip finished scanning, every required check complete.
        case scanned
        /// A cleaned copy from the editor or the video screen reached Photos, with no warning.
        case saved
        /// A batch saved every one of its `items`.
        case batchSaved(items: Int)
        /// A save, load or scan failed or warned, or a batch stopped or lost an item.
        case setback
    }

    /// Clean successes since the session began, or since the last setback.
    private(set) var successes = 0
    /// Photos and videos worked on since the session began, or since the last setback.
    private(set) var items = 0
    /// The session has had its one request.
    private(set) var hasOpened = false

    /// Records `event`; `true` exactly when this is the moment to ask.
    mutating func record(_ event: Event) -> Bool {
        switch event {
        case .scanned:
            items += 1
            return false
        case .setback:
            successes = 0
            items = 0
            return false
        case .saved:
            successes += 1
        case .batchSaved(let count):
            guard count > 0 else { return false }
            successes += 1
            items += count
        }
        guard !hasOpened, successes >= 2 || items >= 2 else { return false }
        hasOpened = true
        return true
    }
}

// MARK: - ReviewPrompt

/// The session's rating request: what happens goes in, and once the gate opens
/// the root view asks (`requestsReview(when:)`).  Owned by the app's one
/// `ScrubberViewModel`, so it lives exactly as long as the process.  Nothing in
/// it is stored or sent, and neither the Share Extension nor an App Intent ever
/// reaches it.
@Observable
final class ReviewPrompt {
    @ObservationIgnored private(set) var gate = ReviewPromptGate()
    /// Set when the gate opens, until the request has been made.
    private(set) var isDue = false

    func record(_ event: ReviewPromptGate.Event) {
        if gate.record(event) { isDue = true }
    }

    /// The request was made; the gate does not open again this session.
    func requested() {
        isDue = false
    }
}

// MARK: - Asking

extension View {
    /// Asks for a rating when `prompt` falls due — the one place PicStrip does.
    func requestsReview(when prompt: ReviewPrompt) -> some View {
        modifier(ReviewRequest(prompt: prompt))
    }
}

private struct ReviewRequest: ViewModifier {
    let prompt: ReviewPrompt
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content.task(id: prompt.isDue) {
            guard prompt.isDue else { return }
            // A beat for the success to land first: saving a photo closes the
            // review sheet and slides in its confirmation.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            requestReview()
            prompt.requested()
        }
    }
}
