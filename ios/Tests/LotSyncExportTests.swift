import Foundation
import SwiftData
import Testing
@testable import Slab3

/// Teams, the rest of it: the buyer's reported figures beside the team's, the
/// offline sync summary, reconciling a slab a lead released, and the lead's
/// whole-lot CSV.
@MainActor
struct LotSyncExportTests {

    private func bucket(_ budget: Int64, used: Int64) -> LotDashboard.Bucket {
        let r = BuyRange(id: UUID(), name: "b", valueMinCents: 0, valueMaxCents: 10_000, gradeMin: 7, gradeMax: 10,
                         clConfMin: nil, clConfMax: nil, yearMin: nil, yearMax: nil, maxCards: 400,
                         budgetCents: budget, notes: nil)
        return LotDashboard.Bucket(range: r, usedCents: used, cards: 1)
    }

    private func report(_ b: LotDashboard.Bucket, cents: Int64, cards: Int?, at: String) -> RangeReport {
        try! JSONDecoder().decode(RangeReport.self, from: Data("""
        {"lot_buy_range_id":"\(b.id)","used_cents":\(cents),"card_count":\(cards.map(String.init) ?? "null"),"reported_at":"\(at)"}
        """.utf8))
    }

    // MARK: Reported beside bought

    @Test func reportedSumsAndIsDatedByTheStalestBucket() {
        let a = bucket(2_000_000, used: 1_000_000), b = bucket(2_000_000, used: 500_000)
        let reports = [a.id: report(a, cents: 990_000, cards: 100, at: "2026-09-24T09:12:00Z"),
                       b.id: report(b, cents: 400_000, cards: 50, at: "2026-09-25T10:00:00Z")]
        let r = LotDashboard.reported([a, b], reports: reports)!
        #expect(r.usedCents == 1_390_000)
        #expect(r.cards == 150)
        #expect(r.asOf == ISO8601.date("2026-09-24T09:12:00Z"), "a band is as current as its stalest bucket")
        #expect(r.gapCents == 110_000, "bought $15,000, reported $13,900")
        #expect(r.gapMatters, "$1,100 on a $40,000 allocation is past 2%")
    }

    @Test func aSmallGapIsNotShouted() {
        let a = bucket(10_000_000, used: 1_000_000)
        let r = LotDashboard.reported([a], reports: [a.id: report(a, cents: 997_000, cards: nil, at: "2026-09-24T09:12:00Z")])!
        #expect(r.gapCents == 3_000)
        #expect(!r.gapMatters, "$30 is rounding and timing, not a rejected submission")
        #expect(r.cards == nil, "a missing count is not zero cards")
        #expect(LotDashboard.reported([a], reports: [:]) == nil, "never reported: no line at all")

        let big = bucket(20_000_000, used: 0), small = bucket(2_600_000, used: 600_000)
        let one = LotDashboard.reported([big, small],
                                        reports: [small.id: report(small, cents: 520_000, cards: 61, at: "2026-09-24T09:12:00Z")])!
        #expect(one.gapCents == 80_000)
        #expect(one.gapMatters, "$800 against the one reported $26,000 bucket, not the whole band's $226,000")
    }

    // MARK: Offline

    @Test func theSyncSummaryReadsLikeTheReconnectBar() {
        var s = LotClaims.SyncSummary()
        s.synced = 5; s.inLot = 3; s.overLimit = 1; s.notInLot = 1
        #expect(s.line == "Synced 5 offline scans · 3 in lot · 1 over limit · 1 not in lot")
        let offline = LotVerdict(outcome: "pending", reason: "network")
        #expect(LotVerdictText.line(state: .pending, verdict: offline).text == "Unverified · syncs when online")
    }

    // MARK: A lead released one of this phone's slabs

    private let me = UUID(), lotId = UUID()

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Card.self, Folder.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func heldCard(_ cert: String, answeredAt: Date, in context: ModelContext, group: Folder) -> Card {
        let card = Card(scan: CertScan(grader: .psa, certNumber: cert, raw: cert))
        context.insert(card)
        card.folder = group
        card.lotClaimLotId = lotId
        card.lotClaimState = .confirmed
        card.lotVerdict = LotVerdict(outcome: "confirmed", rangeName: "$0 – $100", copies: 1, answeredAt: answeredAt)
        return card
    }

