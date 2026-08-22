import SwiftUI
import VisionKit

/// Thin wrapper around VisionKit's DataScannerViewController.
/// Recognizes QR (modern PSA/CGC labels) AND 1D barcodes (Code 128 / Code 39 /
/// EAN — the CGC cert barcode). Reports the SYMBOLOGY with each scan so we can
/// tell a CGC QR (useless cgccomics.com URL) from the CGC cert barcode.
struct ScannerView: UIViewControllerRepresentable {
    var onScan: (String, String) -> Void // (payload, symbology)

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [
                    .qr, .microQR, .aztec, .dataMatrix, .pdf417,
                    .code128, .code39, .code93, .ean13, .ean8, .upce, .itf14, .codabar,
                ])
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
        let onScan: (String, String) -> Void
        init(onScan: @escaping (String, String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd added: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in added {
                if case let .barcode(code) = item, let payload = code.payloadStringValue {
                    let sym = code.observation.symbology.rawValue // e.g. "VNBarcodeSymbologyQR"
                    onScan(payload, sym.replacingOccurrences(of: "VNBarcodeSymbology", with: ""))
                }
            }
        }
    }
}
