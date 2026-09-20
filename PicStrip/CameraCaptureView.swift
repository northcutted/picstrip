import AVFoundation
import SwiftUI
import UIKit

// MARK: - CameraHardware

nonisolated enum CameraHardware {
    /// Whether there is a camera to capture with.  The capture controllers'
    /// own availability checks are not enough: on the iOS 27 simulator they
    /// report `true` and then fail with "Unable to capture media".
    static var isPresent: Bool { AVCaptureDevice.default(for: .video) != nil }

    /// Set by UI tests to check the home-screen layout with every camera action present.
    static var isForcedForUITests: Bool {
        ProcessInfo.processInfo.environment["PICSTRIP_FORCE_SCAN_BUTTON"] == "1"
    }
}

// MARK: - CameraCaptureView

/// The system camera, for taking a photo straight into the editor.  The photo
/// comes back in memory and is never written to the photo library by PicStrip —
/// only the cleaned copy the user chooses to save is.
struct CameraCaptureView: UIViewControllerRepresentable {

    enum Outcome {
        case captured(UIImage)
        case cancelled
    }

    static var isAvailable: Bool {
        (UIImagePickerController.isSourceTypeAvailable(.camera) && CameraHardware.isPresent)
            || CameraHardware.isForcedForUITests
    }

    let onFinish: (Outcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (Outcome) -> Void

        init(onFinish: @escaping (Outcome) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onFinish(.captured(image))
            } else {
                onFinish(.cancelled)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(.cancelled)
        }
    }
}
