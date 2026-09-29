import Foundation

/// The lead's Team activity numbers (teams-first plan, D17–D27), derived and
/// nothing else.
///
/// WHAT IT IS FOR. The lead runs the team; this answers "how many cards has each
/// person contributed to this lot, and which ones" — with the full receipt, card
/// by card. It is not a price tool: every dollar here is **CL Value at the moment
/// of the claim** (`lot_claims.price_cents`), which is what the lot's budgets are
/// counted in. The app never learns what a buyer actually paid, so no figure here
/// may be labelled as "spent".
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
        var id: UUID { lot.id }
    }

    struct MemberTotal: Identifiable, Equatable {
        let userId: UUID
        let name: String
        let cards: Int
        let cents: Int64
        var id: UUID { userId }
    }

    /// The slabs that count: in the lot, confirmed or over the limit.
    static func counted(_ claims: [TeamClaim]) -> [TeamClaim] {
        claims.filter { $0.state == "confirmed" || $0.state == "over_limit" }
    }

    /// Every lot a lead can review, open ones first by deadline (soonest, then no
    /// deadline), then closed ones newest first. Drafts have no buys to show.
    static func boxes(lots: [Lot], claimsByLot: [UUID: [TeamClaim]]) -> [LotBox] {
        let open = lots.filter { $0.status == .active }.sorted(by: Lot.soonestFirst)
        let closed = lots.filter { $0.status == .closed }.sorted { $0.createdAt > $1.createdAt }
        return (open + closed).map { lot in
            let claims = counted(claimsByLot[lot.id] ?? [])
            return LotBox(lot: lot, cards: claims.count,
                          cents: claims.reduce(0) { $0 + Int64($1.priceCents ?? 0) })
        }
    }

    /// The box to open on: the lot being scanned into, else the first.
    static func defaultLot(current: UUID?, boxes: [LotBox]) -> UUID? {
        if let current, boxes.contains(where: { $0.id == current }) { return current }
        return boxes.first?.id
    }

    /// One row per person, most CL value first (owner, D25), then most cards, then
    /// name. Every current member is listed, even with nothing yet — a zero is
    /// information for the lead — and someone who has since left the team keeps
    /// their buys, as "Former member".
    static func members(claims: [TeamClaim], roster: [TeamStore.Member]) -> [MemberTotal] {
        let counted = counted(claims)
        var ids = roster.map(\.userId)
        for claim in counted where !ids.contains(claim.buyerId) { ids.append(claim.buyerId) }
        return ids.map { id in
            let theirs = counted.filter { $0.buyerId == id }
            return MemberTotal(userId: id,
                               name: roster.first { $0.userId == id }?.displayName ?? "Former member",
                               cards: theirs.count,
                               cents: theirs.reduce(0) { $0 + Int64($1.priceCents ?? 0) })
        }
        .sorted {
            if $0.cents != $1.cents { return $0.cents > $1.cents }
            if $0.cards != $1.cards { return $0.cards > $1.cards }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// One person's receipt for a lot, newest buy first.
    static func receipt(claims: [TeamClaim], userId: UUID) -> [TeamClaim] {
        counted(claims).filter { $0.buyerId == userId }
            .sorted { ($0.scannedDate ?? .distantPast) > ($1.scannedDate ?? .distantPast) }
    }
}
