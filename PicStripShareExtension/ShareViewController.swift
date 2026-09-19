import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - App Group constants

private enum AppGroup {
    static let identifier = "group.com.northcutt.PicStrip"
    static let pendingEditFilename = "pending-edit.data"
    static let urlScheme = "picstrip://edit-from-extension"

    static var pendingEditURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(pendingEditFilename)
    }
}

// MARK: - ExtensionViewModel

@Observable
@MainActor
final class ExtensionViewModel {
    enum Phase: Equatable { case configuring, processing, ready }
    var phase: Phase = .configuring
    var errorMessage: String?
    /// Human-readable description of the active processing operation.
    /// Set just before `phase` transitions to `.processing` so the spinner
    /// always reflects the actual destination (Photos vs. main app editor).
    var processingMessage: String = ""
}

// MARK: - ShareViewController
//
// Entry point for the Share / Action extension.
//
// Lifecycle:
//   1. iOS presents this view controller as a share sheet card.
//   2. We embed ExtensionConfigView — two toggles and two action buttons.
//   3. On "Process & Save" the pipeline saves a cleaned copy directly to Photos.
//   4. On "Edit in PicStrip" the pipeline writes processed data to the shared
//      app group container, shows a "Image Prepared" confirmation, then dismisses.
//      iOS Share Extensions cannot programmatically switch apps (NSExtensionContext
//      .open() is not supported from Share Extensions), so the user opens PicStrip
//      manually. The main app's scenePhase observer drains the pending file on the
//      next foreground transition.
//
// Memory discipline: each image's UIImage and Data are released between
// iterations.  Extensions are killed without warning above ~120 MB.

class ShareViewController: UIViewController {

    // MARK: - State

