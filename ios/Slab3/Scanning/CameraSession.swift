import AVFoundation
import CoreVideo
import Foundation

/// The live camera behind the scan viewport.
///
/// WHY THIS EXISTS AT ALL — it replaces VisionKit's `DataScannerViewController`,
/// which was the sole cause of both scanner complaints. That class hands back
/// pixels exactly one way, `capturePhoto()`, and that call reconfigures the
/// running capture session for a high-resolution still. The preview visibly froze
/// for roughly 0.5–1.5s, and because the capture was awaited before the next cert
/// could be admitted, it was ALSO the only thing blocking the following slab. One
/// bug, both symptoms. There is no cheaper frame API on that class to swap in —
/// it vends no sample buffers and does not expose its session — so owning the
/// session is the only way out. Nothing was lost by leaving: the app already
/// disabled every DataScanner affordance (guidance, highlighting, pinch zoom).
///
/// Now the frame the barcode was recognised in IS the photo, so a capture costs
/// one crop and one encode and the preview never stops.
///
/// Threading, which is the part that is easy to get wrong:
///   * `sessionQueue` owns every configuration call and start/stop.
///   * `videoQueue` is the sample-buffer delegate queue; detection and encoding
///     both run there, never on main.
///   * only the finished result hops to the main actor.
final class CameraSession: NSObject {
    enum Availability: Equatable {
        case ok
        case noDevice
        case denied
        case failed(String)
    }

    /// Delivered on the main actor, once per admitted slab.
    var onScan: ((CertScan, Data?) -> Void)?
    /// Main actor, on CHANGE only: the scanner is holding on the slab it just
    /// captured (true) or is ready for the next one (false). See RecentCertWindow.
    var onHoldChange: ((Bool) -> Void)?
    /// Main actor: a tap-to-scan tap found nothing readable before its deadline.
    /// Auto-scan never fires this — nothing was asked, so silence is honest.
    var onCaptureMiss: (() -> Void)?
    /// Frames seen / certs admitted, for the harness read-out. Video queue only.
    var onStats: ((_ framesPerSecond: Double, _ detectionsPerSecond: Double) -> Void)?

