import Testing
import Foundation
import SwiftData
@testable import Slab3

/// The 0.9 workflow test (2026-10-06): each case here is a bug found by walking a
/// feature end to end, pinned so it cannot come back. The server halves are in
/// supabase/tests/lot_archive_test.sql and team_people_test.sql.
@MainActor
struct WorkflowFixesTests {
    private let lead = UUID(), teamId = UUID(), lotId = UUID()

    private func claim(cert: String, credited: UUID? = nil, cl: Int? = 5_000, cy: Int? = nil,
                       cyConf: Int? = nil) -> TeamClaim {
        var c = TeamClaim(id: UUID(), lotId: lotId, rangeId: nil, cert: cert, grader: "psa", gradeLabel: "9",
                          priceCents: cl, clConfidence: 4, label: nil, player: "Charizard", cardSet: nil,
                          cardYear: nil, cardNumber: nil, imageUrl: nil, buyerId: lead, state: "confirmed",
                          scannedAt: "2026-10-06T10:00:00Z")
        c.creditedPersonId = credited
        c.cyPriceCents = cy
        c.cyConfidence = cyConf
        return c
    }

    private func card(_ cert: String, inLot: Bool, tag: Buyer?) -> Card {
        let card = Card(scan: CertScan(grader: .psa, certNumber: cert, raw: cert))
        if inLot { card.lotClaimLotId = lotId }
        card.creditedPersonId = tag?.id
        card.creditedName = tag?.name
        return card
    }

    // MARK: A lead's phone-only tag follows the card into a lot

    @Test func aTaggedCardFiledIntoALotCarriesItsTagToTheClaim() {
        let mike = Buyer(id: UUID(), name: "Mike", isVirtual: true)
        let a = card("11111111", inLot: true, tag: mike)
        let plan = CardTagging.carryPlan([a], claimsByLot: [lotId: [claim(cert: "11111111")]], choices: [mike])
        #expect(plan.count == 1)
        #expect(plan.first?.buyer == mike)
        #expect(plan.first?.cards.map(\.certNumber) == ["11111111"])
    }

    @Test func aCreditTheLeadChoseInTheReceiptIsNeverOverwritten() {
        let mike = Buyer(id: UUID(), name: "Mike", isVirtual: true)
        let a = card("11111111", inLot: true, tag: mike)
        let credited = claim(cert: "11111111", credited: UUID())
        #expect(CardTagging.carryPlan([a], claimsByLot: [lotId: [credited]], choices: [mike]).isEmpty)
    }

    @Test func aCardNotYetClaimedWaits() {
        // Pending, or outside any lot: nothing on the server to carry it to yet.
        let mike = Buyer(id: UUID(), name: "Mike", isVirtual: true)
        let pending = card("11111111", inLot: true, tag: mike)
        let plain = card("22222222", inLot: false, tag: mike)
        #expect(CardTagging.carryPlan([pending, plain], claimsByLot: [lotId: []], choices: [mike]).isEmpty)
    }

    @Test func carriesGroupByBuyerInFirstSeenOrder() {
        let mike = Buyer(id: UUID(), name: "Mike", isVirtual: true)
        let sam = Buyer(id: UUID(), name: "Sam", isVirtual: true)
        let cards = [card("11111111", inLot: true, tag: sam), card("22222222", inLot: true, tag: mike),
                     card("33333333", inLot: true, tag: sam)]
        let claims = [claim(cert: "11111111"), claim(cert: "22222222"), claim(cert: "33333333")]
        let plan = CardTagging.carryPlan(cards, claimsByLot: [lotId: claims], choices: [mike, sam])
        #expect(plan.map(\.buyer.name) == ["Sam", "Mike"])
        #expect(plan.first?.cards.count == 2)
    }

    @Test func aPersonOffTheRosterKeepsTheStoredName() {
        // tag() then fails on the server and the phone keeps the tag; the plan must
        // still name them rather than send a blank.
        let gone = Buyer(id: UUID(), name: "Old Mike", isVirtual: true)
        let a = card("11111111", inLot: true, tag: gone)
        let plan = CardTagging.carryPlan([a], claimsByLot: [lotId: [claim(cert: "11111111")]], choices: [])
        #expect(plan.first?.buyer.name == "Old Mike")
    }

