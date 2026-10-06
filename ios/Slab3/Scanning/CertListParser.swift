import Foundation

/// Reads every cert out of a pasted block of text — the seller's list.
///
/// WHY IT EXISTS (owner ask, 2026-10-01). A buyer is usually sent a list of certs
/// by an independent seller and used to check them one at a time through the
/// manual-entry sheet. The lists arrive however the seller typed them: one per
/// line, comma-separated, "PSA 10 Charizard - 49385027", a column of cert URLs. So
/// this pulls certs out of prose rather than demanding a format, and leaves the
/// preview to show the user exactly what it found.
///
/// Each candidate goes through `CertParser.parse` — the camera's own rules — so a
/// pasted cert gets the same grader guess a scanned one would (10 digits → CGC,
/// 7–9 → PSA, or the URL's host). Short numbers (grades, years, prices) and runs
/// of 11+ digits are not certs and are skipped.
enum CertListParser {
    static func extract(_ text: String) -> [CertScan] {
        let joined = joinGroupedCGC(in: text)
        var seen = Set<String>()
        var found: [CertScan] = []
        for token in joined.split(whereSeparator: { $0.isWhitespace || ",;|".contains($0) }) {
            for scan in scans(in: String(token)) where seen.insert(scan.certNumber).inserted {
                found.append(scan)
            }
        }
        if found.isEmpty, let lone = loneNumber(text) { return [lone] }
        return found
    }

    /// One token: a whole cert or URL first, then any 7–10 digit runs inside it
    /// ("#49385027", "cert:49385027", a URL with a trailing ")").
    private static func scans(in token: String) -> [CertScan] {
        if let scan = CertParser.parse(token) { return [scan] }
        return token
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { run in (7...10).contains(run.count) ? CertParser.parse(String(run)) : nil }
    }

    /// CGC prints its 10-digit cert grouped 4-3-3 ("6055 074 171"), and a seller
    /// copying it off the label types it that way. Joined here so the split on
    /// whitespace doesn't break it into three short numbers. Spaces and hyphens
    /// only — never a newline, which separates two certs.
    private static func joinGroupedCGC(in text: String) -> String {
        let pattern = #"(?<!\d)(\d{4})[ -](\d{3})[ -](\d{3})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2$3")
    }

    /// The sheet's single-cert job, kept: before lists, it took any number typed
    /// into it, which is how a slab with an unusual cert length got in at all. A
    /// lone bare number the parser won't place is still accepted — as PSA, the
    /// grader picker's old default — and the preview lets the user flip it.
    private static func loneNumber(_ text: String) -> CertScan? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        return CertScan(grader: .psa, certNumber: trimmed, raw: trimmed)
    }
}

/// What a pasted list does when added: the new certs up to the cap, the ones
/// already in inventory (which add nothing), and the overflow left for next time.
///
/// The cap is the owner's (2026-10-01): seller lists are usually small, and every
/// new cert costs a Card Ladder lookup against a 200/day per-user budget. Only NEW
/// certs count toward it — a cert already held costs nothing.
enum CertBatch {
    static let cap = 30

    struct Split: Equatable {
        var add: [CertScan] = []
        var held: [CertScan] = []
        var over: [CertScan] = []
    }

    static func split(_ scans: [CertScan], cap: Int = cap, isHeld: (CertScan) -> Bool) -> Split {
        var split = Split()
        for scan in scans {
            if isHeld(scan) { split.held.append(scan) }
            else if split.add.count < cap { split.add.append(scan) }
            else { split.over.append(scan) }
        }
        return split
    }
}
