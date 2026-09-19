import AppIntents
import Foundation

// MARK: - StripImageIntent

/// An App Intent that opens PicStrip directly to the multi-photo picker.
///
/// Why open-app instead of background processing:
///   - IntentFile coercion from "Select Photos" silently returns empty Data
///     (phasset:// URLs are not readable via IntentFile.data).
///   - Vision OCR in a background-launched App Intents process exceeds the
///     memory ceiling and is killed, producing an XPC error in Shortcuts.
///   - PHPhotoLibrary.requestAuthorization cannot present its dialog from a
///     background intent context ("could not be run with the current user interface").
///
/// With `supportedModes = .foreground(.immediate)` the intent runs in the
/// foreground app process.  The app opens, immediately presents the native
/// PhotosPicker (the same one behind "Select Multiple Photos"), and the existing
/// batch pipeline handles everything — metadata stripping, optional PII
/// redaction, save to Photos.
///
/// For unattended Shortcuts automations that only need metadata removed, see
/// `StripMetadataIntent`, which runs in the background and returns files.
///
/// Shortcuts usage:
///   Just add "Clean Photos with PicStrip" as a step. No variable wiring needed.
struct StripImageIntent: AppIntent {

    static let title: LocalizedStringResource = "Clean Photos with PicStrip"

    static let description = IntentDescription(
        LocalizedStringResource("Opens PicStrip so you can select photos to clean. Strips privacy metadata and optionally redacts sensitive content before saving cleaned copies to your Photos library."),
        categoryName: LocalizedStringResource("Privacy")
    )

    /// Bring the app to the foreground before `perform()` runs. All photo
    /// selection and processing happens in the full app context — no background
    /// process limitations.  (Replaces `openAppWhenRun`, deprecated in iOS 26.)
    static let supportedModes: IntentModes = .foreground(.immediate)

    @AppDependency private var router: IntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        // Same process as the UI, so ask it directly; ContentView presents the
        // batch photo picker as soon as it sees the request.
        router.requestBatchPicker()
        return .result()
    }
}

// MARK: - PicStripShortcuts

/// Registers "Clean Photos with PicStrip" as an App Shortcut so it appears
/// automatically in Spotlight search, the Shortcuts app, and Siri without
/// the user having to build it manually.
struct PicStripShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StripImageIntent(),
            phrases: [
                "Clean photos with \(.applicationName)",
                "Strip metadata with \(.applicationName)",
                "Remove metadata with \(.applicationName)",
                "Scrub photos with \(.applicationName)"
            ],
            shortTitle: "Clean Photos",
            systemImageName: "shield.checkmark"
        )
    }
}
