import Foundation

/// Which source a team lot's money is counted in (owner decision M3, 2026-10-01;
/// ~/.claude/plans/max-buy-for-teams-and-lot-basis.md).
///
/// On a CL lot every dollar is Card Ladder Value at claim, as it always was. On a CY
/// lot it is Courtyard's value instead, and CL plays NO part: buckets match on it,
/// budgets spend it, the 3-limit counts Courtyard's identity, and members need no
/// Card Ladder account to buy in. The server decides all of that
/// (`claim_lot_scan` v3); the app's job is to LABEL every lot dollar with its basis,
/// so a CY figure is never read as CL.
///
/// Every claim records both sources' values, which is what lets a lead switch an
/// existing lot (`set_lot_basis`) without anybody's buy moving.
enum ValueBasis: String, Codable, CaseIterable, Equatable, Hashable {
    case cl, cy

    var source: PriceSource { self == .cl ? .cl : .cy }
    /// "CL" / "CY" — the segment label.
    var short: String { rawValue.uppercased() }
    /// "CL value at claim" — the label every lot dollar carries.
    var valueAtClaim: String { "\(short) value at claim" }
    /// "Card Ladder" / "Courtyard" — for sentences.
    var sourceName: String { self == .cl ? "Card Ladder" : "Courtyard" }
}
