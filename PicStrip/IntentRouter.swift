import Observation

// MARK: - IntentRouter

/// In-process hand-off from App Intents to the SwiftUI scene.
///
/// `StripImageIntent` runs in the foreground app process, so it can tell the UI
/// what to do directly.  The previous design wrote a flag to the App Group's
/// `UserDefaults` and waited for the next `scenePhase == .active` transition to
/// read it — which never comes when the shortcut fires while PicStrip is already
/// frontmost, leaving a stale flag that opened the picker at some later,
/// unrelated launch.
///
/// Registered with `AppDependencyManager` in `PicStripApp.init()`.
@Observable
@MainActor
final class IntentRouter {

    /// `true` while an intent is waiting for the multi-photo picker to open.
    ///
    /// A pending flag (rather than a fire-and-forget event) because on a cold
    /// launch the intent can run before `ContentView` exists; the view picks the
    /// request up when it appears.
    private(set) var isBatchPickerRequested = false

    func requestBatchPicker() {
        isBatchPickerRequested = true
    }

    /// Called by the view once it has presented the picker.
    func batchPickerPresented() {
        isBatchPickerRequested = false
    }
}
