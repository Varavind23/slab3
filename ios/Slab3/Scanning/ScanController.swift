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

    /// True while the scanner is deliberately ignoring the frame because the slab
    /// it just captured has not left yet (`RecentCertWindow` rule 2). The viewport
    /// says so: holding and failing-to-read look identical otherwise, and a user
    /// who thinks it missed the slab will wave it about instead of lifting it off.
    private(set) var isHolding = false

    var torchOn = false { didSet { session.setTorch(torchOn) } }

    /// Auto-scan (the default) takes every slab the camera recognises; tap-to-scan
    /// waits to be asked. The screen owns the preference and pushes it here; the
    /// session is what actually acts on it, and it is set again in `start` so a
    /// restored preference survives the camera being torn down and rebuilt.
    var autoScan = true { didSet { session.isAutoScanning = autoScan } }

    /// Tap-to-scan: take the slab in front of the camera now. Arms the next
    /// detection pass rather than capturing inline — see TapCaptureArm.
    func capture() { session.requestCapture() }

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
    /// `onMiss` fires only in tap-to-scan — a tap that found nothing readable. It
    /// defaults to doing nothing, so the device harness (which only ever
    /// auto-scans) keeps compiling against this unchanged.
    func start(onScan: @escaping (CertScan, Data?) -> Void, onMiss: @escaping () -> Void = {}) {
        session.onScan = onScan
        session.onCaptureMiss = onMiss
        session.onStats = { [weak self] fps, dps in
            Task { @MainActor in
                self?.framesPerSecond = fps
                self?.detectionsPerSecond = dps
            }
        }
        session.onHoldChange = { [weak self] holding in
            Task { @MainActor in self?.isHolding = holding }
        }
        // The camera is torn down and rebuilt whenever the tab is left and come
        // back to, so the remembered mode has to be pushed on every start, not
        // only when the user flips the switch.
        session.isAutoScanning = autoScan
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
