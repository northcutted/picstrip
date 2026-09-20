import AVFoundation
import SwiftUI
import VisionKit

// MARK: - DocumentScannerView

/// The system document camera.  The scan is handed back in memory and goes
/// straight into the detect → redact → export pipeline; PicStrip never saves
/// the un-redacted capture to the photo library.
struct DocumentScannerView: UIViewControllerRepresentable {

    enum Outcome {
        case scanned(ScannedDocument)
        case cancelled
        case failed
    }

    static var isAvailable: Bool {
        (VNDocumentCameraViewController.isSupported && CameraHardware.isPresent)
            || CameraHardware.isForcedForUITests
    }

    let onFinish: (Outcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) { }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: (Outcome) -> Void

        init(onFinish: @escaping (Outcome) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            onFinish(scan.pageCount > 0 ? .scanned(ScannedDocument(scan: scan)) : .cancelled)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(.cancelled)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onFinish(.failed)
        }
    }
}

// MARK: - DocumentScanFlow

/// What tapping "Scan Document" should do for a given camera permission.
/// A pure function so the mapping is unit-testable without a camera.
nonisolated enum DocumentScanFlow {

    enum Step: Equatable {
        case present
        case requestAccess
        case explainDenied
    }

    static func step(for status: AVAuthorizationStatus) -> Step {
        switch status {
        case .authorized:          return .present
        case .notDetermined:       return .requestAccess
        case .denied, .restricted: return .explainDenied
        @unknown default:          return .explainDenied
        }
    }
}
