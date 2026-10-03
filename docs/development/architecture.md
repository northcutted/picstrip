# App architecture

[Developer guide](../../DEVELOPMENT.md)

## Project Structure

| Location | Purpose |
| --- | --- |
| `PicStrip/` | SwiftUI app, imports, editor, review and intents |
| `PicStripCore/` | Shared scanning, metadata, redaction and export contracts |
| `PicStripShareExtension/` | Share-extension entry point and privacy declarations |
| `PicStripTests/`, `PicStripUITests/` | Unit regressions and native UI scenarios |
| `Tests/Fixtures/` | OCR fixture included in both test bundles |
| `PicStrip.xcodeproj/` | Targets, schemes and resource membership |
| `fastlane/` | Screenshot capture, localized store copy and reviewed artwork |
| `scripts/` | Localization audits, screenshot composition and platform launcher |
| `scripts/ci/` | App workflow policy, change classification and contract tests |
| `.github/ios-release.json` | App identity, toolchains, screenshot inventory and release policy |
| `.github/ios-release-platform.json` | Reviewed shared platform revision |
| `.github/workflows/` | App entry points for PR checks, release operations and screenshots |
| `docs/development/`, `docs/ci-cd/` | Maintained technical and operating guides |
| `docs/releases/` | Active release acceptance checklists |
| `docs/archive/` | Dated reviews and their preserved evidence |
| `PRIVACY.md`, `LICENSE` | Public privacy policy and license |

Run `make help` for local commands. `build/`, `.build/`, `qa-results/` and `node_modules/` hold ignored local outputs or dependencies.

## Architecture Overview

### Design Pattern: MVVM

```
┌─────────────────────────────────────────────────────┐
│  SwiftUI Views                                      │
│  ContentView · PreSaveReviewView · BatchConfigView  │
└───────────────────────┬─────────────────────────────┘
                        │ observes via @Observable
                        ▼
┌─────────────────────────────────────────────────────┐
│  ScrubberViewModel   @Observable @MainActor         │
│  ├─ selectedItem: PhotosPickerItem?                 │
│  ├─ inputImage: Image?                              │
│  ├─ sourceUIImage: UIImage?                         │
│  ├─ processedData: Data?                            │
│  ├─ outputFileFields: [MetadataField]               │
│  ├─ stripConfig: StripConfig                        │
│  ├─ detectionResults: [DetectionResult]             │
│  ├─ activeSheet: ActiveSheet?                       │
│  └─ processSinglePhoto() / processBatch()           │
└───────────────────────┬─────────────────────────────┘
                        │ calls (no coupling)
                        ▼
┌─────────────────────────────────────────────────────┐
│  Stateless Services                                 │
│  ├─ ImageProcessor  (enum, static methods)         │
│  ├─ PIIScanner      (struct, async)                 │
│  └─ ImageRedactor   (struct, async)                 │
└───────────────────────┬─────────────────────────────┘
                        │ uses
                        ▼
┌─────────────────────────────────────────────────────┐
│  Apple Frameworks                                   │
│  ImageIO · Vision · Photos · PhotosUI · AppIntents  │
│  VisionKit · AVFoundation · CoreGraphics · UIKit    │
│  SwiftUI                                            │
└─────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Stateless services (no instances) | Photo processing is a pure function of inputs; no mutable service state needed |
| Two-pass ImageIO | Single-pass re-encode still triggers iOS auto-synthesis of EXIF; two-pass defeats it |
| `ImageRequestHandler(data)` instead of a decoded `CGImage` | Preserves EXIF orientation so bounding boxes land on the correct pixels (covered by `testBoundingBoxesFollowEXIFOrientation`) |
| Downsampled UI previews | The app keeps full-resolution bytes for export, but decodes display/review previews to bounded images to reduce RAM |
| Off-main image processing | Metadata encode/decode, review preview generation, OCR, redaction rendering and every batch item run in `@concurrent` functions; the view model only publishes final state |
| Fail closed | Batch, the share extension and `StripMetadataIntent` never save or return an image when a requested strip or redaction step failed — an untouched original must not be presented as clean |
| Sequential batch processing | Prevents OOM by keeping peak memory at ~one image at a time |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | Eliminates `@MainActor` annotation noise on view-layer types |
| Static detector caches | Compiles regexes once and reuses the native `NSDataDetector` across scans |
| No history database | Session state stays in memory; protected temporary exports and extension handoffs use explicit expiry and cleanup |
| In-process `IntentRouter` | `StripImageIntent` runs in the foreground app process and asks the UI for the batch picker directly; the App Group is only used for the share extension's "Edit in PicStrip" file |

### Shared processing contract

`ScanCoverage` records each detector's completion independently of its findings. Interactive review keeps incomplete checks visible and requires an explicit acknowledgement; unattended visual-redaction paths reject them. `ExportPlan` captures format, metadata choices and selected regions, and `VerifiedExport` describes the actual encoded result. `AuditReport` exposes counts and field names only. These contracts are shared by the main app, batch, extension and metadata-only Shortcut where applicable.

`ImageResourceBudget` admits at most 25 MP / 128 MiB in the editor, 13 MP / 64 MiB in background work, and 6.5 MP / 48 MiB for extension visual processing. These limits accommodate nominal 24/12/6 MP camera dimensions. Explicit reduction targets remain 12/6 MP. They bound admission, not measured peak process memory.

Photo and live-camera overlay coordinates remain left-to-right pixel coordinates inside an RTL interface. Navigation and textual controls retain the user's layout direction. Do not let directional layout mirror selection borders, handles or pan coordinates independently of the bitmap.

---


## Data Flow

### Single-Photo Flow

```
User taps PhotosPicker
    ↓
ContentView.selectedItem.didSet → ScrubberViewModel.handleItemChange()
    ↓
