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
    let parsed: CertScan?
    var id: String { raw }
}

struct ScannerScreen: View {
    @State private var scans: [RawScan] = []

    var body: some View {
        VStack(spacing: 0) {
            ScannerView { payload in
                guard !scans.contains(where: { $0.raw == payload }) else { return }
                scans.insert(RawScan(raw: payload, parsed: CertParser.parse(payload)), at: 0)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            List(scans) { scan in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
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
                    // FULL raw payload, wrapped — this is what we need for CGC.
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