    private(set) var availability: Availability = .ok
    /// Session queue: what configuring the camera found, once `start()` has done
    /// it. `availability` cannot be read straight after `start()` — the work is
    /// still queued then, so a failure used to read as `.ok` (a black viewport).
    var onAvailability: ((Availability) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "slabs.camera.session")
    private let videoQueue = DispatchQueue(label: "slabs.camera.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()

    private let detector = BarcodeDetector()
    private let capture = SlabFrameCapture()

    // Video-queue state. Not synchronized because that queue is serial and is
    // the only thing that touches them.
    private var window = RecentCertWindow()
    private var arm = TapCaptureArm()
    private var autoScan = true
    private var lastDetectionAt: CFTimeInterval = 0
    /// Last hold state handed to the UI, so `onHoldChange` fires on transitions
    /// rather than twelve times a second.
    private var lastReportedHold = false
    private var frameCount = 0
    private var detectionCount = 0
    private var statsWindowStart: CFTimeInterval = CACurrentMediaTime()

    private var device: AVCaptureDevice?

    var previewSession: AVCaptureSession { session }

    var suppressionWindow: TimeInterval {
        get { window.suppression }
        set { videoQueue.async { self.window.suppression = newValue } }
    }

    /// Auto-scan takes slabs as the camera recognises them; tap-to-scan waits to be
    /// asked. Applied on the video queue, like the suppression window, because that
    /// queue owns every decision it changes.
    var isAutoScanning: Bool {
        get { autoScan }
        set {
            videoQueue.async {
                self.autoScan = newValue
                // A tap the user has just switched away from must not fire its
                // readout into the other mode.
                self.arm.cancel()
                // The hold is an auto-scan idea. Left lit, it would dim the guides
                // of a tap-to-scan viewport that is perfectly ready.
                if !newValue { self.reportHold(false) }
            }
        }
    }

    /// Tap-to-scan: take whatever is in front of the camera now. Arms the next
    /// detection pass rather than capturing here — the frame a tap would want has
    /// already been recycled by the time the tap arrives. See TapCaptureArm.
    func requestCapture() {
        videoQueue.async { self.arm.arm() }
    }

    // MARK: Lifecycle

    /// Configure once. Everything the old code re-applied on every SwiftUI
    /// update — focus, zoom, torch — is set here and then left alone.
    func start() {
        sessionQueue.async { [self] in
            if session.isRunning { return }
            if session.inputs.isEmpty {
                switch configure() {
                case .success: availability = .ok
                case .failure(let reason): availability = reason
                }
                onAvailability?(availability)
                guard availability == .ok else { return }
            }
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Let a cert be scanned again immediately — used when its card is removed.
    func forget(_ scan: CertScan) {
        videoQueue.async { self.window.forget(Self.key(scan)) }
    }

    private enum ConfigureResult { case success, failure(Availability) }

    private func configure() -> ConfigureResult {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else { return .failure(.denied) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return .failure(.noDevice)
        }
        self.device = device

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 1080p: a guide-rect crop of this is ~780 × 1080, several times the row
        // thumbnail's pixel count. 4K would roughly triple detection cost and
        // heat for a difference nobody can see at 46 × 64.
        session.sessionPreset = .hd1920x1080

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return .failure(.failed("camera input rejected")) }
            session.addInput(input)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return .failure(.failed("camera output rejected")) }
        session.addOutput(output)

        // Rotate at the connection so buffers arrive upright: Vision then gets
        // `.up` and the JPEG needs no orientation fix-up per frame.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        // Slabs are held close, so bias autofocus near. Done once.
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        device.unlockForConfiguration()

        return .success
    }

    // MARK: Torch

    func setTorch(_ on: Bool) {
        sessionQueue.async { [self] in
            guard let device, device.hasTorch else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    private static func key(_ scan: CertScan) -> String {
        "\(scan.grader.rawValue):\(scan.certNumber)"
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = CACurrentMediaTime()
        frameCount += 1
        reportStats(now: now)

        // Detection is throttled; the preview is not. It runs off its own
        // connection and never waits on anything here.
        guard now - lastDetectionAt >= 1.0 / ScanGeometry.detectionsPerSecond else { return }
        lastDetectionAt = now

        // Tap-to-scan looks only when it has been asked to. Vision is the
        // expensive half of this callback, so an idle tap-mode viewport costs
        // nothing beyond the preview it is already drawing.
        if !autoScan && !arm.isArmed { return }

        // The WHOLE frame, on EVERY pass — including passes that see nothing. An
        // empty frame is the evidence that the captured slab has left and the
        // scanner can take the next one, so this cannot be skipped when there is
        // no cert to react to. Feeding the window one cert per pass is what made a
        // slab still sitting in view look as though it had gone.
        let scans = detector.certificates(in: buffer)
        if !scans.isEmpty { detectionCount += 1 }

        let taken: CertScan?
        if autoScan {
            let admitted = window.update(sightings: scans.map(Self.key))
            reportHold(window.isHolding)
            taken = admitted.flatMap { key in scans.first { Self.key($0) == key } }
        } else {
            switch arm.resolve(sawCert: !scans.isEmpty) {
            case .idle:
                return
            case .expired:
                DispatchQueue.main.async { [onCaptureMiss] in onCaptureMiss?() }
                return
            case .capture:
                // The user picked this slab, so the window's rules are bypassed: a
                // second tap on a card already in inventory has to reach the
                // duplicate readout rather than be swallowed by rule 1. It is
                // still recorded, so flipping back to auto-scan does not take the
                // slab still sitting in your hand.
                let scan = scans[0]
                window.noteAdmitted(Self.key(scan))
                taken = scan
            }
        }

        guard let scan = taken else { return }

        // Encode inline: the buffer is only valid for this callback, and holding
        // it to convert later would starve the capture pool.
        let photo = capture.jpeg(from: buffer)
        DispatchQueue.main.async { [onScan] in onScan?(scan, photo) }
    }

    /// Transitions only. The UI redraws on this and the loop runs twelve times a
    /// second, so reporting every pass would be twelve redraws a second.
    private func reportHold(_ holding: Bool) {
        guard holding != lastReportedHold else { return }
        lastReportedHold = holding
        DispatchQueue.main.async { [onHoldChange] in onHoldChange?(holding) }
    }

    private func reportStats(now: CFTimeInterval) {
        guard let onStats, now - statsWindowStart >= 1 else { return }
        let elapsed = now - statsWindowStart
        onStats(Double(frameCount) / elapsed, Double(detectionCount) / elapsed)
        frameCount = 0
        detectionCount = 0
        statsWindowStart = now
    }
}
