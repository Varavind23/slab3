import Foundation

enum Grader: String { case psa, cgc }

struct CertScan: Identifiable {
    let grader: Grader
    let certNumber: String
    let raw: String
    var id: String { "\(grader.rawValue):\(certNumber)" }
}

/// Parses raw barcode/QR payloads from PSA and CGC slab labels.
///
///   payload ──► URL form?  ──► psacard.com/cert/{n}       → PSA
///          │                   cgccards.com/certlookup/{n} → CGC
///          └─► bare digits ──► PSA cert (Code 128/39 on older labels)
///
/// The M0 spike exists to validate these patterns against REAL slabs —
/// add every payload the harness shows to the fixture list below.
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

        // Bare numeric payload: older PSA labels carry the cert number directly.
        if trimmed.count >= 7, trimmed.count <= 10, trimmed.allSatisfy(\.isNumber) {
            return CertScan(grader: .psa, certNumber: trimmed, raw: trimmed)
        }
        return nil
    }
}
