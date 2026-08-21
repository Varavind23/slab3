// M0 spike: throwaway VisionKit harness.
// Purpose: point a real iPhone at real PSA + CGC slabs — reflective cases,
// curved labels, bad show-floor lighting — and verify the barcode/QR reads
// and CertParser extracts (grader, cert). Exit evidence: a screen recording.
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

struct ScannerScreen: View {
    @State private var results: [CertScan] = []

    var body: some View {
        VStack(spacing: 0) {
            ScannerView { payload in
                if let scan = CertParser.parse(payload),
                   !results.contains(where: { $0.id == scan.id }) {
                    results.insert(scan, at: 0)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            List(results) { scan in
                HStack {
                    Text(scan.grader.rawValue.uppercased()).bold()
                    Text(scan.certNumber).monospaced()
                    Spacer()
                    Text(scan.raw).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxHeight: 260)
        }
    }
}