    // MARK: The lead's max-buy knobs and lot bases survive a launch with no signal

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "slabs.test.policy.\(UUID().uuidString)")!
    }

    @Test func thePolicyIsRestoredAfterALaunch() {
        let defaults = scratchDefaults()
        let saved = MaxBuyTeamPolicy()
        let cyLot = UUID()
        saved.knobs = .init(skew: 0.4, margin: 0.12)
        saved.basisByLot = [cyLot: .cy, UUID(): .cl]
        saved.remember(in: defaults)

        let launched = MaxBuyTeamPolicy()
        launched.restore(from: defaults)
        #expect(launched.knobs == .init(skew: 0.4, margin: 0.12), "a member never prices on looser knobs offline")
        #expect(launched.basisByLot[cyLot] == .cy, "a CY lot's cards keep pricing on Courtyard offline")
    }

    @Test func aLoadThatAlreadyAnsweredWinsOverTheStoredCopy() {
        let defaults = scratchDefaults()
        let saved = MaxBuyTeamPolicy()
        saved.knobs = .init(skew: 0.4, margin: 0.12)
        saved.remember(in: defaults)

        let launched = MaxBuyTeamPolicy()
        launched.knobs = .init(skew: 0.5, margin: 0.2)
        launched.restore(from: defaults)
        #expect(launched.knobs == .init(skew: 0.5, margin: 0.2))
    }

    @Test func signingOutForgetsTheTeamsKnobs() {
        let defaults = scratchDefaults()
        let policy = MaxBuyTeamPolicy()
        policy.knobs = .init(skew: 0.4, margin: 0.12)
        policy.basisByLot = [UUID(): .cy]
        policy.remember(in: defaults)
        policy.forget(in: defaults)
        #expect(policy.knobs == nil && policy.basisByLot.isEmpty)

        let next = MaxBuyTeamPolicy()
        next.restore(from: defaults)
        #expect(next.knobs == nil, "the next account on this phone starts from its own knobs")
    }

    @Test func leavingTheTeamIsRememberedAsNoKnobs() {
        let defaults = scratchDefaults()
        let policy = MaxBuyTeamPolicy()
        policy.knobs = .init(skew: 0.4, margin: 0.12)
        policy.remember(in: defaults)
        policy.knobs = nil              // a successful load: no team, or the lead cleared them
        policy.remember(in: defaults)
        let launched = MaxBuyTeamPolicy()
        launched.restore(from: defaults)
        #expect(launched.knobs == nil)
    }

    // MARK: The lead's note is the lead's

    @Test func aRosterRowDecodesWithoutTheNote() throws {
        // Members are no longer granted the column, so the select omits it.
        let json = #"[{"id":"\#(UUID())","team_id":"\#(teamId)","display_name":"Mike","user_id":null,"link_code_at":null}]"#
        let people = try JSONDecoder().decode([TeamPerson].self, from: Data(json.utf8))
        #expect(people.first?.displayName == "Mike")
        #expect(people.first?.note == nil)
    }

    // MARK: A lead's whole-lot export carries what 0.9 claims record

    @Test func aTeammatesCourtyardValueReachesTheFile() {
        var lot = CSVExport.LotExport()
        lot.teammates = [.init(claim: claim(cert: "49385027", cl: 15_000, cy: 18_000, cyConf: 3), buyer: "Justin", bucket: nil),
                         .init(claim: claim(cert: "41066652", cl: nil, cy: nil), buyer: "Sam", bucket: nil)]
        let rows = CSVExport.rows([], columns: [.cert, .clPrice, .cyPrice, .cyConf],
                                  payoutPercent: nil, lot: lot)
        #expect(rows == [
            "cert,cl_price,cy_price,cy_conf",
            "49385027,150.00,180.00,3",
            "41066652,,,",
        ], "recorded at claim since 0.9; none recorded is still empty, never 0")
    }

    @Test func exportsFooterCountsTeammatesLikeOwnCards() {
        let both = claim(cert: "1", cl: 15_000, cy: 18_000)
        let clOnly = claim(cert: "2", cl: 9_000, cy: nil)
        #expect(CSVExport.teammateValue(both, preferring: .cy) == 18_000, "a CY toggle no longer adds CL")
        #expect(CSVExport.teammateValue(both, preferring: .cl) == 15_000)
        #expect(CSVExport.teammateValue(clOnly, preferring: .cy) == 9_000, "falls back, as PriceSet.best does")
        #expect(CSVExport.teammateValue(claim(cert: "3", cl: nil, cy: nil), preferring: .cl) == nil)
    }

    // MARK: Seller lists as they really arrive (manual cert tool)

    private func certs(_ text: String) -> [String] { CertListParser.extract(text).map(\.certNumber) }

    @Test func aTextedListWithPricesAndGrades() {
        let text = """
        1) PSA 10 Charizard 49385027 - $1,250
        2) PSA 9 Pikachu #66581638 $85.50
        3. CGC 9.5 Mewtwo 6055 074 171 — $300
        """
        #expect(certs(text) == ["49385027", "66581638", "6055074171"])
    }

    @Test func aSpreadsheetPasteWithTabsAndHeaders() {
        let text = "Cert\tGrade\tPrice\n49385027\t10\t1250.00\n66581638\t9\t85.50\n"
        #expect(certs(text) == ["49385027", "66581638"])
    }

    @Test func datesAndYearsAreNotCerts() {
        #expect(certs("Shipped 10/05/2026, 2023 Prizm #136: 49385027") == ["49385027"])
        #expect(certs("2026-10-05 49385027") == ["49385027"])
    }

    @Test func bulletsAndEmojiDoNotHideACert() {
        #expect(certs("• 49385027 🔥\n- 66581638 ✅") == ["49385027", "66581638"])
    }
}
