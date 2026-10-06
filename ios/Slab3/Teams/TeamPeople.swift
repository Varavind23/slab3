import Foundation

// Virtual members (owner decisions V1–V6, 2026-10-04;
// ~/.claude/plans/pasted-content-id-960f-i-want-memoized-heron.md).
//
// A lead's consignors hand over stacks of slabs but never open the app, so the
// lead scans everything and every claim said the LEAD bought it. A `TeamPerson` is
// someone the lead tracks on the roster — usually with no account (virtual), later
// maybe linked to one. Tagging a slab to a person makes them its BUYER everywhere a
// buyer is shown (V1): Team activity, receipts, the CSV. The scanning account is
// kept as "added by".
//
// Server: supabase/migrations/20261004000000_team_people.sql. A linked person is
// NOT a team member — linking grants only my_credited_cards (read-only, V5).

/// One roster entry. `userId` nil = virtual.
struct TeamPerson: Identifiable, Equatable, Decodable {
    let id: UUID
    let teamId: UUID
    var displayName: String
    var note: String?
    var userId: UUID?
    /// When the current invite was made; the code itself is never selectable
    /// (column grant) — only `invite_person` returns it, to a lead.
    var linkCodeAt: String?

    var isVirtual: Bool { userId == nil }

    enum CodingKeys: String, CodingKey {
        case id, note
        case teamId = "team_id", displayName = "display_name", userId = "user_id", linkCodeAt = "link_code_at"
    }
}

/// Who bought a slab, after credit (V1). `id` is a team member's user id or a
/// virtual person's id — both UUIDs, never confused in practice, so a receipt can be
/// addressed by either.
struct Buyer: Hashable, Identifiable {
    let id: UUID
    let name: String
    /// A roster entry with no account on this team — drawn as "Virtual".
    let isVirtual: Bool
}

enum BuyerResolver {
    /// The one rule every screen and the CSV share:
    /// - credited to a person who is a team MEMBER (their own row, or a virtual entry
    ///   merged into them) → that member, so their scans and their credit add up;
    /// - credited to anyone else → that person;
    /// - not credited, or the person is gone → the scanning account.
    static func buyer(creditedPersonId: UUID?, buyerId: UUID,
                      members: [TeamStore.Member], people: [TeamPerson]) -> Buyer {
        if let pid = creditedPersonId, let person = people.first(where: { $0.id == pid }) {
            if let uid = person.userId, let member = members.first(where: { $0.userId == uid }) {
                return Buyer(id: uid, name: member.displayName, isVirtual: false)
            }
            return Buyer(id: person.id, name: person.displayName, isVirtual: person.userId == nil)
        }
        return Buyer(id: buyerId,
                     name: members.first { $0.userId == buyerId }?.displayName ?? "Former member",
                     isVirtual: false)
    }

    static func buyer(of claim: TeamClaim, members: [TeamStore.Member], people: [TeamPerson]) -> Buyer {
        buyer(creditedPersonId: claim.creditedPersonId, buyerId: claim.buyerId, members: members, people: people)
    }

    /// Everyone a slab can be credited to, as the tag picker lists them: members
    /// first (as on the Members sheet), then people who are not members, by name.
    /// A person row that IS a member is folded into that member.
    static func choices(members: [TeamStore.Member], people: [TeamPerson]) -> [Buyer] {
        let memberIds = Set(members.map(\.userId))
        let others = people.filter { $0.userId.map { !memberIds.contains($0) } ?? true }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return members.map { Buyer(id: $0.userId, name: $0.displayName, isVirtual: false) }
            + others.map { Buyer(id: $0.id, name: $0.displayName, isVirtual: $0.userId == nil) }
    }

    /// The person id to send for a picked buyer: a person's own id, or nil for a
    /// MEMBER — the caller asks the server for the member's row (member_person).
    static func personId(for buyer: Buyer, people: [TeamPerson]) -> UUID? {
        people.first { $0.id == buyer.id }?.id
    }
}

/// A slab credited to the signed-in user by someone else's team (my_credited_cards,
/// V5). Read-only, frozen at claim time.
struct CreditedCard: Identifiable, Equatable, Decodable {
    let claimId: UUID
    let cert: String
    let grader: String
    let gradeLabel: String?
    let label: String?
    let player: String?
    let cardSet: String?
    let cardYear: String?
    let imageUrl: String?
    let priceCents: Int?
    let cyPriceCents: Int?
    let state: String
    let scannedAt: String?
    let lotId: UUID
    let lotName: String
    let valueBasis: String?
    let teamName: String
    let addedBy: String

    var id: UUID { claimId }
    var title: String { label ?? player ?? "#\(cert)" }
    var scannedDate: Date? { scannedAt.flatMap(ISO8601.date) }
    /// The figure in the lot's own basis — what the lot counted it at.
    var valueCents: Int? { valueBasis == "cy" ? cyPriceCents : priceCents }
    var basisLabel: String { valueBasis == "cy" ? "CY" : "CL" }

    enum CodingKeys: String, CodingKey {
        case cert, grader, label, player, state
        case claimId = "claim_id", gradeLabel = "grade_label", cardSet = "card_set", cardYear = "card_year"
        case imageUrl = "image_url", priceCents = "price_cents", cyPriceCents = "cy_price_cents"
        case scannedAt = "scanned_at", lotId = "lot_id", lotName = "lot_name", valueBasis = "value_basis"
        case teamName = "team_name", addedBy = "added_by"
    }
}

/// A roster entry on someone else's team that this account is linked to (my_links).
struct PersonLink: Identifiable, Equatable, Decodable {
    let personId: UUID
    let teamName: String
    let displayName: String
    var id: UUID { personId }
    enum CodingKeys: String, CodingKey {
        case personId = "person_id", teamName = "team_name", displayName = "display_name"
    }
}
