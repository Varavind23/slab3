// Device harness for the scanner rebuild (2026-08-28).
//
// The app's scanner froze the preview and stalled between slabs. Both came from
// one call: VisionKit's DataScannerViewController hands back pixels only via
// capturePhoto(), a full still capture that reconfigures the running session —
// and it was awaited before the next cert could be admitted. CameraSession
// replaces it with an AVCaptureSession we own, where the frame the barcode was
// found in IS the photo.
//
// This harness exists to answer the questions a simulator cannot:
//   * is the freeze actually gone, and does the preview hold its frame rate
//     while capturing? (fps / detections-per-second read-out)
//   * how fast is slab-to-slab really, flipping through an actual box?
//   * is a cropped video frame good enough for the row AND the detail view?
//     (each capture is shown at both 46×64 and full width, with its byte count)
//   * is the suppression window right? (slider). Only governs OTHER certs now —
//     a repeat of the last slab is blocked outright, whatever the gap.
//   * does the guide-rect crop frame the card or the label at natural distance?
//
// It builds the APP's CameraSession/BarcodeParser/etc. from source (see
// project.yml `sources:`) rather than copying them — the previous harness kept
// its own fork of CertParser, which drifted, so every verdict it produced was a
// verdict about the harness rather than the app.
//
// Setup: open ScanHarness.xcodeproj, run on a real iPhone.

import SwiftUI

@main
struct ScanHarnessApp: App {
    var body: some Scene {
        WindowGroup { HarnessScreen() }
    }
}

struct CapturedScan: Identifiable {
    let scan: CertScan
    let photo: Data?
    let at = Date()
    var id: String { "\(scan.grader.rawValue):\(scan.certNumber):\(at.timeIntervalSince1970)" }
}

struct HarnessScreen: View {
    @State private var controller = ScanController()
    @State private var scans: [CapturedScan] = []
    @State private var suppression: Double = 1.5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraPreview(session: controller.captureSession)
                GuideOverlay()
                VStack {
                    Spacer()
                    readout
                }
            }
            .frame(height: 340)
            .clipped()

            controls
            captureList
        }
        .onAppear {
            controller.start { scan, photo in
                scans.insert(CapturedScan(scan: scan, photo: photo), at: 0)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        .onDisappear { controller.stop() }
    }

    /// The numbers you cannot guess from a desk.
    private var readout: some View {
        HStack(spacing: 14) {
            stat("fps", String(format: "%.0f", controller.framesPerSecond))
            stat("det/s", String(format: "%.1f", controller.detectionsPerSecond))
            stat("scans", "\(scans.count)")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .padding(.bottom, 8)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle("Torch", isOn: $controller.torchOn).fixedSize()
                Spacer()
                Button("Clear") { scans.removeAll() }.buttonStyle(.bordered)
            }
            HStack {
                Text("Other-cert hold \(suppression, specifier: "%.1f")s")
                    .font(.caption).monospacedDigit()
                Slider(value: $suppression, in: 0.3...4)
                    .onChange(of: suppression) { _, new in controller.suppressionWindow = new }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Each capture at BOTH sizes it has to survive: the 46×64 row thumbnail and
    /// the full-width detail view.
    private var captureList: some View {
        List(scans) { item in
            HStack(alignment: .top, spacing: 10) {
                thumb(item.photo, width: 46, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.scan.grader.rawValue.uppercased()).bold()
                        Text(item.scan.certNumber).monospaced()
                    }
                    Text(item.photo.map { "\($0.count / 1024) KB" } ?? "NO PHOTO")
                        .font(.caption2)
                        .foregroundStyle(item.photo == nil ? .red : .secondary)
                    thumb(item.photo, width: 220, height: 300)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func thumb(_ data: Data?, width: CGFloat, height: CGFloat) -> some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
                .border(.secondary)
        } else {
            Rectangle().fill(.quaternary).frame(width: width, height: height)
        }
    }
}

/// Draws exactly the rectangle Vision is restricted to and the capture is cropped
/// to, so a mis-framed slab is visible rather than mysterious.
struct GuideOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let r = ScanGeometry.guideRectFlipped
            Rectangle()
                .strokeBorder(.yellow.opacity(0.8), lineWidth: 2)
                .frame(width: r.width * geo.size.width, height: r.height * geo.size.height)
                .position(
                    x: (r.minX + r.width / 2) * geo.size.width,
                    y: (r.minY + r.height / 2) * geo.size.height
                )
        }
    }
}