ScrubberViewModel.ingest()  — the three jobs below start together; none waits for another
    ├─ Load: PhotosPickerItem → Data            (home screen shows "Processing…" after a beat)
    ├─ Preview:  ImageIO downsample → sourceUIImage → isProcessing = false, photo on screen
    ├─ Metadata: CGImageSource properties → allSourceMetadata → badges appear
    └─ Scan (@concurrent): PIIScanner.scan(data:hints:progress:)
          ├─ Vision text / faces / barcodes / document edges, one performAll pass
          │     each finished request → ScanStep.analysed(…) → ScanProgress → progress bar
          ├─ ScanStep.matchingPatterns → DetectionRegistry regex + NSDataDetector + context
          └─ published → isScanningPII = false, Save enabled
                └─ then, if Apple Intelligence is on: SemanticPII name pass (isFindingNames);
                   its names are appended, nothing waits on it
    ↓
User views metadata panel + live redaction preview
    ↓
User adjusts stripConfig (toggle categories, fields, PII types)
    ↓
User taps "Save to Photos" or "Share"
    ├─ Await in-flight OCR scan (prevents stale empty detection racing save)
    ├─ Prepare review bytes:
    │     Optional: ImageRedactor.redact() if redaction enabled
    │     ImageProcessor.process(image:sourceData:preset:config:)
    │     → processedData, processedPreviewUIImage, outputFileFields
    ├─ presentSheet(.preSave)
    └─ PreSaveReviewView shows format picker + stripped-field summary
    ↓
User taps "Save as New" / "Replace Original" / "Share"
    ├─ PhotoLibraryWriter.save(…)  (the only PhotoKit change block)
    ├─ Generate AuditReport JSON → FileManager.tmp
    └─ Dismiss sheet → home screen
```

### Batch-Photo Flow

```
User taps "Pick Multiple" (or Shortcut fires StripImageIntent)
    ↓
ContentView presents BatchConfigView (stripMetadata, redactPII, outputFormat, saveMode)
    ↓
ScrubberViewModel.processBatch(config)  →  runBatch(sources:config:save:)
    ├─ for each BatchSource (sequential — never concurrent):
    │     ├─ Load: PhotosPickerItem → Data
    │     ├─ processBatchItem(...)  ← @concurrent, off the main actor
    │     │     ├─ Scan: PIIScanner.scanImage(data:)
    │     │     ├─ Optional: ImageRedactor.redact()
    │     │     └─ Strip: ImageProcessor.process(...)
    │     │     (returns nil if any requested step fails → photo counted as failed, nothing saved)
    │     ├─ Save: PHPhotoLibrary.performChanges
    │     ├─ Append to batchReports only after Photos accepts the write
    │     └─ @MainActor progress update
    └─ Generate BatchAuditReport JSON (photoCount = saved, failedCount = not saved)
    ↓
BatchSummaryView shows saved and failed counts and the downloadable audit JSON
```

`runBatch` takes its photo sources and its saver as parameters, so unit tests drive the whole loop with in-memory data and never touch the picker or the photo library.

### Document Scan Flow

```
User chooses Document in the camera (`CameraView`)
    ↓
DocumentScanFlow.step(for: camera permission) → present / request access / explain denial
    ↓
