import Foundation

/// Builds the canonical `card_key` used for sale-limit counting AND price
/// matching. MUST stay byte-for-byte identical to the SQL `make_card_key`
/// function (supabase/migrations) — the plan requires Swift↔SQL parity, tested
/// against shared vectors.
///
/// Shape: `{grader}:{set}:{card_id}:{grade}`, each segment lowercased with every
/// run of non-alphanumerics collapsed to a single '-'.
enum CardKey {
    static func make(grader: Grader, set: String?, cardId: String?, grade: String?) -> String {
        [grader.rawValue, slug(set), slug(cardId), slug(grade)].joined(separator: ":")
    }

    /// Mirrors SQL: lower(trim(x)) then regexp_replace('[^a-z0-9]+', '-', 'g').
    /// Note: unlike a typical slug, the SQL does NOT strip leading/trailing '-',
    /// so we must not either — parity over prettiness.
    private static func slug(_ raw: String?) -> String {
        let lowered = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastWasDash = false
            } else {
                if !lastWasDash { out.append("-") }
                lastWasDash = true
            }
        }
        return out
    }
}
