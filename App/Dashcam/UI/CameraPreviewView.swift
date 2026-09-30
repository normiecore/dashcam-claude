import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview. Rotation follows the device via `AVCaptureDevice.RotationCoordinator`
/// (iOS 17+), so the preview stays upright whether the phone is mounted portrait or landscape.
///
/// `device` is an explicit input (published by the coordinator once the session is configured) so
/// SwiftUI re-runs `updateUIView` when it becomes available; the capture service's own device
/// property is owned by the session queue and must not be read from here.
struct CameraPreviewView: UIViewRepresentable {
    let capture: CameraCaptureService
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.videoGravity = .resizeAspect
        // Attached on the session queue so it cannot race a configuration block.
        capture.attachPreview(view.previewLayer) { [weak view] in
            view?.reapplyRotation()
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if let device {
            uiView.attachRotationCoordinator(for: device)
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var attachedDeviceID: String?

    func attachRotationCoordinator(for device: AVCaptureDevice) {
        guard attachedDeviceID != device.uniqueID else { return }
        attachedDeviceID = device.uniqueID
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
        }
    }

    /// Re-applies the current angle; needed when the preview connection appears after the coordinator.
    func reapplyRotation() {
        guard let rotationCoordinator else { return }
        applyPreviewRotation(rotationCoordinator.videoRotationAngleForHorizonLevelPreview)
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}
