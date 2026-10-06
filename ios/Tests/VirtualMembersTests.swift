import Testing
import Foundation
import SwiftData
@testable import Slab3

/// Virtual members (V1–V6, 2026-10-04): who a slab's buyer is after credit, and that
/// every place showing a buyer — Team activity, receipts, the CSV, the detail
/// screen — reads the same answer. The server half is pinned by
/// supabase/tests/team_people_test.sql.
@MainActor
struct VirtualMembersTests {
    private let lead = UUID(), buyer = UUID(), teamId = UUID(), lotId = UUID()

    private var roster: [TeamStore.Member] {
        [TeamStore.Member(userId: lead, role: .lead, displayName: "Lead"),
         TeamStore.Member(userId: buyer, role: .buyer, displayName: "Justin")]
    }

    private func person(_ name: String, userId: UUID? = nil, id: UUID = UUID()) -> TeamPerson {
        TeamPerson(id: id, teamId: teamId, displayName: name, note: nil, userId: userId, linkCodeAt: nil)
    }

    private func claim(by scanner: UUID, credited: UUID? = nil, cents: Int? = 5_000,
                       cert: String = String(Int.random(in: 1...99_999_999))) -> TeamClaim {
        var c = TeamClaim(id: UUID(), lotId: lotId, rangeId: nil, cert: cert, grader: "psa", gradeLabel: "9",
                          priceCents: cents, clConfidence: 4, label: nil, player: "Charizard", cardSet: nil,
                          cardYear: nil, cardNumber: nil, imageUrl: nil, buyerId: scanner, state: "confirmed",
                          scannedAt: "2026-10-04T10:00:00Z")
        c.creditedPersonId = credited
        return c
    }

    // MARK: BuyerResolver — the one rule

    @Test func anUncreditedSlabIsTheScanners() {
        let b = BuyerResolver.buyer(of: claim(by: buyer), members: roster, people: [])
        #expect(b == Buyer(id: buyer, name: "Justin", isVirtual: false))
    }

    @Test func aCreditedSlabIsThePersons() {
        let mike = person("Mike")
        let b = BuyerResolver.buyer(of: claim(by: lead, credited: mike.id), members: roster, people: [mike])
        #expect(b == Buyer(id: mike.id, name: "Mike", isVirtual: true), "V1: the virtual member replaces the buyer")
    }

    @Test func creditToAMembersRowIsThatMember() {
        // A virtual entry merged into Justin: credit and Justin's own scans must add up.
        let row = person("Mike (old)", userId: buyer)
        let b = BuyerResolver.buyer(of: claim(by: lead, credited: row.id), members: roster, people: [row])
        #expect(b == Buyer(id: buyer, name: "Justin", isVirtual: false))
    }

    @Test func aLinkedConsignorIsNotVirtualButIsNotAMember() {
        let mike = person("Mike", userId: UUID())
        let b = BuyerResolver.buyer(of: claim(by: lead, credited: mike.id), members: roster, people: [mike])
        #expect(b.id == mike.id && !b.isVirtual)
    }

    @Test func creditToSomeoneNoLongerOnTheRosterFallsBackToTheScanner() {
        let b = BuyerResolver.buyer(of: claim(by: lead, credited: UUID()), members: roster, people: [])
        #expect(b.id == lead)
    }

    @Test func choicesListMembersThenOthersByNameWithMemberRowsFolded() {
        let choices = BuyerResolver.choices(members: roster, people: [
            person("zed"), person("Amy"), person("Justin's row", userId: buyer),
        ])
        #expect(choices.map(\.name) == ["Lead", "Justin", "Amy", "zed"])
    }

    // MARK: Team activity follows credit

    @Test func activityCountsCreditedSlabsForThePersonAndListsZeroes() {
        let mike = person("Mike"), sam = person("Sam")
        let claims = [claim(by: lead, credited: mike.id, cents: 7_000),
                      claim(by: lead, credited: mike.id, cents: 3_000),
                      claim(by: lead, cents: 1_000)]
        let rows = TeamActivity.members(claims: claims, roster: roster, people: [mike, sam])
        #expect(rows.first?.name == "Mike" && rows.first?.cards == 2 && rows.first?.cents == 10_000)
        #expect(rows.first?.isVirtual == true)
        #expect(rows.first { $0.userId == lead }?.cards == 1, "the lead keeps only what is not credited away")
        #expect(rows.first { $0.userId == sam.id }?.cards == 0, "a virtual member with nothing yet still shows")
    }

    @Test func aReceiptIsAddressedByBuyerId() {
        let mike = person("Mike")
        let mine = claim(by: lead), his = claim(by: lead, credited: mike.id)
        let receipt = TeamActivity.receipt(claims: [mine, his], userId: mike.id, roster: roster, people: [mike])
        #expect(receipt == [his])
        #expect(TeamActivity.receipt(claims: [mine, his], userId: lead, roster: roster, people: [mike]) == [mine])
    }