DocumentScannerView (VNDocumentCameraViewController) → ScannedDocument, held in memory
   (Photo mode is the same flow with LiveCameraView → the camera's own bytes, without the document hint;
    CameraCaptureView → CapturedPages(photo:) is the fallback)
    ↓  (acted on in the cover's onDismiss — presenting a sheet mid-dismissal can drop it)
ScrubberViewModel.loadCaptured(CapturedPages)
    ├─ 1 page  → CapturedImageEncoder → loadData(_:)      (the single-photo flow above)
    └─ N pages → scannedBatchSources → BatchConfigView  (the batch flow above; no Save Mode)
```

`CapturedPages` is a count plus a `@Sendable (Int) async -> Data?` closure, so pages are encoded one at a time, tests need no camera, and a later in-app camera can feed the same path. The un-redacted capture is never written to the photo library; it is released when the batch state is cleared or the sheet is dismissed (`scannedBatchSources = []`). Captured pages have no library original, so `effectiveBatchConfig(_:)` forces `.saveAsNew`.

### Data Ownership

| Data | Owner | Lifetime |
|------|-------|----------|
| `sourceUIImage: UIImage?` | ScrubberViewModel | Downsampled display preview for the single-photo session |
| `processedData: Data?` | ScrubberViewModel | Set during pre-save prep; nil'd on dismiss |
| `processedPreviewUIImage: UIImage?` | ScrubberViewModel | Downsampled decoded preview of processed bytes; avoids repeated Data decoding |
| `detectionResults: [DetectionResult]` | ScrubberViewModel | Single-photo session |
| `pendingStrippedMetadata: StrippedMetadata?` | ScrubberViewModel | Single-photo session |
| `stripConfig: StripConfig` | ScrubberViewModel | Per-session; persists across format changes |
| `outputFileFields: [MetadataField]` | ScrubberViewModel | Set after each encode pass; after an encode it — not the config — decides what the review and audit call "removed" (`isRemoved(_:)`) |
| Audit JSON | `FileManager.default.temporaryDirectory` | Session; user can share/download; deleted after |

---


## Share Extension

### Architecture

```
ShareViewController (UIKit — UIViewController)
    │
    └─ UIHostingController<ExtensionConfigView>
           │
           └─ ExtensionConfigView (SwiftUI, private)
                  └─ observes ExtensionViewModel (@Observable)
                         phase: .configuring | .processing | .ready | .finished
```

`ExtensionViewModel` tracks configuring, processing, ready and finished states. `ShareViewController.runProcessingPipeline()` owns sequential work, cancellation and partial-result reporting.

### Processing Pipeline (Extension)

```
User taps "Process & Save to Photos"
    ↓
Request Photos add-only permission
    ↓
For each selected provider, sequentially:
    Resolve a concrete image type; prefer a file representation
    Apply encoded-byte and pixel limits
    If explicitly allowed, create a smaller copy when required
    ExportPipeline.clean → typed coverage → verified output
    Reject incomplete required visual checks
    PhotoLibraryWriter.save → per-item result
    ↓
Show completion or partial-result summary; support cancellation/retry
```

### Shared Core Without a Framework Target

iOS extensions are separate processes. An extension binary cannot dynamically link to the `.app` binary's code, so PicStrip keeps shared processing code in `PicStripCore/` and compiles those same source files into both targets. This avoids duplicate source files while also avoiding a new binary framework build phase.

`ExportFormat+AppEnum.swift` remains app-only because it imports `AppIntents`. The extension uses the shared `ExportPreset` directly.

### Extension resource limits

Extension memory limits depend on the device and OS; there is no universal safe peak. Visual processing admits up to 6.5 MP and 48 MiB of encoded input. Metadata-only processing uses the 13 MP background limit. Larger images require explicit consent to a smaller copy (6 MP visual / 12 MP metadata target), or the user can hand the original to the main app. Processing stays sequential and saves each output through `PhotoLibraryWriter` without accumulating decoded results. Profile the exact signed build on hardware before accepting these budgets.

---


## App Intent & Siri

### `StripImageIntent` — foreground, opens the picker

**File:** `PicStrip/StripImageIntent.swift`

```swift
struct StripImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Photos with PicStrip"
    static let supportedModes: IntentModes = .foreground(.immediate)   // replaces openAppWhenRun (deprecated iOS 26)

    @AppDependency private var router: IntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestBatchPicker()
        return .result()
    }
}
```

The intent runs in the foreground app process, so it talks to the UI through `IntentRouter` (`@Observable @MainActor`, registered with `AppDependencyManager` in `PicStripApp.init()`):

1. `perform()` sets `isBatchPickerRequested`.
2. `ContentView` observes it with `.onChange(..., initial: true)` — `initial` covers a cold launch, where the intent has already run before the view exists — presents the multi-photo picker and clears the request.

This replaced an App Group `UserDefaults` flag that was only read on a `scenePhase → .active` transition. Running the shortcut while PicStrip was already frontmost never produced that transition, so the flag went stale and opened the picker at some later, unrelated launch.

Siri phrase registered: `"Clean photos with PicStrip"`. Also appears in the Shortcuts app and Spotlight.

### `StripMetadataIntent` — background, files in → files out

**File:** `PicStrip/StripMetadataIntent.swift`

Takes `[IntentFile]` (`supportedContentTypes: [.image]`) plus an `ExportFormat`, strips metadata with `ImageProcessor`, and returns clean `[IntentFile]`s for the next Shortcuts step. `supportedModes = .background`; on iOS 27 it conforms to `LongRunningIntent` and runs inside `performBackgroundTask` so a large selection can outlast the normal intent time limit.

It is deliberately **metadata only** — no OCR (what previously exceeded the background memory ceiling) and no photo-library writes (a background intent cannot present the authorization prompt). It fails closed: one unreadable or undecodable file fails the whole run.

The `images` parameter declares `inputConnectionBehavior: .connectToPreviousIntentResult`. That is what makes it the action's *input*: without it Shortcuts never wires the previous action's output into the parameter and the intent runs with no images.

**Verified end to end in the iOS 27 simulator** (Shortcuts app, not just unit tests):

| Shortcut | Input | Result |
|----------|-------|--------|
| Select Photos → Strip Metadata from Images → Save to Photos | 2.8 MB HEIC with GPS, 32 EXIF keys, MakerApple | Saved HEIC holds only structural keys |
| Same | JPEGs with GPS/EXIF/IPTC | Saved JPEGs clean |
| Get Latest Photos → Strip Metadata from Images *as PNG* → Save to Photos | JPEG (Nikon, GPS, IPTC) | Saved PNG, no metadata |

`readData(of:)` prefers bounded reads from a security-scoped `fileURL`, then accepts inline data when no URL is available. Each verified output is written to a protected file with a neutral `PicStrip` filename and returned with `removedOnCompletion = true`. Failure removes earlier outputs; successful temporary outputs also have an expiry sweep.

Known quirks, none of them in PicStrip's code:

- **iOS 27 beta runtime (24A5355p) drops the Export Format choice.** The runner logs the chosen case but App Intents resolves the enum to `nil` (`AppEnum case "to-0.0" was not found`), so the intent runs with the default, *Match Original*. Metadata is still stripped — only the conversion is skipped. The release runtime (24A434) delivers the value correctly.
- In the simulator `performBackgroundTask` logs `BGTaskScheduler is not available on this platform` and then runs the work anyway.
- Still worth one pass on a physical device before release: `LongRunningIntent` scheduling and a large (50+) selection can only be exercised there.

---


## Persistence Model

| Data | Storage | Key | Scope |
|------|---------|-----|-------|
| "Edit in PicStrip" handoff | App Group `PendingEdits` directory | Neutral unique filename | 15-minute validity; oldest first, removed on consumption or cancellation |
| Audit JSON and Shortcut outputs | Temporary `PicStripExports` directory | Neutral unique filename | Cleanup after use/failure where applicable; one-hour expiry |

`PrivateFileStore` writes files with complete protection and excludes its directories from backups. Expired files are rejected and cleaned when the store is accessed; expiry is not a guaranteed background deletion timer. A pending handoff contains the selected original. Reports contain field names and counts, never removed values, OCR snippets or region coordinates. The app has no processing-history database and does not use `UserDefaults`, Core Data or SwiftData. See `PRIVACY.md` for user-selected exports and Photos retention.

---


## Privacy & Security

### PrivacyInfo.xcprivacy

Both the main app and share extension declare:

```xml
<key>NSPrivacyTracking</key><false/>
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyTrackingDomains</key><array/>
```

No developer data collection, analytics or third-party crash-reporting SDKs. User-selected exports and system services follow the privacy policy.

### Required-Reason APIs

| API category | Reason code | Why |
|-------------|-------------|-----|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1`, both targets | Container file metadata for bounded reads, expiry and oldest-first handoff consumption |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `3B52.1`, both targets | File-size checks for files explicitly selected by the user |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1`, app only | Elapsed time between live-camera frames, to throttle analysis and measure how fast the camera moves; not stored or transmitted |

Re-audit declarations when adding file, timing or other required-reason API use. The extension does not call the camera uptime API.

### Permissions

| Permission | Level | When |
|-----------|-------|------|
| `NSPhotoLibraryAddUsageDescription` | Add-only | Saving a new cleaned asset |
| `NSPhotoLibraryUsageDescription` | Read + write | "Replace Original" — needs read access to delete the source asset |
| `NSCameraUsageDescription` | Camera | First tap on "Camera" |
| `NSMicrophoneUsageDescription` | Microphone | First recording in Video mode |

The app defaults to `.addOnly` authorization. Users must explicitly grant read+write if they want "Replace Original."

### On-Device Processing Guarantee

```
UIImage(data:)          native iOS — no network
CGImageSourceCreateWithData  ImageIO — native iOS
RecognizeTextRequest    Vision — on-device model, no network
PIIScanner.liveScan     Vision on camera frames — in memory, never stored
SystemLanguageModel     FoundationModels — on-device only; never Private Cloud Compute
NSRegularExpression     Foundation — native iOS
UIGraphicsImageRenderer CoreGraphics — native iOS
CGImageDestinationCopyImageSource  ImageIO — native iOS
PHPhotoLibrary.performChanges       Photos — native iOS
```

PicStrip has no image-upload service. Apple's object-selection model can download only after explicit consent through `downloadObjectModelAndContinue()`. Selected Photos/file providers may download an image, and saving or sharing follows the user's chosen service and sync settings. Processing and detection remain on device; user-directed exports may leave it.

---


## Known Constraints

### Structural Metadata Cannot Be Stripped

The iOS JPEG/HEIC encoder unconditionally re-synthesises structural rendering fields regardless of what `CGImageDestinationCopyImageSource` is asked to omit. The UI marks these with a lock icon. Do not attempt to remove the two-pass logic in hopes of stripping them — it will not work and will introduce correctness regressions.

### Two-Pass Encoding Overhead

The two-pass strategy has encoding and memory costs that depend on format and image content. Preserve output-metadata verification when optimizing it. The [release-readiness measurements](../archive/releases/1.7.0/evidence/release-readiness-2026-09-27/device-export-benchmark.json) are synthetic, Debug, export-only measurements; they do not establish scanner latency or worst-case memory. Profile the signed candidate with representative photos.

### Share Extension Memory Ceiling

Keep extension work sequential and enforce the resource limits above before decoding. Encoded byte size alone does not bound bitmap memory, and the pixel limits still require real-device acceptance.

### OCR Language Correction Must Stay Disabled

`RecognizeTextRequest.usesLanguageCorrection = true` normalises OCR output toward dictionary words. For credentials (`AIzaSyD...`, `sk-live-...`, `AKIAIOSFODNN7EXAMPLE`) this destroys the pattern structure the regex rules depend on. It must remain `false`.

### Use `performAll`, Not the Variadic `perform`

`ImageRequestHandler.perform(a, b, c)` throws if *any* request fails, discarding the results of the ones that succeeded — rectangle detection failing on the simulator would take OCR down with it. `performAll` reports each request separately. The `.fast` OCR retry and the default-revision face retry each create a fresh handler.

### PhotoKit Change Blocks Live in `PhotoLibraryWriter` Only

`PHPhotoLibrary.performChanges` runs its block on PhotoKit's own serial queue. A closure written inside a `@MainActor` type — the view model, the share extension's view controller, anything in the app target, which is `MainActor` by default — is inferred `@MainActor`, and Swift 6 asserts that at run time: the app traps the moment PhotoKit calls the block. It compiles cleanly and no unit test sees it, because only a real save reaches PhotoKit. `PicStripCore/PhotoLibraryWriter.swift` is `nonisolated`, so its block is too. A SwiftLint rule (`photo_library_change_block`) fails the build if `performChanges` appears anywhere else, and `testSaveAsNewPhotoReachesThePhotoLibrary` (UI tests) does a real save on the simulator. The same trap applies to any framework callback that is not `@Sendable` and runs off the main thread.

### Batch Processing Must Remain Sequential

Concurrent batch processing would hold several decoded images and intermediate buffers at once. Keep sequential processing and per-item resource admission; file-backed outputs prevent earlier encoded results accumulating in the Shortcut process.

### The Language Model Is On-Device Only, and Not Trusted

`SemanticPII` uses `SystemLanguageModel` and nothing else. `PrivateCloudComputeLanguageModel` exists in the iOS 27 SDK and must never be used here: it would send recognised text off the device and void every on-device claim the app makes. The model's output is treated as a hint — `SemanticPIIMerger` keeps a name only if the line index exists and the line really contains that text, and takes the box from Vision's character geometry, so a hallucination cannot put a box on the image. Names are `isRedactedByDefault == false`; batch burns only default-redacted types, and batch and the share extension do not run the model at all. The pass runs *after* the scan has been published (`startNameScan`), so neither the editor nor a save ever waits for the model; its findings are added with `appendDetections`, which leaves every existing region — and the undo history — as the user has it. It is capped at 12 s and the model is prewarmed at launch (≈2 s warm, ≈6 s cold on the simulator). `PICSTRIP_DISABLE_NAME_DETECTION=1` switches it off for UI tests and screenshots, which must be deterministic.

### The Live Viewfinder Is Advisory

`PIIScanner.liveScan(in:)` runs on camera frames for the viewfinder only. It returns each finding's `PIIType` and box, and the boxes of every line of text it read — never the text itself. Only types that are `isRedactedByDefault` are shown, and the language-model name pass does not run. The captured photo is scanned again by the full pipeline, so nothing in the editor depends on what the viewfinder showed. Frames are never stored.

- **Pacing.** One pass at a time (`AnalysisThrottle`). The interval comes from `LiveAnalysisPacing`: 0.35 s on a cool phone, 0.6 s from thermal state `.fair`, and at least 1.5 × the last pass so a slow device never runs Vision back to back. Analysis pauses at `.serious` or `.critical`, and the status line says so. It uses accurate OCR — the fast model garbles the digits the pattern rules need (and reads nothing on the simulator) — so tune the interval, not the level, if a device runs hot. `OSSignposter` intervals "Live scan" and "Frame registration" (subsystem `com.northcutt.PicStrip`, category `LiveCamera`) measure both on a device; the frame size is logged once at debug level.
- **Motion.** Between passes, `FrameRegistration` (Vision translational image registration, about 15 Hz) measures how far the picture slid, and `LiveMotion` accumulates it. Findings are stored in that stabilised space and drawn at their position plus the offset, so boxes stay on their content while the phone moves and the pass's latency is hidden. Passes are skipped while the picture moves faster than 0.8 frame lengths per second, when OCR reads only blur. Zoom, rotation, interruptions and thermal pauses clear the findings and restart the measurement.
- **Stability.** `LiveDetectionTracker` matches each pass to the findings on screen by type and overlap, eases a moved box into place and keeps a missed one for two passes, faded, so the overlay neither swaps boxes between findings nor blinks when OCR misses a line.
- **Presentation.** Findings are outlined in their risk colour (`RiskLevel.color`, shared with the editor and About) and labelled with their type and match strength — the editor's `ConfidenceLevel.matchLabel`, never a percentage, because About promises the score is not a probability. The outline repeats the strength for findings that only get a badge: solid for strong, dashed for possible, dotted for tentative. The tracker smooths each finding's score across passes and changes its band only once the score is 0.03 past a boundary. Live frames read less cleanly than a still photo, so the editor's strength for the same finding may be higher; `LiveLabelLayout` keeps labels off other findings, the controls and, where it can, text. A toggle shows black boxes instead, as a preview of the result; the choice is not remembered, because PicStrip keeps no preferences. The status line above the shutter summarises what is in view and carries the VoiceOver label; VoiceOver announces a kind of finding when it comes into view.
- **Camera.** The back camera is a virtual device where there is one, started at the Camera app's 1× (`displayVideoZoomFactorMultiplier`), so close-ups switch to the macro-capable lens on their own. The same controls as Video mode (`CameraControls.swift`): the Camera app's lens buttons and pinch to zoom (the boxes are cleared when a pinch ends — they describe the old view), tap to focus and drag for exposure, the front camera, the flashlight, the Camera Control's zoom and exposure sliders, and the volume buttons or Camera Control (`onCameraCaptureEvent`) as a shutter. Session interruptions show "Camera paused"; a runtime error restarts the session.

If the capture session cannot be configured, `LiveCameraView` reports `.unavailable` and the system camera (`CameraCaptureView`) is presented instead. The simulator has no camera: launch with `PICSTRIP_LIVE_CAMERA_FIXTURE=<path to an image>` and the app opens the viewfinder on that still image (`LiveCameraFixture`), which `testLiveViewfinderNamesFindingsAndCaptures` uses. Faces and barcodes are not detected there — those Vision requests fail on the simulator — and focus, zoom, the flashlight and motion need a device.

### Video Mode Records at the Camera App's Quality

The camera (`CameraView`) has three modes, Video, Photo and Document, switched by `CameraModePicker` above the shutter; Photo is the live viewfinder above, and Document presents Apple's document scanner over an empty camera (the scanner needs the camera to itself) — cancelling it returns to the mode before. Video mode (`VideoCameraView`, `VideoCameraModel`, `VideoCaptureSession`) is a separate `AVCaptureSession` with an `AVCaptureMovieFileOutput` and no frame analysis, so nothing competes with the recording for power or heat. Home's Camera button opens it in Photo mode; the "Take a Photo" shortcut and the fixtures can open it in another (`ContentView.CameraRequest` — a `fullScreenCover(item:)`, because a flag set beside a separate mode is read before the mode lands).

- **Formats.** `VideoFormatCatalog` works on `VideoFormatTraits` — each 16:9 format's size, top frame rate, HLG support, enhanced-stabilisation support, binning and range — so choosing is unit-tested without a camera. It offers 4K and HD at 24, 30, 60 and 120 fps where a format reaches them, HDR where the format takes HLG BT.2020, and enhanced stabilisation (`cinematicExtendedEnhanced`) where it is supported; `nearest(to:)` keeps the resolution, then the nearest frame rate, then HDR and stabilisation, and `bestFormat(for:)` prefers unbinned, video-range, 8-bit-for-SDR formats with the lowest sufficient frame rate. Recording starts at 4K, 30 fps, HDR.
- **Encoding.** The format is set directly (`activeFormat`, both frame durations held at the chosen rate), with `automaticallyConfiguresCaptureDeviceForWideColor` off so the colour space follows the choice: HLG BT.2020 for HDR (Dolby Vision on iPhone), P3 otherwise. The movie output records HEVC; low-light noise reduction is on by default for movie outputs on iOS 27 and low-light boost is enabled where supported. At `systemPressureState` `.critical` the frame rate drops to 30 rather than the session stopping.
- **Sound.** Stereo (`multichannelAudioMode`) with wind-noise removal where the microphones support it; audio zoom (iOS 26.4) is on by default. Without microphone permission the session records video only, and the view says so.
- **Controls.** The Camera app's lens buttons (`lensLevels`: widest, each `virtualDeviceSwitchOverVideoZoomFactors` lens, and 2× from the main lens) and pinch to zoom; tap to focus, then a vertical drag for exposure bias (±2 stops); the torch; the front camera; volume buttons and Camera Control (`onCameraCaptureEvent`) to start and stop; and, where `session.supportsControls`, the Camera Control's own `AVCaptureSystemZoomSlider` and `AVCaptureSystemExposureBiasSlider` — PicStrip's controls fade while their overlay is full screen. The preview is stabilised like the recording (`previewOptimized`), and the movie connection takes the rotation coordinator's capture angle when recording starts.
- **Where it goes.** The recording is written to `PrivateFileStore.exports` and opens in the video cleaner as `VideoSource.recorded`, used in place and deleted with the screen like any copy. It is never saved to Photos as it is; closing the cleaner before a copy has been saved asks first, and the sheet cannot be swiped away meanwhile. A recording ended by the system (a call, a full disk) is kept if AVFoundation reports it finished; one under way when the camera closes is deleted.

The simulator has no camera: launch with `PICSTRIP_VIDEO_CAMERA_FIXTURE=<path to a movie>` and the camera opens in Video mode on the movie's first frame (`VideoCameraFixture`), with a typical back camera's choices; stopping hands over a copy of the movie. `testAVideoIsRecordedIntoTheEditor` uses it.

### One Library Button, Routed by What Is Picked

Home has three ways in: the Camera, Photos & Videos, and Files. Photos & Videos is one `PhotosPicker` for images and videos, any number, `.current` encoding; `LibrarySelection` (generic, unit-tested) sends one photo to the editor, one video to the video cleaner, several photos to the photo batch, and several videos — or photos with videos — to one batch. A Live Photo is a photo, though it carries a movie. Screenshots are a collection inside the system picker; the "Clean a Screenshot" shortcut still opens a picker filtered to them. Files accepts images and movies; a movie is copied into the protected store while its security scope lasts and opened as `VideoSource.imported`.

### Batches Take Videos Too

`processBatch` runs the photos first (`runBatch`, with `total` and `finishes: false` when videos follow), then the videos (`runVideoBatch`), with one progress count. Each video is copied into the protected store (`IncomingVideo`), cleaned by `VideoBatchCleaner` — the video editor's defaults with no review: faces blurred, text and codes solid, when "Redact Sensitive Visual Data" is on; the hidden details always removed — saved with `PhotoLibraryWriter.saveVideo(at:deleting:)` (replace mode deletes the original in the same change), and its temporary files deleted before the next. It fails closed like the photos. Stop cancels the video under way (`batchVideoTask`). The screen stays awake during a batch (`isIdleTimerDisabled`); running on in the background would need `BGContinuedProcessingTask` with the background-GPU entitlement, since the covers are drawn with Core Image on the GPU — not added yet.

### Sharing Presets Decide the Format and the First Selection

`SharingPurpose` (photo, screenshot, document) is guessed when an image loads — `SharingPurpose.detect`: a document-camera scan is a document, and iOS writes "Screenshot" into the EXIF user comment of its screenshots — and can be changed in the editor. It sets the export format (JPEG for everyday photos, PNG for text) and which findings are covered as soon as the scan finishes (`coversByDefault`; documents also cover names). Everything stays editable; the regions themselves are never rebuilt by a preset change.

### An Emoji Cover Always Sits on a Blur

`RedactionStyle.emoji` draws the region's emoji (`RedactionRegion.emoji`, so every face can have its own) at `EmojiCover.coverage` × the box's longer side, centred. Emoji are not opaque rectangles — round faces leave the box's corners bare, and shapes like 🙈 have gaps — so the region is first put through the blur pass at full strength (`scramblePass`, `passStrength`), and only then is the glyph drawn. If the blur cannot run, the box is painted solid before the emoji goes on. The editor's preview draws the glyph with the same `fontSize(for:covering:)`, so what is previewed is what is saved.

### Partial Covering Uses Word Geometry Where It Can

`DetectedInstance.partialBoundingBox` is the part of a card, phone, SSN or IBAN number before its last four characters, or of an email before its "@" (`PIIScanner.partialCoverRange`). Vision's `boundingBox(for:)` places whole words, not characters, so inside a single token ("6185551234", "alex@example.com") every sub-range gets the whole word's box. When Vision cannot separate the covered and kept parts, `estimatedPartialBox` splits the match by the glyphs' widths in the system font, plus a third of a character toward covering. Rescoring passes must use `withScore(_:)` so the partial box survives. The editor switches a region between its two boxes with undo (`setPartialCover`).

### Always Cover Is the One Thing Kept Between Launches

`AlwaysCoverList` stores the user's words and phrases in `Application Support/AlwaysCover.json` with complete file protection and `isExcludedFromBackup`, never in UserDefaults (the privacy manifest says PicStrip uses none) and never in the App Group, so the Share Extension cannot see it. `AlwaysCoverMatcher` finds whole-word, case- and accent-insensitive occurrences in `ScannedLine`s and reports them as `PIIType.alwaysCover` at a fixed 0.95. The editor adds them to each scan, re-checks the open photo when a term is added (`refreshAlwaysCover`, via `appendDetections`, which merges into an existing kind with unique region ids), batches wrap the scan closure, and the live camera passes the terms to `liveScan`.

### Video Cleaning Replaces Metadata, It Does Not Filter It

`VideoCleaner.clean` exports with `AVAssetExportPresetPassthrough`, so frames are copied, not re-encoded. Two AVFoundation behaviours shape it, both pinned by `VideoCleanerTests`: an **empty** `metadata` array is treated as "keep the source's metadata", and `AVMetadataItemFilter.forSharing()` removes the location but keeps make, model, software and dates. So the session always gets a non-empty list — a new random content identifier for a plain video, the pairing identifier for a Live Photo's video — plus the filter for track-level items, and the output is re-read: any location, device or date left fails the export and deletes the file. Picked videos are copied into `PrivateFileStore.exports` (`copy`, `reserve`) and deleted when the screen closes.

A Live Photo's motion is kept only when nothing is covered and the format is not PNG, because the motion is not redacted. `LivePhotoCleaner` loads the `PHLivePhoto` from the picker, cleans its `.pairedVideo` resource keeping `com.apple.quicktime.content.identifier`, writes that identifier back into the still's Apple maker note (key 17), and saves both resources in one creation request; if Photos refuses the pair, a still is saved and the user is told. This path needs a device to verify.

### Faces and Text in a Video Are Tracked, Then Covered per Frame

`VideoFaceScanner.scan` reads the video through `AVAssetReaderVideoCompositionOutput` with a plain composition (`AVVideoComposition.Configuration(for:)`) whose frame duration is `FaceTracking.sampleInterval` (0.1 s): the composition turns every frame upright — the space covers are drawn in — and hands back only the frames that are looked at. Each runs the photo face detector (`PIIScanner.makeFaceRequest`, with the same default-revision fallback); on the simulator the request is moved to the CPU, because the simulator's GPU cannot create the face model's inference context. The reading composition sets `sourceTrackIDForFrameTiming` to invalid: otherwise frames follow the video track and every frame comes back (90 frames for a 1.5 s 60 fps clip, not 15), and the loop also skips frames that come too soon. Every `FaceTracking.tileEvery` (3rd) look, faces are also looked for in four overlapping 60% tiles of the full-size frame, each cut out as its own image (`FrameShrinker.crop`) — not `regionOfInterest`, for which revision 3 reports boxes relative to the region and revision 4 relative to the whole frame (mixing them put covers on a bench in the device test) — that found three children 35 px tall in the background of a photo collage, and a face being kissed. Detections are merged by `FaceTracking.isSameFace`: a good overlap (IoU 0.45) or nearly the same centre, not one centre inside the other box, which merged two faces cheek to cheek. Faces are looked for in a copy scaled to `detectionLongSide` (1280 px) — on a test frame, detection was the same from 388 to 2173 pixels — with both face detectors where the OS has two: on a device, revision 4 dropped a face in a collage at full resolution that revision 3 found, and revision 3 missed others revision 4 found, so `FaceTracking.union` keeps each face either finds. Text is still read at full resolution. A few times a second the scanner hands the screen a `Glimpse` — the small registration frame with what was just found — which the scanning screen draws with the viewfinder's own `DetectionBox`, `DetectionBadge` and `ReadingLines` (shared in `DetectionOverlay.swift`), a sweeping scan line, and a status capsule like the viewfinder's. Opening a video: the picker asks for `preferredItemEncoding: .current`, since the default may convert HEVC to H.264 before handing it over, which was most of the wait; the handed-over file is moved, not copied, into `PrivateFileStore` (`adopt`); and the picker's `Progress` drives the opening screen. The face detector misses faces turned to the side, looking down or away, so each frame also runs `DetectHumanBodyPoseRequest`: `HeadEstimate.box` draws a square head around the nose, eyes and ears it places (sized by their spread and by the neck), and `HeadEstimate.merged` adds the heads that contain no detected face. This also keeps a cover on a dancer whose face stops being found mid-move, instead of leaving it where the face was last seen. Analysis waits while the thermal state is serious or critical. `FaceTracking` links the boxes into `FaceTrack`s greedily (overlap first, then distance within 1.5 face widths); a face unseen for more than `maximumGap` (2 s) starts a new track — linking too much only covers a little more, while a split leaves the face bare in the gap.

`FaceTrack.coverBox(at:)` is what keeps a cover on a face between samples: the box moves in a straight line between sightings (filling misses), is held for `hold` (1 s) before the first and after the last, and is padded 15% on three sides and 35% above (a face box starts at the eyebrows). `VideoFaceRedactor.render` draws, per frame, the photo blur at full strength over each box and, for an emoji cover, the glyph on top at `EmojiCover.coverage`; if the blur cannot be made the face is painted black. The same `AVVideoComposition(applyingFiltersTo:)` drives the preview and the export, and `VideoCleaner.clean(…, videoComposition:)` re-encodes through it (HEVC where the asset allows it) before the usual metadata check, which still fails closed. With nothing found, or with covering skipped, the passthrough path above is used.

Text, codes and Always Cover words are read in every fifth scanned frame (`FindingTracking.sampleInterval`, 0.5 s) by `PIIScanner.frameFindings` — the viewfinder's pass without faces, keeping snippets for the list. Between scanned frames, `FrameRegistration` on a 480-pixel copy (`FrameShrinker`) builds a `CameraPath` of how the picture slid. `FindingTrack.coverBox(at:path:)` carries each read along the path, blends the reads either side, holds 0.75 s at the ends, and pads by the text's height. The path is checked against what was read: a single step over a quarter of the frame is dropped, a carry over `CameraPath.maximumCarry` (20%) is not followed, and where carrying one read does not land on the next (`agrees`), that stretch falls back to a straight line between the reads. Matching tries both the carried and the last box, so a wrong path cannot split a track. A repeating pattern (a checkerboard) fools the registration; `VideoTextRedactionTests` use a non-repeating wall. Rows group tracks by type and normalised snippet (`FindingGroup`), so the same email seen twice is one switch; one style (solid by default, pixelate or blur) covers them all. Faces cannot be grouped the same way — there is no on-device face-identity API — so each face track is its own row, which a 2 s `maximumGap` keeps few.

The iOS 27 simulator cannot play *any* video composition in `AVPlayer` (even Apple's plain one fails with -12784), while exporting and `AVAssetImageGenerator` work. A preview item that fails therefore falls back to a covered still from the image generator, at the tapped face's middle sample — a failed composition shows nothing, never an uncovered face. On a device, playback with the covers is expected; that, HDR source video, and long videos are device checks. `VideoFaceRedactionTests` drive the scanner with a stand-in detector (the frame's yellow pixels) so the orientation, tracking and rendering checks do not depend on Vision recognising an emoji; one test runs real Vision on 🧑🏽, which it does find.

### Object Covers Follow Their Subject; the Timeline Times Every Cover and Sound Edit

"Add a Cover" pauses the preview and shows the frame at the playhead with the current covers drawn on it (`VideoCleanerModel.coveredFrame`), so the user draws around what is still showing. `VideoObjectFollower.follow` then runs Vision's `TrackObjectRequest` on 640-pixel upright frames from that moment to the end, and backwards in two-second stretches read forwards and followed in reverse; a subject is lost after three readings below 0.3 confidence. The result is a `FaceTrack` with `isDrawn`: padded 8% rather than like a face, no hold, but on for at least `minimumDrawnLength` (1 s) — the tracker can lose plain background at once, and the user drew it to cover something. Drawn covers are covered whatever the faces switch says, can be blur, solid or an emoji, and can be removed.

`EditorTimeline` is laid out like a video editor: a ruler, a strip of frames (`filmstrip`), and a labelled lane each for faces, text, objects and audio (with the sound's waveform, `VideoAudioEditor.levels`), every cover or sound edit a clip; the playhead (fed by a periodic time observer, or set to the still's time where the preview cannot play). Tapping or dragging moves the playhead (`scrub`); a selected face or drawn cover gets handles, and its range (`VideoCleanerModel.ranges`, passed to the plan as `FaceCoverage.range`) replaces the track's own: inside it the cover holds its first or last box beyond the sightings, outside it there is none. Text groups show on the timeline but are switched, not trimmed. Pinching zooms (`TimelineWindow`: down to two seconds across, anchored under the fingers); zoomed in, an overview bar shows and moves the part in view, the window follows the playhead as it plays, and a drag held within 28 pt of either edge carries on along the video. The filmstrip is tiles at the frames' own shape, each the nearest of about one frame a second (made once the editor is open), and the waveform has twenty readings a second, so both hold up zoomed in. Holding and dragging along the audio lane selects a stretch; on release the system edit menu (`UIEditMenuInteraction`, presented from a view that takes no touches) offers Bleep, Mute, Play and Select All, and tapping the selection brings it back. Each clip is a `Menu` with a primary action — tap selects, hold shows its row's options — because a `.contextMenu` inside a `List` row belongs to the whole row, and the first one in it opens wherever the row is held. A box drawn to cover an object can be moved, resized by its corner, set with Position & size, or added in the middle, as on a photo, before it is followed. The review sets the audio session to `.playback` (mode `.moviePlayback`) so the preview is heard with the Ring/Silent switch on silent, and deactivates it with `.notifyOthersOnDeactivation` when the screen closes.

### Sound Is Bleeped or Muted Through a Composition

An `AudioEdit` (bleep or mute, a time range) is applied by `VideoAudioEditor.edited`: the video and audio tracks are copied into an `AVMutableComposition`, and an `AVAudioMix` silences the original sound over every edited stretch (merged, padded 50 ms each side). Single `setVolume` points are blended into slow slides by the mixer — a mute measured as a gradual dip — so each stretch is spelled out as ramps: a 10 ms fade that ends before the stretch, flat zero across it, a fade back after. Bleeps also get a 1 kHz tone (`writeTone`, a `.caf` in the private store — `reserve` needs the real extension or AVFoundation cannot open it) laid end to end on a track of its own, with empty ranges between, since inserting into a track pushes later content along. The same edited asset and mix drive the preview item and the saved copy; with any sound edit the copy is encoded again (`VideoCleaner.clean(_:audioMix:…)`), since a mix cannot be applied to copied samples. Test movies with sound are written picture and sound separately and put together: one `AVAssetWriter` with both inputs stalls waiting on itself unless they are fed interleaved.

### Screenshots and the Camera From Shortcuts

`TakePhotoIntent` and `CleanScreenshotIntent` open the app (`.foreground(.immediate)`) and set flags on `IntentRouter`, like `StripImageIntent`; `ContentView` presents the live camera or a `PhotosPicker` filtered to `.screenshots`. "The latest screenshot" would need full photo-library access, which PicStrip never requests, so the picker — newest first — is as close as it gets.

### The Object-Selection Model Is Never Downloaded Unasked

Tap-to-redact uses `GenerateIterativeSegmentationRequest` (iOS 27), whose model is an asset the OS downloads from Apple on request (`assetStatus` / `downloadAssets()`); it cannot be bundled. It requires separate download consent. `ScrubberViewModel.selectObject(at:)` never calls `downloadModel` itself: a `.needsDownload` status raises the consent alert, and only `downloadObjectModelAndContinue()` — the alert's "Download" button — fetches it. Keep that property when touching this code; `ObjectSelectionFlowTests` pins it. Regions are rectangles, so the mask is reduced to its bounding box (`SegmentationMask.boundingBox`), and a mask covering almost the whole image is rejected as "the background".

### Marketing Screenshots Live in Git LFS

`fastlane/screenshots/processed/**/*.png` is tracked by Git LFS (`.gitattributes`). Run `git lfs install` once per clone — without it git stores the PNGs as ordinary blobs and the attribute does nothing, which is how the repository's pack grew to a gigabyte before September 2026. Building and testing the app never needs these files, so a clone without LFS still works. The release platform's packaging job checks out with `lfs: true` and rejects LFS pointer files, so any new workflow that reads the screenshots must do the same. Commits from before the conversion still carry the PNGs as blobs; shrinking that history would mean rewriting `main`.

### Captured Pages Are Encoded Lazily

A document scan is held as a `VNDocumentCameraScan` and each page is turned into bytes only when the pipeline asks for it. Extracting every page up front would hold one decoded bitmap per page (tens of megabytes each) for the life of the batch.

### Scans Get the Document Boost From a Hint, Not a Rectangle

The document camera crops to the page edges, so `DetectRectanglesRequest` rarely finds a quad inside a scan. `ScanHints.scannedDocument` supplies the boost instead: `ScannedDocument.pages` sets it, and `scan(data:hints:)` scores the whole frame as the document — using the image's real aspect ratio — without turning it into a redaction instance. Do not "fix" a missing rectangle by injecting a full-frame one: `applyDocumentContext` would turn it into a region and black out the whole page.

Release version analysis and its tests live in the pinned `ios-release-workflows` platform. Use the Release Prep summary for the candidate version; PicStrip does not maintain a second version calculator.
