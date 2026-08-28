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
///   URL form  ──► host psacard.com → PSA ; host cgccards/cgccomics.com → CGC
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

        if let components = URLComponents(string: trimmed),
           let host = components.host?.lowercased(),
           let grader = grader(for: host),
           let cert = certificate(in: components, grader: grader) {
            return CertScan(grader: grader, certNumber: cert, raw: trimmed)
        }

        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        switch trimmed.count {
        case 10: return CertScan(grader: .cgc, certNumber: trimmed, raw: trimmed)
        case 7...9: return CertScan(grader: .psa, certNumber: trimmed, raw: trimmed)
        default: return nil
        }
    }

    private static func grader(for host: String) -> Grader? {
        if host == "psacard.com" || host.hasSuffix(".psacard.com") { return .psa }
        let cgcDomains = ["cgccards.com", "cgccomics.com"]
        if cgcDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return .cgc }
        return nil
    }

    private static func certificate(in components: URLComponents, grader: Grader) -> String? {
        let queryNames = Set(["cert", "certnumber", "certno", "certificationnumber"])
        let queryCandidates = components.queryItems?.compactMap { item -> String? in
            guard queryNames.contains(item.name.lowercased()) else { return nil }
            return item.value
        } ?? []
        let pathCandidates = components.path.split(separator: "/").reversed().map(String.init)
        return (queryCandidates + pathCandidates).first { valid($0, for: grader) }
    }

    private static func valid(_ value: String, for grader: Grader) -> Bool {
        guard value.allSatisfy(\.isNumber) else { return false }
        switch grader {
        case .psa: return (7...9).contains(value.count)
        case .cgc: return value.count == 10
        }
    }
}