    // MARK: Card tags — the claim wins, local tags follow the roster

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Card.self, Folder.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    @Test func aLotSlabsBuyerIsItsClaimsNotItsLocalTag() {
        let mike = person("Mike")
        let card = Card(scan: CertScan(grader: .psa, certNumber: "66581638", raw: "66581638"))
        card.lotClaimLotId = lotId
        card.creditedName = "Stale local tag"
        card.creditedPersonId = UUID()
        let claims = [lotId: [claim(by: lead, credited: mike.id, cert: "66581638")]]
        #expect(CardTagging.buyerName(for: card, claimsByLot: claims, members: roster, people: [mike]) == "Mike")
    }

    @Test func aLocalTagReadsTheLiveNameThenTheStoredOne() {
        let mike = person("Mike R")
        let card = Card(scan: CertScan(grader: .psa, certNumber: "1", raw: "1"))
        card.creditedPersonId = mike.id
        card.creditedName = "Mike"
        #expect(CardTagging.buyerName(for: card, claimsByLot: [:], members: roster, people: [mike]) == "Mike R")
        #expect(CardTagging.buyerName(for: card, claimsByLot: [:], members: roster, people: []) == "Mike",
                "removed from the roster, or the user left the team: the stored name still exports")
        let untagged = Card(scan: CertScan(grader: .psa, certNumber: "2", raw: "2"))
        #expect(CardTagging.buyerName(for: untagged, claimsByLot: [:], members: roster, people: [mike]) == nil)
    }

    @Test func tagIsLocalForCardsOutsideALot() async throws {
        let context = try store()
        let card = Card(scan: CertScan(grader: .psa, certNumber: "3", raw: "3"))
        context.insert(card)
        let mike = Buyer(id: UUID(), name: "Mike", isVirtual: true)
        let note = await CardTagging.tag([card], to: mike, team: TeamStore(), lots: LotStore(), in: context)
        #expect(note == nil)
        #expect(card.creditedPersonId == mike.id && card.creditedName == "Mike")
        _ = await CardTagging.tag([card], to: nil, team: TeamStore(), lots: LotStore(), in: context)
        #expect(card.creditedPersonId == nil && card.creditedName == nil)
    }

    @Test func aMergeMovesThisPhonesTags() throws {
        let context = try store()
        let absorbed = UUID()
        let card = Card(scan: CertScan(grader: .psa, certNumber: "4", raw: "4"))
        card.creditedPersonId = absorbed
        card.creditedName = "Michael"
        let other = Card(scan: CertScan(grader: .psa, certNumber: "5", raw: "5"))
        context.insert(card); context.insert(other)
        let keep = Buyer(id: UUID(), name: "Mike", isVirtual: true)
        CardTagging.retag(from: absorbed, to: keep, in: context)
        #expect(card.creditedPersonId == keep.id && card.creditedName == "Mike")
        #expect(other.creditedPersonId == nil)
    }

    // MARK: Export (V3)

    @Test func theBuyerColumnIsOnEveryExport() {
        let card = Card(scan: CertScan(grader: .psa, certNumber: "66581638", raw: "66581638"))
        let untagged = Card(scan: CertScan(grader: .psa, certNumber: "41066652", raw: "41066652"))
        let rows = CSVExport.rows([card, untagged], columns: [.cert, .buyer], payoutPercent: nil,
                                  buyers: [card.localId: "Mike"])
        #expect(rows == ["cert,buyer", "66581638,Mike", "41066652,"], "no buyer is an empty cell")
    }

    // MARK: The consignor's receipt (V5)

    @Test func creditedCardsDecodeAndValueInTheLotsBasis() throws {
        let json = """
        [{"claim_id":"\(UUID())","cert":"7001","grader":"psa","grade_label":"9","label":null,"player":"Charizard",
          "card_set":null,"card_year":"1999","card_number":null,"image_url":null,"price_cents":5000,
          "cl_confidence":4,"cy_price_cents":null,"cy_confidence":null,"state":"confirmed",
          "scanned_at":"2026-10-04T10:00:00+00:00","claimed_at":"2026-10-04T10:00:01+00:00",
          "lot_id":"\(lotId)","lot_name":"Show","value_basis":"cy","team_name":"People",
          "person_name":"Mike","added_by":"Lead"}]
        """
        let cards = try JSONDecoder().decode([CreditedCard].self, from: Data(json.utf8))
        #expect(cards.first?.title == "Charizard")
        #expect(cards.first?.valueCents == nil, "a CY lot with no CY value is an em dash, not the CL figure")
        #expect(cards.first?.basisLabel == "CY")
    }

    @Test func myCardsGroupByTeamAndLotInArrivalOrder() throws {
        func card(_ team: String, _ lot: String) throws -> CreditedCard {
            try JSONDecoder().decode(CreditedCard.self, from: Data("""
            {"claim_id":"\(UUID())","cert":"1","grader":"psa","grade_label":null,"label":null,"player":null,
             "card_set":null,"card_year":null,"image_url":null,"price_cents":null,"cy_price_cents":null,
             "state":"confirmed","scanned_at":null,"lot_id":"\(UUID())","lot_name":"\(lot)",
             "value_basis":"cl","team_name":"\(team)","added_by":"Lead"}
            """.utf8))
        }
        let sections = MyCardsSheet.sections([try card("A", "Oct"), try card("B", "Show"), try card("A", "Oct")])
        #expect(sections.map(\.key) == ["A · Oct", "B · Show"])
        #expect(sections.first?.cards.count == 2)
    }
}
