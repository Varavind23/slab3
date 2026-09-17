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

    /// EVERY cert visible in one frame, de-duplicated, in Vision's order. Runs
    /// SYNCHRONOUSLY on the caller's queue — the camera's serial video queue — so
    /// late frames are dropped rather than queued and there is no backlog.
    ///
    /// It returns all of them rather than the first because the scanner holds on
    /// ONE slab at a time, and that hold has to know whether the slab it just
    /// captured is STILL in frame (`RecentCertWindow`). With only the first result
    /// that question is unanswerable: while a lifted slab and the one underneath
    /// it are both in view, Vision reports either one, so on any frame that named
    /// the other slab the captured one looked like it had left. The scanner
    /// re-armed early, and the same slab could be admitted twice — which is how
    /// one card reached the recent list more than once (2026-09-15).
    ///
    /// Deliberately no downscaling first: resizing costs about what the detection
    /// itself costs, and small Code128 bars on a curved, glare-lit slab label are
    /// exactly where the extra pixels earn their keep.
    func certificates(in buffer: CVPixelBuffer) -> [CertScan] {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var found: [CertScan] = []
        for scan in (request.results ?? []).lazy.compactMap(\.payloadStringValue).compactMap(CertParser.parse) {
            // One slab can carry two readable codes (a QR and a barcode), and a
            // frame can hold two slabs. Identity is grader + cert, not the raw
            // payload, so the same slab read two ways counts once.
            if !found.contains(where: { $0.grader == scan.grader && $0.certNumber == scan.certNumber }) {
                found.append(scan)
            }
        }
        return found
    }
}
