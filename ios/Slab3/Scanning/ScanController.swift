import SwiftUI
import AVFoundation

/// Owns the live scanner: the camera session, the torch control under the
/// viewport, and the certs it has admitted.
///
/// It used to own a `DataScannerViewController` and, on every recognised cert,
/// await `capturePhoto()` for the slab photo. That single call was both scanner
/// complaints at once: the still capture reconfigured the running session (the
/// preview froze for around a second) and it was awaited before the next cert
/// could be admitted (so scanning stalled for exactly as long). `CameraSession`
/// removes the reason for it — the frame the barcode was found in is the photo.
@MainActor
@Observable
final class ScanController {
    private(set) var scannerError: String?
    /// Live read-outs, useful on device and behind a debug toggle in the harness.
    private(set) var framesPerSecond: Double = 0
    private(set) var detectionsPerSecond: Double = 0

    var torchOn = false { didSet { session.setTorch(torchOn) } }

    /// How long a slab stays suppressed after leaving frame. Exposed so the
    /// harness can tune it against real slabs.
    var suppressionWindow: TimeInterval {
        get { session.suppressionWindow }
        set { session.suppressionWindow = newValue }
    }

    @ObservationIgnored private let session = CameraSession()

    var captureSession: AVCaptureSession { session.previewSession }

    /// Start delivering scans. Safe to call repeatedly — the session ignores a
    /// start it is already running.
    func start(onScan: @escaping (CertScan, Data?) -> Void) {
        session.onScan = onScan
        session.onStats = { [weak self] fps, dps in
            Task { @MainActor in
                self?.framesPerSecond = fps
                self?.detectionsPerSecond = dps
            }
        }
        session.start()
        switch session.availability {
        case .ok: scannerError = nil
        case .noDevice: scannerError = "No camera is available on this device."
        case .denied: scannerError = "Camera access is off for Slabs."
        case .failed(let reason): scannerError = "The camera couldn\'t start (\(reason))."
        }
    }

    func stop() { session.stop() }

    /// Allow a cert to be scanned again right away — used when its card is
    /// deleted, so a re-scan isn\'t silently swallowed by the suppression window.
    func forget(_ scan: CertScan) { session.forget(scan) }
}
