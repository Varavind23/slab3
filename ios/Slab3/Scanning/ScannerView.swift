import SwiftUI
import VisionKit

/// VisionKit barcode/QR scanner. Emits a decoded CertScan (grader auto-detected)
/// and de-dupes repeated reads of the same code within a session.
struct ScannerView: UIViewControllerRepresentable {
    var onScan: (CertScan) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [
                    .qr, .microQR, .aztec, .dataMatrix, .pdf417,
                    .code128, .code39, .code93, .ean13, .ean8, .upce, .itf14, .codabar,
                ])
            ],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (CertScan) -> Void
        private var seen = Set<String>()
        init(onScan: @escaping (CertScan) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd added: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in added {
                guard case let .barcode(code) = item,
                      let payload = code.payloadStringValue,
                      let scan = CertParser.parse(payload),
                      !seen.contains(scan.grader.rawValue + scan.certNumber)
                else { continue }
                seen.insert(scan.grader.rawValue + scan.certNumber)
                onScan(scan)
            }
        }
    }
}
