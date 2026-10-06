import Foundation

/// The lead's Team activity numbers (teams-first plan, D17–D27), derived and
/// nothing else.
///
/// WHAT IT IS FOR. The lead runs the team; this answers "how many cards has each
/// person contributed to this lot, and which ones" — with the full receipt, card
/// by card. It is not a price tool: every dollar here is a figure RECORDED AT CLAIM,
/// and the lead picks which one with the MAX · CL · CY bar (owner M6, 2026-10-01):
/// CL Value, Courtyard's value, or the max buy the buyer's phone showed. The bar is
/// a view only — it changes nothing on the server, and the lot's budgets stay in the
/// lot's own basis. The app never learns what a buyer actually paid, so no figure
/// here may be labelled as "spent". A claim with no figure in the chosen view adds
/// nothing and is counted as unvalued, so the screen can say "9 of 12" rather than
/// pass a short sum off as complete.
///
/// WHAT COUNTS. Every slab a buyer put into the lot — confirmed AND over-limit (an
/// offline buy that landed after a limit filled: the buyer really bought it, owner
/// decision D27). Released slabs (`removed`) are not in the lot and never count.
/// Note this differs on purpose from LotRoom, which counts only confirmed claims:
/// room is about the lot's caps, activity is about each person's work.
///
/// LEAD-ONLY IS UI GATING. RLS lets any team member read every claim
/// (`lot_claims_read`), and buyers already see teammates' buys on Cards; the
/// dashboard is simply not offered to them.
enum TeamActivity {
    struct LotBox: Identifiable, Equatable {
        let lot: Lot
        let cards: Int
        let cents: Int64
        /// Cards that HAVE a figure in the chosen view. `cards` when every one does.
        var valued: Int? = nil
        var id: UUID { lot.id }
    }

    /// One buyer's row. `userId` is a member's user id OR a virtual person's id
    /// (`Buyer.id`) — a slab credited to someone is theirs, not the scanner's (V1).
    struct MemberTotal: Identifiable, Equatable {
        let userId: UUID
        let name: String
        let cards: Int
        let cents: Int64
        var valued: Int? = nil
        var isVirtual: Bool = false
        var id: UUID { userId }
    }

    /// The per-phone view the lead last picked; unset reads as the lot's own basis.
    static let lensKey = "caliper_activity_lens"

    static func lens(stored: String, lot: Lot?) -> PriceLens {
        PriceLens(rawValue: stored) ?? PriceLens(lot?.valueBasis.source ?? .cl)
    }

    /// "9 of 12 with a max buy" when some claims have no figure in this view.
    static func coverage(cards: Int, valued: Int?, lens: PriceLens) -> String? {
        guard let valued, valued < cards else { return nil }
        let what = lens == .maxBuy ? "with a max buy" : "with a \(lens.label) value"
        return "\(valued) of \(cards) \(what)"
    }

    private static func sum(_ claims: [TeamClaim], _ lens: PriceLens) -> (cents: Int64, valued: Int) {
        claims.reduce((Int64(0), 0)) { acc, claim in
            guard let c = claim.cents(in: lens) else { return acc }
            return (acc.0 + Int64(c), acc.1 + 1)
        }
    }

    /// The slabs that count: in the lot, confirmed or over the limit.
    static func counted(_ claims: [TeamClaim]) -> [TeamClaim] {
        claims.filter { $0.state == "confirmed" || $0.state == "over_limit" }
    }

    /// Every lot a lead can review, open ones first by deadline (soonest, then no
    /// deadline), then closed ones newest first. Drafts have no buys to show.
    static func boxes(lots: [Lot], claimsByLot: [UUID: [TeamClaim]], lens: PriceLens = .cl) -> [LotBox] {
        let open = lots.filter { $0.status == .active }.sorted(by: Lot.soonestFirst)
        let closed = lots.filter { $0.status == .closed }.sorted { $0.createdAt > $1.createdAt }
        return (open + closed).map { lot in
            let claims = counted(claimsByLot[lot.id] ?? [])
            let total = sum(claims, lens)
            return LotBox(lot: lot, cards: claims.count, cents: total.cents, valued: total.valued)
        }
    }

    /// The box to open on: the lot being scanned into, else the first.
    static func defaultLot(current: UUID?, boxes: [LotBox]) -> UUID? {
        if let current, boxes.contains(where: { $0.id == current }) { return current }
        return boxes.first?.id
    }

    /// One row per buyer, most value first (owner, D25), then most cards, then
    /// name. Every current member AND virtual member is listed, even with nothing
    /// yet — a zero is information for the lead — and someone who has since left the
    /// team keeps their buys, as "Former member". A credited slab counts for the
    /// person it is credited to (V1), not for whoever scanned it.
    static func members(claims: [TeamClaim], roster: [TeamStore.Member], people: [TeamPerson] = [],
                        lens: PriceLens = .cl) -> [MemberTotal] {
        let counted = counted(claims)
        var buyers = BuyerResolver.choices(members: roster, people: people)
        let byClaim = counted.map { ($0, BuyerResolver.buyer(of: $0, members: roster, people: people)) }
        for (_, buyer) in byClaim where !buyers.contains(where: { $0.id == buyer.id }) { buyers.append(buyer) }
        return buyers.map { buyer in
            let theirs = byClaim.filter { $0.1.id == buyer.id }.map(\.0)
            let total = sum(theirs, lens)
            return MemberTotal(userId: buyer.id, name: buyer.name,
                               cards: theirs.count, cents: total.cents, valued: total.valued,
                               isVirtual: buyer.isVirtual)
        }
        .sorted {
            if $0.cents != $1.cents { return $0.cents > $1.cents }
            if $0.cards != $1.cards { return $0.cards > $1.cards }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// One buyer's receipt for a lot, newest buy first. `userId` is a `Buyer.id`.
    static func receipt(claims: [TeamClaim], userId: UUID, roster: [TeamStore.Member] = [],
                        people: [TeamPerson] = []) -> [TeamClaim] {
        counted(claims).filter { BuyerResolver.buyer(of: $0, members: roster, people: people).id == userId }
            .sorted { ($0.scannedDate ?? .distantPast) > ($1.scannedDate ?? .distantPast) }
    }
}
