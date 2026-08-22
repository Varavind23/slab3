import Foundation

enum Grader: String { case psa, cgc }

struct CertScan: Identifiable {
    let grader: Grader
    let certNumber: String
    let raw: String
    var id: String { "\(grader.rawValue):\(certNumber)" }
}

/// Parses raw barcode/QR payloads from PSA and CGC slab labels, auto-detecting
/// the grader — no manual toggle.
///
///   payload ──► URL form?  ──► host psacard.com  → PSA
///          │                   host cgc*.com      → CGC
///          └─► bare digits ──► length 10 → CGC   (cert shown 4-3-3 on slab)
///                              length 7-9 → PSA
///
/// Grader-by-length is the magic: verified against real slabs (2026-08-22) —
/// PSA certs are 8 digits (49385027, 82031277), CGC card certs are 10 digits
/// (6055074171, 4274842001). Both encode as bare-number Code128 barcodes, so
/// length is the only on-device signal that tells them apart. The barcode is
/// the reliable target for both (the CGC QR is just a Turnstile-walled URL).
enum CertParser {
    static func parse(_ payload: String) -> CertScan? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // QR / URL form: classify by host, pull the numeric path component.
        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            let digits = url.pathComponents.reversed().first {
                !$0.isEmpty && $0.allSatisfy(\.isNumber)
            }
            if host.contains("psacard"), let cert = digits {
                return CertScan(grader: .psa, certNumber: cert, raw: trimmed)
            }
            if host.contains("cgc"), let cert = digits {
                return CertScan(grader: .cgc, certNumber: cert, raw: trimmed)
            }
            return nil
        }

        // Bare numeric barcode (Code128). Grader by cert-number length.
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        switch trimmed.count {
        case 10:
            return CertScan(grader: .cgc, certNumber: trimmed, raw: trimmed)
        case 7...9:
            return CertScan(grader: .psa, certNumber: trimmed, raw: trimmed)
        default:
            return nil
        }
    }
}
