import UIKit
import Photos
import UniformTypeIdentifiers

/// Share Extension entry point.
///
/// Lifecycle:
///   1. iOS calls `viewDidLoad` — shows a spinner while working.
///   2. We load the first image attachment as `Data`.
///   3. `ImageProcessor.process` strips all metadata (`.matchSource` / `.default`).
///   4. The clean image is saved to the photo library.
///   5. A brief "Saved" confirmation is shown, then `extensionContext.completeRequest` dismisses.
class ShareViewController: UIViewController {

    // MARK: - UI

    private let stack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.alignment = .center
        s.spacing = 12
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.tintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 48),
            iv.heightAnchor.constraint(equalToConstant: 48),
        ])
        return iv
    }()

    private let label: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15, weight: .medium)
        l.textColor = .white
        l.textAlignment = .center
        return l
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Dark pill background — visible against any share sheet backdrop.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        view.layer.cornerRadius = 20
        view.clipsToBounds = true

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        showSpinner()
        processImage()
    }

    // MARK: - State helpers

    private func showSpinner() {
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .light)
        iconView.image = UIImage(systemName: "arrow.trianglehead.2.clockwise", withConfiguration: config)
        label.text = "Stripping metadata…"

        // Rotate the spinner icon continuously
        let rotation = CABasicAnimation(keyPath: "transform.rotation")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        iconView.layer.add(rotation, forKey: "spin")
    }

    private func showSuccess() {
        iconView.layer.removeAllAnimations()
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        iconView.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: config)
        iconView.tintColor = .systemGreen
        label.text = "Saved to Photos"
    }

    private func showError() {
        iconView.layer.removeAllAnimations()
        let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        iconView.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: config)
        iconView.tintColor = .systemRed
        label.text = "Something went wrong"
    }

    // MARK: - Pipeline

    private func processImage() {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            })
        else {
            Task { @MainActor in self.finishWithError() }
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
            guard let self, let data else {
                Task { @MainActor [weak self] in self?.finishWithError() }
                return
            }

            Task.detached(priority: .userInitiated) {
                do {
                    let result = try ImageProcessor.process(
                        data: data,
                        preset: .matchSource,
                        config: .default
                    )
                    await self.saveToPhotos(data: result.data)
                } catch {
                    await self.finishWithError()
                }
            }
        }
    }

    // MARK: - Save

    @MainActor
    private func saveToPhotos(data: Data) async {
        var saved = false
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    continuation.resume()
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: data, options: nil)
                }) { success, _ in
                    saved = success
                    continuation.resume()
                }
            }
        }
        if saved {
            finishWithSuccess()
        } else {
            finishWithError()
        }
    }

    // MARK: - Completion

    @MainActor
    private func finishWithSuccess() {
        showSuccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    @MainActor
    private func finishWithError() {
        showError()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.extensionContext?.cancelRequest(withError: NSError(
                domain: "northcutt.PicStrip.ShareExtension",
                code: 1
            ))
        }
    }
}
