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

// MARK: - TakePhotoIntent

/// Opens PicStrip's live camera — for the Action Button, Control Center (as a
/// shortcut) or Siri.  Foreground only: the camera is PicStrip's own view.
struct TakePhotoIntent: AppIntent {

    static let title: LocalizedStringResource = "Take a Photo with PicStrip"

    static let description = IntentDescription(
        LocalizedStringResource("Opens PicStrip's camera, which shows what it would cover before you take the photo."),
        categoryName: LocalizedStringResource("Privacy")
    )

    static let supportedModes: IntentModes = .foreground(.immediate)

    @AppDependency private var router: IntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestCamera()
        return .result()
    }
}

// MARK: - CleanScreenshotIntent

/// Opens PicStrip at the user's screenshots, the newest first.
///
/// The system photo picker, filtered to screenshots, rather than "the latest
/// screenshot": finding that would need access to the whole photo library,
/// which PicStrip never asks for.
struct CleanScreenshotIntent: AppIntent {

    static let title: LocalizedStringResource = "Clean a Screenshot with PicStrip"

    static let description = IntentDescription(
        LocalizedStringResource("Opens PicStrip at your screenshots so you can pick one to clean."),
        categoryName: LocalizedStringResource("Privacy")
    )

    static let supportedModes: IntentModes = .foreground(.immediate)

    @AppDependency private var router: IntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestScreenshotPicker()
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
        AppShortcut(
            intent: TakePhotoIntent(),
            phrases: [
                "Take a photo with \(.applicationName)",
                "Open the \(.applicationName) camera"
            ],
            shortTitle: "Take Photo",
            systemImageName: "camera"
        )
        AppShortcut(
            intent: CleanScreenshotIntent(),
            phrases: [
                "Clean a screenshot with \(.applicationName)",
                "Clean my screenshot with \(.applicationName)"
            ],
            shortTitle: "Clean Screenshot",
            systemImageName: "camera.viewfinder"
        )
    }
}
