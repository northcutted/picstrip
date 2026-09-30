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
User taps "Scan Document"
    ↓
DocumentScanFlow.step(for: camera permission) → present / request access / explain denial
    ↓
DocumentScannerView (VNDocumentCameraViewController) → ScannedDocument, held in memory
   ("Take Photo" is the same flow with LiveCameraView → the camera's own bytes, without the document hint;
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
| `NSCameraUsageDescription` | Camera | First tap on "Take Photo" or "Scan Document" |

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
- **Presentation.** Findings are outlined in their risk colour (`RiskLevel.color`, shared with the editor and About) and labelled with their type; `LiveLabelLayout` keeps labels off other findings, the controls and, where it can, text. A toggle shows black boxes instead, as a preview of the result; the choice is not remembered, because PicStrip keeps no preferences. The status line above the shutter summarises what is in view and carries the VoiceOver label; VoiceOver announces a kind of finding when it comes into view.
- **Camera.** The back camera is a virtual device where there is one, started at the Camera app's 1× (`displayVideoZoomFactorMultiplier`), so close-ups switch to the macro-capable lens on their own. Tap to focus and expose, a 1×/2× zoom, the flashlight, and the volume buttons or Camera Control (`onCameraCaptureEvent`) as a shutter. Session interruptions show "Camera paused"; a runtime error restarts the session.

If the capture session cannot be configured, `LiveCameraView` reports `.unavailable` and the system camera (`CameraCaptureView`) is presented instead. The simulator has no camera: launch with `PICSTRIP_LIVE_CAMERA_FIXTURE=<path to an image>` and the app opens the viewfinder on that still image (`LiveCameraFixture`), which `testLiveViewfinderNamesFindingsAndCaptures` uses. Faces and barcodes are not detected there — those Vision requests fail on the simulator — and focus, zoom, the flashlight and motion need a device.

### The Object-Selection Model Is Never Downloaded Unasked

Tap-to-redact uses `GenerateIterativeSegmentationRequest` (iOS 27), whose model is an asset the OS downloads from Apple on request (`assetStatus` / `downloadAssets()`); it cannot be bundled. It requires separate download consent. `ScrubberViewModel.selectObject(at:)` never calls `downloadModel` itself: a `.needsDownload` status raises the consent alert, and only `downloadObjectModelAndContinue()` — the alert's "Download" button — fetches it. Keep that property when touching this code; `ObjectSelectionFlowTests` pins it. Regions are rectangles, so the mask is reduced to its bounding box (`SegmentationMask.boundingBox`), and a mask covering almost the whole image is rejected as "the background".

### Marketing Screenshots Live in Git LFS

`fastlane/screenshots/processed/**/*.png` is tracked by Git LFS (`.gitattributes`). Run `git lfs install` once per clone — without it git stores the PNGs as ordinary blobs and the attribute does nothing, which is how the repository's pack grew to a gigabyte before September 2026. Building and testing the app never needs these files, so a clone without LFS still works. The release platform's packaging job checks out with `lfs: true` and rejects LFS pointer files, so any new workflow that reads the screenshots must do the same. Commits from before the conversion still carry the PNGs as blobs; shrinking that history would mean rewriting `main`.

### Captured Pages Are Encoded Lazily

A document scan is held as a `VNDocumentCameraScan` and each page is turned into bytes only when the pipeline asks for it. Extracting every page up front would hold one decoded bitmap per page (tens of megabytes each) for the life of the batch.

### Scans Get the Document Boost From a Hint, Not a Rectangle

The document camera crops to the page edges, so `DetectRectanglesRequest` rarely finds a quad inside a scan. `ScanHints.scannedDocument` supplies the boost instead: `ScannedDocument.pages` sets it, and `scan(data:hints:)` scores the whole frame as the document — using the image's real aspect ratio — without turning it into a redaction instance. Do not "fix" a missing rectangle by injecting a full-frame one: `applyDocumentContext` would turn it into a region and black out the whole page.

Release version analysis and its tests live in the pinned `ios-release-workflows` platform. Use the Release Prep summary for the candidate version; PicStrip does not maintain a second version calculator.
