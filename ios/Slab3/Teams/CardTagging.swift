import Foundation
import SwiftData

/// Who a card in THIS phone's inventory is credited to, and the one way to tag it
/// (virtual members, V1–V4, 2026-10-04).
///
/// TWO HOMES, ONE ANSWER. A slab in a lot has a server claim, and the claim's
/// credit (`credited_person_id`) is the truth — the whole team sees it. Any other
/// card can still be tagged (V4), but only on this phone (`Card.creditedPersonId` /
/// `creditedName`), and a linked consignor never sees it. Wherever both exist the
/// claim wins, so Export, the detail screen and Team activity can never disagree.
///
/// `Card.creditedPersonId` holds a `Buyer.id` — a member's user id or a roster
/// person's id — so a local tag needs no server round trip, even for a member.
@MainActor
enum CardTagging {
    /// The lot claim that is this card's server record, if it has one.
    static func claim(for card: Card, in claimsByLot: [UUID: [TeamClaim]]) -> TeamClaim? {
        guard let lotId = card.lotClaimLotId else { return nil }
        return claimsByLot[lotId]?.first { $0.cert == card.certNumber && $0.grader == card.graderRaw }
    }

    /// The buyer's name for the CSV and the detail screen. A lot slab: its claim's
    /// buyer after credit (the scanner when uncredited). Otherwise the local tag,
    /// read live from the roster when the person is still on it. nil = no buyer to name.
    static func buyerName(for card: Card, claimsByLot: [UUID: [TeamClaim]],
                          members: [TeamStore.Member], people: [TeamPerson]) -> String? {
        if let claim = claim(for: card, in: claimsByLot) {
            return BuyerResolver.buyer(of: claim, members: members, people: people).name
        }
        guard let id = card.creditedPersonId else { return nil }
        return BuyerResolver.choices(members: members, people: people).first { $0.id == id }?.name
            ?? card.creditedName
    }

    /// Tag cards to `buyer`, or clear their tag (nil). Lot slabs are credited on the
    /// server — by a lead only, as the receipt does (V2); everything else is tagged
    /// on this phone. Returns copy for anything not done, nil when all of it was.
    static func tag(_ cards: [Card], to buyer: Buyer?, team: TeamStore, lots: LotStore,
                    in context: ModelContext) async -> String? {
        var byLot: [UUID: [TeamClaim]] = [:]
        var local: [Card] = []
        for card in cards {
            if let claim = claim(for: card, in: lots.claimsByLot) {
                byLot[claim.lotId, default: []].append(claim)
            } else {
                local.append(card)
            }
        }
        for card in local {
            card.creditedPersonId = buyer?.id
            card.creditedName = buyer?.name
        }
        try? context.save()

        guard !byLot.isEmpty else { return nil }
        let lotCount = byLot.values.reduce(0) { $0 + $1.count }
        guard team.isLead, let teamId = team.team?.id else {
            return "\(lotCount) lot \(lotCount == 1 ? "card was" : "cards were") left as is — a lead tags those in the lot's receipt."
        }
        var personId: UUID?
        if let buyer {
            let (id, failure) = await team.personId(for: buyer)
            if let failure { return failure }
            personId = id
        }
        for (lotId, claims) in byLot {
            if let failure = await lots.setPerson(personId, claims: claims, lotId: lotId, teamId: teamId) {
                return failure
            }
        }
        return nil
    }

    /// After a merge, this phone's own tags follow the person who was absorbed.
    static func retag(from absorbed: UUID, to keep: Buyer, in context: ModelContext) {
        let target: UUID? = absorbed
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.creditedPersonId == target })
        guard let cards = try? context.fetch(descriptor), !cards.isEmpty else { return }
        for card in cards {
            card.creditedPersonId = keep.id
            card.creditedName = keep.name
        }
        try? context.save()
    }
}
