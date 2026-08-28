import AVFoundation
import SwiftUI

/// The live preview layer, and nothing else.
///
/// `updateUIView` is EMPTY ON PURPOSE — do not add work to it. The scanner it
/// replaced re-applied camera settings on every SwiftUI update, taking a device
/// configuration lock each time, which was a second source of preview hitching on
/// top of the still-capture freeze. Camera state is configured once in
/// `CameraSession.configure()` and changed only through explicit calls like
/// `setTorch`, never as a side effect of a view update.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    /// Intentionally empty. See the note above.
    func updateUIView(_ view: PreviewView, context: Context) {}

    /// Backing the view with the preview layer directly avoids having to resize a
    /// sublayer by hand on every layout pass.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
