import Foundation

/// The one spelling of a grade the app stores: a bare number — "9", "10", "9.5".
///
/// Why it needs a home of its own (2026-08-31): the three sources each state the
/// grade differently — Courtyard "10 GEM MINT", PSA "PSA 9", Card Ladder the code
/// "g9" — and `Card.grade` is read by three things that must agree: the grade
/// badge, the comps panel header, and `card_key`, whose slug of "10 gem mint" is
/// a DIFFERENT key from the slug of "10". Normalizing at the point each source is
/// applied is what keeps one card from occupying two keys depending on which
/// source happened to answer first.
///
/// Anything that isn't a plain numeric grade (AUTH, altered, qualifier-only)
/// returns nil rather than a guess — the same rule prices follow, and the UI has
/// a real em-dash state for it.
enum GradeText {
    /// "10 GEM MINT" / "PSA 9" / "9.5" / "g9" → "10" / "9" / "9.5" / "9".
    /// Leading number only, so a trailing qualifier can never leak into the key.
    static func normalized(_ grade: String?) -> String? {
        guard let grade else { return nil }
        var out = ""
        for ch in grade {
            if ch.isNumber || (ch == "." && !out.isEmpty) {
                out.append(ch)
            } else if !out.isEmpty {
                break
            }
        }
        return out.isEmpty ? nil : out
    }
}