    @Test func aReleasedSlabGoesBackToInventoryAndSaysWhy() throws {
        let context = try store()
        let group = Folder(name: "Show 7/24"); group.teamLotId = lotId; context.insert(group)
        let loadedAt = Date()
        let released = heldCard("11111111", answeredAt: loadedAt.addingTimeInterval(-60), in: context, group: group)
        let justClaimed = heldCard("22222222", answeredAt: loadedAt.addingTimeInterval(2), in: context, group: group)
        let lot = Lot(id: lotId, name: "Show 7/24", deadline: nil, status: .active, createdAt: Date())

        LotClaims.reconcile([lotId: []], lots: [lot], loadedAt: loadedAt, myUserId: me, in: context)

        #expect(released.lotClaimState == .blocked)
        #expect(released.folder == nil, "back in plain inventory")
        #expect(LotVerdictText.line(state: .blocked, verdict: released.lotVerdict).text == "Not in lot — released by a lead")
        #expect(justClaimed.lotClaimState == .confirmed, "newer than the list is not missing, just newer")
        #expect(justClaimed.folder === group)
    }

    /// Inventory is per phone: signed into a second account, the phone still holds
    /// the first account's lot cards. Those are not this account's to call released.
    @Test func anotherAccountsClaimOnThisPhoneIsLeftAlone() throws {
        let context = try store()
        let group = Folder(name: "Show 7/24"); group.teamLotId = lotId; context.insert(group)
        let loadedAt = Date()
        let theirs = heldCard("33333333", answeredAt: loadedAt.addingTimeInterval(-60), in: context, group: group)
        theirs.lotVerdict?.buyerId = UUID()                      // claimed by someone else
        let lot = Lot(id: lotId, name: "Show 7/24", deadline: nil, status: .active, createdAt: Date())

        LotClaims.reconcile([lotId: []], lots: [lot], loadedAt: loadedAt, myUserId: me, in: context)

        #expect(theirs.lotClaimState == .confirmed, "never labelled 'released by a lead'")
        #expect(theirs.folder === group)
    }

    @Test func aClaimRemembersWhoHoldsIt() throws {
        let buyer = UUID()
        let verdict = try LotVerdict.decode(Data("""
        {"outcome":"confirmed","claim":{"lot_buy_range_id":null,"warn_reasons":[],"buyer_id":"\(buyer)"},"copies":1}
        """.utf8))
        #expect(verdict.buyerId == buyer)
    }

    // MARK: The lead's whole-lot CSV

    private func claim(_ cert: String, price: Int?) -> TeamClaim {
        try! JSONDecoder().decode(TeamClaim.self, from: Data("""
        {"id":"\(UUID())","lot_id":"\(lotId)","lot_buy_range_id":null,"cert":"\(cert)","grader":"psa",
         "grade_label":"10","price_cents":\(price.map(String.init) ?? "null"),"cl_confidence":5,
         "label":"2022 Pokemon Go #011 Radiant Charizard","player":"Radiant Charizard","card_set":"Pokemon Go",
         "card_year":"2022","card_number":"011","image_url":null,"buyer_id":"\(UUID())",
         "state":"confirmed","scanned_at":"2026-09-25T18:30:00+00:00"}
        """.utf8))
    }

    @Test func lotColumnsNeverLeakIntoAnOrdinaryExport() {
        let card = Card(scan: CertScan(grader: .psa, certNumber: "66581638", raw: "66581638"))
        let rows = CSVExport.rows([card], columns: [.cert, .buyer, .bucket], payoutPercent: nil)
        #expect(rows[0] == "cert", "buyer/bucket exist only in a lot export")
        #expect(!CSVColumn.available(testingUnlocked: true).contains(.buyer))
        #expect(CSVColumn.available(testingUnlocked: false, lot: true).contains(.bucket))
    }

    @Test func aLeadsLotExportIsTheWholeLot() {
        let card = Card(scan: CertScan(grader: .psa, certNumber: "66581638", raw: "66581638"))
        card.cardLadderPriceCents = 16_050
        var lot = CSVExport.LotExport()
        lot.buyerByCard[card.localId] = "Lead"
        lot.bucketByCard[card.localId] = "$100 – $240"
        lot.teammates = [.init(claim: claim("110578584", price: 15_000), buyer: "Justin", bucket: "$100 – $240"),
                         .init(claim: claim("41066652", price: nil), buyer: "Sam", bucket: nil)]
        let rows = CSVExport.rows([card], columns: [.cert, .clPrice, .cyPrice, .buyer, .bucket],
                                  payoutPercent: nil, lot: lot)
        #expect(rows == [
            "cert,cl_price,cy_price,buyer,bucket",
            "66581638,160.50,,Lead,$100 – $240",
            "110578584,150.00,,Justin,$100 – $240",
            "41066652,,,Sam,",
        ], "a teammate's Courtyard cell is empty, never 0 — this phone never priced it")
    }
}