    private let viewModel = ExtensionViewModel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        view.layer.cornerRadius = 20
        view.clipsToBounds = true
        embedConfigView()
    }

    // MARK: - Embed SwiftUI config view

    private func embedConfigView() {
        let configView = ExtensionConfigView(
            itemCount: inputItemCount(),
            viewModel: viewModel,
            onProcess: { [weak self] stripMetadata, redactPII in
                self?.runProcessingPipeline(stripMetadata: stripMetadata, redactPII: redactPII, destination: .photos)
            },
            onEdit: { [weak self] stripMetadata, redactPII in
                self?.runProcessingPipeline(stripMetadata: stripMetadata, redactPII: redactPII, destination: .mainApp)
            },
            onComplete: { [weak self] in
                // "Done" from the ready state: job succeeded, complete normally.
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(
                    domain: "northcutt.PicStrip.ShareExtension",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Cancelled by user")]
                ))
            }
        )

        let host = UIHostingController(rootView: configView)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    // MARK: - Input helpers

    private func inputItemCount() -> Int {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return 0 }
        return items.flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            .count
    }

    // MARK: - Destination

    private enum ProcessingDestination {
        /// Save cleaned copies to the Photos library.
        case photos
        /// Write the first image to the app group container and open the main app editor.
        case mainApp
    }

    // MARK: - Processing pipeline

    private func runProcessingPipeline(
        stripMetadata: Bool,
        redactPII: Bool,
        destination: ProcessingDestination
    ) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            showErrorThenCancel(String(localized: "No input items found."))
            return
        }

        let providers = items
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        guard !providers.isEmpty else {
            showErrorThenCancel(String(localized: "No image attachments found."))
            return
        }

        // "Edit in PicStrip" only processes the first image — subsequent images
        // in a multi-select are ignored since the editor is single-image.
        let targetProviders: [NSItemProvider] = destination == .mainApp
            ? Array(providers.prefix(1))
            : providers

        viewModel.processingMessage = destination == .mainApp
            ? String(localized: "Preparing to open in PicStrip…")
            : String(localized: "Cleaning and saving to Photos…")
        viewModel.phase = .processing

        Task { [weak self] in
            await self?.process(
                targetProviders,
                stripMetadata: stripMetadata,
                redactPII: redactPII,
                destination: destination
            )
        }
    }

    /// Runs on the main actor so the (non-Sendable) item providers never leave
    /// it; only each image's `Data` crosses to the background in `clean`.
    private func process(
        _ providers: [NSItemProvider],
        stripMetadata: Bool,
        redactPII: Bool,
        destination: ProcessingDestination
    ) async {
        // ── Request Photos authorization (save path only) ──────────────────
        if destination == .photos {
            let authStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authStatus == .authorized || authStatus == .limited else {
                showErrorThenCancel(String(localized: "Photos access is needed to save cleaned images. Grant access in Settings > Privacy > Photos."))
                return
            }
        }

        var savedCount = 0
        var failedCount = 0

        // Sequential on purpose: one decoded image at a time keeps the extension
        // under its ~120 MB ceiling.
        for provider in providers {

            // ── Resolve best concrete type + load raw Data ────────────────
            // ── Scan, redact, strip — off the main actor ──────────────────
            // Fail closed: if a step the user asked for cannot run, skip the
            // image instead of saving the untouched original as "cleaned".
            guard let typeID = Self.bestTypeIdentifier(for: provider),
                  let rawData = await loadData(from: provider, typeIdentifier: typeID),
                  let finalData = await Self.clean(rawData, stripMetadata: stripMetadata, redactPII: redactPII)
            else {
                failedCount += 1
                continue
            }

            switch destination {
            case .photos:
                // ── Save cleaned image to Photos library ───────────────────
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: finalData, options: nil)
                    }
                    savedCount += 1
                } catch {
                    // Non-fatal: continue with the remaining images.
                    failedCount += 1
                }

            case .mainApp:
                // ── Write to app group container ───────────────────────────
                guard let destURL = AppGroup.pendingEditURL else {
                    failedCount += 1
                    continue
                }
                do {
                    try finalData.write(to: destURL, options: [.atomic, .completeFileProtection])
                    savedCount += 1
                } catch {
                    failedCount += 1
                }
            }
        }

        if savedCount == 0 {
            showErrorThenCancel(String(localized: "No images could be processed."))
        } else if failedCount > 0, destination == .photos {
            // Partial success: tell the user before dismissing so skipped
            // photos are never mistaken for cleaned ones.
            showNoticeThenComplete(
                String(localized: "Some photos could not be cleaned and were not saved.")
            )
        } else if destination == .mainApp {
            // Transition to the "ready" state so the user sees confirmation
            // that their image has been prepared before they dismiss and open
            // PicStrip manually.  iOS Share Extensions cannot programmatically
            // switch to another app — NSExtensionContext.open() is not supported
            // from Share Extensions — so we can only guide the user.
            viewModel.phase = .ready
        } else {
            // Completing with an empty array dismisses the extension
            // normally — Photos / the host app needs no return value
            // since we saved directly to the library.
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Cleaning (off the main actor)

    /// Scans, redacts, and strips one image.  Returns `nil` when a requested step
    /// fails or the result is not a decodable image.
    @concurrent
    nonisolated private static func clean(
        _ rawData: Data,
        stripMetadata: Bool,
        redactPII: Bool
    ) async -> Data? {
        // ── Optional PII scan + redaction ─────────────────────────────────
        var redactedImage: UIImage?
        if redactPII {
            guard let results = try? await PIIScanner().scanImage(data: rawData) else { return nil }
            let instances = results.flatMap(\.instances)
            if !instances.isEmpty {
                guard let uiImage = UIImage(data: rawData),
                      let redacted = await ImageRedactor().redact(image: uiImage, instances: instances)
                else { return nil }
                redactedImage = redacted
            }
        }

        // ── Re-encode only when stripping or redaction requires it ─────────
        let stripConfig: StripConfig = stripMetadata ? .allEnabled : StripConfig(
            categoryEnabled: [:], fieldOverrides: [:]
        )
        let finalData: Data
        if let redactedImage {
            let preset: ExportPreset = stripMetadata ? .losslessPNG : .matchSource
            guard let result = try? ImageProcessor.process(
                image: redactedImage, sourceData: rawData, preset: preset, config: stripConfig
            ) else { return nil }
            finalData = result.data
        } else if stripMetadata {
            guard let result = try? ImageProcessor.process(
                data: rawData, preset: .losslessPNG, config: stripConfig
            ) else { return nil }
            finalData = result.data
        } else {
            finalData = rawData
        }

        guard UIImage(data: finalData) != nil else { return nil }
        return finalData
    }

    // MARK: - UTI resolution

    /// Returns the most specific concrete image type the provider supports.
    ///
    /// `loadDataRepresentation(forTypeIdentifier:)` silently drops its callback
    /// when handed an abstract UTI like `"public.image"` if the provider only
    /// registers concrete types (which Photos always does).  Resolving to the
    /// concrete type first guarantees the callback fires.
    ///
    /// `registeredTypeIdentifiers` is ordered by fidelity, so the first image
    /// type is the provider's best representation.  Asking the provider what it
    /// actually registered (rather than probing a fixed JPEG/PNG/HEIC list) also
    /// covers WebP, HEIF, TIFF, GIF, AVIF, and RAW.  Returns `nil` when the
    /// provider has no image representation at all.
    nonisolated private static func bestTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
    }

    // MARK: - Load helper (continuation bridge)

    private func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Partial-success path

    /// Shows `message` for 2 s, then completes the request normally.  Used when
    /// some — but not all — images were saved.
    @MainActor
    private func showNoticeThenComplete(_ message: String) {
        viewModel.phase = .configuring
        viewModel.errorMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.viewModel.errorMessage = nil
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Error path

    /// Flips back to `.configuring`, shows a red error banner for 2 s,
    /// then cancels the extension.  The user sees the reason before dismissal.
    @MainActor
    private func showErrorThenCancel(_ message: String) {
        viewModel.phase = .configuring
        viewModel.errorMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.viewModel.errorMessage = nil
            self?.extensionContext?.cancelRequest(withError: NSError(
                domain: "northcutt.PicStrip.ShareExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }
}

// MARK: - ExtensionConfigView

private struct ExtensionConfigView: View {

    let itemCount: Int
    let viewModel: ExtensionViewModel
    let onProcess: (Bool, Bool) -> Void
    let onEdit: (Bool, Bool) -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var stripMetadata: Bool = true
    @State private var redactPII: Bool = true

    private var isProcessing: Bool { viewModel.phase == .processing }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .accessibilityHidden(true)

            switch viewModel.phase {
            case .processing: processingBody
            case .ready:      readyBody
            case .configuring: configBody
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: viewModel.phase)
    }

    // MARK: - Config form

    private var configBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo.badge.shield.checkmark")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean with PicStrip")
                        .font(.headline)
                    Text("^[\(itemCount) photo](inflect: true) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            Divider()

            VStack(spacing: 0) {
                Toggle("Strip Privacy Metadata", isOn: $stripMetadata)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .accessibilityHint("Removes location, camera, editing, and other private image metadata.")

                Divider()
                    .padding(.leading, 20)

                Toggle("Auto-Redact Sensitive Data", isOn: $redactPII)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .accessibilityHint("Scans visible text and faces on device and burns redaction boxes over likely sensitive data.")
            }

            Divider()
                .padding(.bottom, 20)

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }

            VStack(spacing: 10) {
                Button {
                    onProcess(stripMetadata, redactPII)
                } label: {
                    Label("Process & Save to Photos", systemImage: "checkmark.shield.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Cleans selected images on this device and saves new copies to Photos.")

                // "Edit in PicStrip" — only available for a single image since
                // the full editor is single-image.  When multiple images were
                // shared, only the first will be sent to the editor.
                Button {
                    onEdit(stripMetadata, redactPII)
                } label: {
                    Label("Edit in PicStrip", systemImage: "pencil.and.scribble")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("Opens the first selected image in the PicStrip editor for manual redaction.")

                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("Closes the PicStrip share extension without saving.")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Ready state (mainApp destination)

    private var readyBody: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Image Prepared")
                    .font(.title2.weight(.semibold))
                Text("Open PicStrip to edit it.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .accessibilityHint("Closes the extension. Open PicStrip to edit your prepared image.")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - Processing state

    private var processingBody: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            Text(viewModel.processingMessage)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.processingMessage)
    }
}
