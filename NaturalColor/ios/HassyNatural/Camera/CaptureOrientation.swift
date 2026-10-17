import UIKit

/// Camera UI remains stable while file orientation follows the held device.
enum CaptureOrientation {
    static func angle(for orientation: UIDeviceOrientation, previous: CGFloat) -> CGFloat {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        default: return previous // face-up/down and unknown keep the last valid pose
        }
    }
}
