import Foundation
import SwiftData

/// Fetches a card's market prices and writes them back to the store. Courtyard
/// is live (direct Algolia). Card Ladder is pending official/session access, so
/// its price stays nil for now — the row's no-price state handles that cleanly.
///
/// On a confident Courtyard match we also auto-fill the card's name/set/grade if
/// they're missing, so a scan of a Courtyard-vaulted slab becomes a fully
/// identified, priced card with no typing.
@MainActor
enum PriceService {
    private static let courtyard = CourtyardClient()

    static func refresh(_ card: Card, in context: ModelContext) async {
        card.pricesLoading = true
        defer { card.pricesLoading = false }

        let match = await courtyard.lookup(
            grader: card.grader,
            certNumber: card.certNumber,
            name: card.name,
            set: card.set,
            grade: card.grade
        )

        guard let match else {
            card.courtyardPriceCents = nil
            if card.lookupStatus == .pending { card.lookupStatus = .needsConfirm }
            return
        }

        card.courtyardPriceCents = match.priceCents

        // Auto-fill identity from an exact/probable Courtyard match when missing.
        if match.confidence != .fuzzy {
            if card.name == nil { card.name = match.name }
            if card.set == nil { card.set = match.set }
            if card.year == nil { card.year = match.year }
            if card.grade == nil { card.grade = match.grade }
            card.refreshCardKey()
            if card.name != nil { card.lookupStatus = .resolved }
        } else if card.lookupStatus == .pending {
            card.lookupStatus = .needsConfirm
        }
    }
}
