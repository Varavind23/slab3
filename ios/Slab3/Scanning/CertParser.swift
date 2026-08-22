import Foundation

/// Result of decoding a slab's barcode/QR into a grader + cert number.
struct CertScan: Equatable {
    let grader: Grader
    let certNumber: String
    let raw: String
}

/// Parses raw barcode/QR payloads from PSA and CGC slab labels, auto-detecting
/// the grader — no manual toggle (verified against real slabs 2026-08-22).
///
///   URL form  ──► host psacard.com → PSA ; host cgc*.com → CGC
///   bare digits ► length 10 → CGC (cert shown 4-3-3 on slab)
///               ► length 7-9 → PSA
///
/// Both graders encode the cert as a bare-number Code128 barcode, so cert
/// length is the only on-device signal separating them: PSA = 8 digits
/// (49385027), CGC card certs = 10 digits (6055074171). The barcode is the
/// reliable target; the CGC QR is only a Turnstile-walled cgccomics.com URL.
enum CertParser {
    static func parse(_ payload: String) -> CertScan? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

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

        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        switch trimmed.count {
        case 10: return CertScan(grader: .cgc, certNumber: trimmed, raw: trimmed)
        case 7...9: return CertScan(grader: .psa, certNumber: trimmed, raw: trimmed)
        default: return nil
        }
    }
}
