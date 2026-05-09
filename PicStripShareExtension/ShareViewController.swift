import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - ExtensionViewModel

@Observable
final class ExtensionViewModel {
    enum Phase { case configuring, processing }
    var phase: Phase = .configuring
    var errorMessage: String?
}

// MARK: - ShareViewController
//
// Entry point for the Share / Action extension.
//
// Lifecycle:
//   1. iOS presents this view controller as a share sheet card.
//   2. We embed ExtensionConfigView — two toggles and a "Process & Save" button.
//   3. On tap the view transitions to a spinner while the sequential pipeline runs:
//        a. Request Photos .addOnly authorization.
//        b. Resolve the provider's best concrete image UTI (Photos only vends
//           concrete types; the abstract "public.image" causes silent callback drops).
//        c. Load raw Data, optionally redact PII, strip metadata.
//        d. Save the cleaned UIImage to the Photos library via PHPhotoLibrary.
//        e. Complete with empty returningItems — the extension dismisses normally.
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
                self?.runProcessingPipeline(stripMetadata: stripMetadata, redactPII: redactPII)
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

    // MARK: - Processing pipeline

    private func runProcessingPipeline(stripMetadata: Bool, redactPII: Bool) {
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

        viewModel.phase = .processing

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // ── Request Photos authorization ───────────────────────────────
            // .addOnly is sufficient — we only write a new asset, never read
            // or delete existing ones.  NSPhotoLibraryAddUsageDescription in
            // the extension's Info.plist covers this entitlement path.
            let authStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authStatus == .authorized || authStatus == .limited else {
                await MainActor.run {
                    self.showErrorThenCancel(String(localized: "Photos access is needed to save cleaned images. Grant access in Settings > Privacy > Photos."))
                }
                return
            }

            var savedCount = 0

            for provider in providers {

                // ── Resolve best concrete type ────────────────────────────
                let typeID = Self.bestTypeIdentifier(for: provider)

                // ── Load raw Data ─────────────────────────────────────────
                guard let rawData = await self.loadData(from: provider, typeIdentifier: typeID) else {
                    continue
                }

                // ── Optional PII scan + redaction ─────────────────────────
                var redactedImage: UIImage?
                if redactPII {
                    redactedImage = await self.redact(data: rawData)
                }

                // ── Re-encode only when stripping or redaction requires it ─
                let stripConfig: StripConfig = stripMetadata ? .allEnabled : StripConfig(
                    categoryEnabled: [:], fieldOverrides: [:]
                )
                let finalData: Data
                if let redactedImage {
                    let preset: ExportPreset = stripMetadata ? .losslessPNG : .matchSource
                    let result = try? ImageProcessor.process(
                        image: redactedImage,
                        sourceData: rawData,
                        preset: preset,
                        config: stripConfig
                    )
                    finalData = result?.data ?? rawData
                } else if stripMetadata {
                    let result = try? ImageProcessor.process(
                        data: rawData,
                        preset: .losslessPNG,
                        config: stripConfig
                    )
                    finalData = result?.data ?? rawData
                } else {
                    finalData = rawData
                }

                // ── Save cleaned image to Photos library ───────────────────
                guard UIImage(data: finalData) != nil else {
                    continue
                }

                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: finalData, options: nil)
                    }
                    savedCount += 1
                } catch {
                    // Non-fatal: log and continue with remaining images.
                }
            }

            let completedCount = savedCount
            await MainActor.run {
                if completedCount == 0 {
                    self.showErrorThenCancel(String(localized: "No images could be saved to your library."))
                } else {
                    // Completing with an empty array dismisses the extension
                    // normally — Photos / the host app needs no return value
                    // since we saved directly to the library.
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            }
        }
    }

    // MARK: - UTI resolution

    /// Returns the most specific concrete image type the provider supports.
    ///
    /// `loadDataRepresentation(forTypeIdentifier:)` silently drops its callback
    /// when handed an abstract UTI like `"public.image"` if the provider only
    /// registers concrete types (which Photos always does).  Resolving to the
    /// concrete type first guarantees the callback fires.
    nonisolated private static func bestTypeIdentifier(for provider: NSItemProvider) -> String {
        let preferredTypes: [String] = [
            UTType.jpeg.identifier,       // "public.jpeg"
            UTType.png.identifier,        // "public.png"
            UTType.heic.identifier,       // "public.heic"
            "com.apple.heic",             // legacy HEIC registration
            UTType.rawImage.identifier,   // "public.camera-raw-image"
            UTType.image.identifier      // "public.image" — abstract fallback
        ]
        return preferredTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
            ?? UTType.image.identifier
    }

    // MARK: - Load helper (continuation bridge)

    private func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Redaction helper

    private func redact(data: Data) async -> UIImage? {
        let results: [DetectionResult]
        do {
            results = try await PIIScanner().scanImage(data: data)
        } catch {
            return nil
        }

        let instances = results.flatMap(\.instances)
        guard !instances.isEmpty else { return nil }
        guard let uiImage = UIImage(data: data) else { return nil }

        return await ImageRedactor().redact(image: uiImage, instances: instances)
    }

    // MARK: - Error path

    /// Flips back to `.configuring`, shows a red error banner for 2 s,
    /// then cancels the extension.  The user sees the reason before dismissal.
    @MainActor
    private func showErrorThenCancel(_ message: String) {
        viewModel.phase = .configuring
        viewModel.errorMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
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

            if isProcessing {
                processingBody
            } else {
                configBody
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
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
                    .accessibilityHint("Scans visible text on device and burns redaction boxes over likely sensitive data.")
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

    // MARK: - Processing state

    private var processingBody: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            Text("Cleaning and saving to Photos…")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cleaning and saving to Photos")
    }
}
