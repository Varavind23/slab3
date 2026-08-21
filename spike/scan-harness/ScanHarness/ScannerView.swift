import SwiftUI
import VisionKit

/// Thin wrapper around VisionKit's DataScannerViewController.
/// Recognizes both machine-readable codes (QR on modern PSA/CGC labels,
/// Code 128 / Code 39 on older PSA labels) — no OCR needed for certs.
struct ScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.qr, .code128, .code39, .dataMatrix, .microQR])
            ],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd added: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in added {
                if case let .barcode(code) = item, let payload = code.payloadStringValue {
                    onScan(payload)
                }
            }
        }
    }
}
