// M0 spike: throwaway VisionKit harness.
// Purpose: point a real iPhone at real PSA + CGC slabs — reflective cases,
// curved labels, bad show-floor lighting — and verify the barcode/QR reads.
//
// CGC investigation (2026-08-22): shows the FULL RAW payload of EVERY scan,
// parsed or not, so a CGC QR that CertParser doesn't yet recognize is still
// visible. Tap a row to copy its raw string. We need to know exactly what the
// CGC QR encodes — if it carries card data, CGC needs no online lookup.
//
// Setup: Xcode → New iOS App "ScanHarness" (SwiftUI, iOS 17) → replace the
// generated files with these three → add NSCameraUsageDescription to Info.

import SwiftUI

@main
struct ScanHarnessApp: App {
    var body: some Scene {
        WindowGroup { ScannerScreen() }
    }
}

struct RawScan: Identifiable {
    let raw: String
    let symbology: String
    let parsed: CertScan?
    var id: String { symbology + ":" + raw }
}

struct ScannerScreen: View {
    @State private var scans: [RawScan] = []

    var body: some View {
        VStack(spacing: 0) {
            ScannerView { payload, symbology in
                guard !scans.contains(where: { $0.raw == payload && $0.symbology == symbology }) else { return }
                scans.insert(RawScan(raw: payload, symbology: symbology, parsed: CertParser.parse(payload)), at: 0)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            List(scans) { scan in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // Symbology tag: QR vs a 1D barcode (Code128 etc.).
                        Text(scan.symbology).font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(scan.symbology == "QR" ? Color.blue.opacity(0.2) : Color.green.opacity(0.25))
                            .clipShape(Capsule())
                        if let p = scan.parsed {
                            Text(p.grader.rawValue.uppercased()).bold()
                            Text(p.certNumber).monospaced()
                        } else {
                            Text("UNPARSED").bold().foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Copy") { UIPasteboard.general.string = scan.raw }
                            .font(.caption).buttonStyle(.bordered)
                    }
                    Text(scan.raw)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
