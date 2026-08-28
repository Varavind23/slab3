import Vision
import CoreVideo

/// Vision barcode detection over live camera frames.
///
/// Replaces VisionKit's `DataScannerViewController`, which detected the same
/// symbologies but kept the pixels to itself: its only way to hand back an image
/// was `capturePhoto()`, a full still capture that reconfigured the session and
/// froze the preview for around a second. Running Vision ourselves means the
/// frame we recognised the barcode in IS the photo — no second capture, nothing
/// to stall, nothing to block the next slab.
///
/// The symbology list is the one the old scanner used, unchanged: both graders
/// print a bare-number Code128 barcode, and PSA's QR is the other reliable target
/// (CGC's QR is a Turnstile-walled URL — see spike/README.md §5).
final class BarcodeDetector {
    private let request: VNDetectBarcodesRequest

    init() {
        request = VNDetectBarcodesRequest()
        request.symbologies = [
            .qr, .microQR, .aztec, .dataMatrix, .pdf417,
            .code128, .code39, .code93, .ean13, .ean8, .upce, .itf14, .codabar,
        ]
        // Only look inside the guides. Cheaper than a full-frame pass AND better
        // behaved: a neighbouring slab in the tray can no longer hijack a scan.
        request.regionOfInterest = ScanGeometry.guideRect
    }

    /// Recognise a cert in one frame. Runs SYNCHRONOUSLY on the caller's queue —
    /// which is the camera's serial video queue, so late frames are dropped
    /// rather than queued and there is no backlog to fall behind on.
    ///
    /// Deliberately no downscaling first: resizing costs about what the detection
    /// itself costs, and small Code128 bars on a curved, glare-lit slab label are
    /// exactly where the extra pixels earn their keep.
    func certificate(in buffer: CVPixelBuffer) -> CertScan? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?
            .lazy
            .compactMap(\.payloadStringValue)
            .compactMap(CertParser.parse)
            .first
    }
}
