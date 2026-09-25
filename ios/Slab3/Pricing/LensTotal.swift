import Foundation

/// The one rule for adding up a pile of cards under a lens (2026-09-25).
///
/// Testers on the max-buy pilot reported the selection total "doesn't add up" — it
/// matched the CY value. Before the lens existed (builds 5–6) the bar always summed
/// the header's source while they read max-buy figures off each card; after it, the
/// bar followed the lens but never said so. Two totals — the selection bar and the
/// Cards summary — each did their own inline sum. They now both come through here,
/// the way every max-buy figure comes through `MaxBuyValue`, and label their basis.
@MainActor
enum LensTotal {

    /// `cents` is the sum; `counted` is how many cards actually contributed. A card
    /// with no figure adds nothing and is never counted as $0 — the caller shows
    /// "9 of 12" so a short total explains itself.
    static func of(_ cards: [Card], lens: PriceLens) -> (cents: Int, counted: Int) {
        let figures: [Int]
        if let source = lens.source {
            // Falls back to the other source when this one is missing — the value
            // totals always have; this does not change what they mean.
            figures = cards.compactMap { $0.prices.best(preferring: source) }
        } else {
            // The same memoized figure every row shows, so the bar equals the sum of
            // the selected rows.
            figures = cards.compactMap { MaxBuyValue.cents(for: $0) }
        }
        return (figures.reduce(0, +), figures.count)
    }
}
