import Foundation
import Testing
@testable import Slab3

/// Lot claims (teams phase 4): the server's replies decode into the verdict the
/// card keeps, and each verdict reads as a line a buyer understands at a glance.
/// The reply shapes are the ones claim_lot_scan returned in the 2026-09-25
/// real-data run against the local stack.
@MainActor
struct LotClaimTests {
    private func verdict(_ json: String) throws -> LotVerdict {
        try LotVerdict.decode(Data(json.utf8))
    }

    @Test func confirmedCarriesTheBucketAndCopyCount() throws {
        let v = try verdict("""
        {"outcome":"confirmed","claim":{"lot_buy_range_id":"8a1f2c1e-2f6b-4f7f-9c62-3f1d8e0b7a11","warn_reasons":["near_range_edge"]},
         "range":{"range_id":"8a1f2c1e-2f6b-4f7f-9c62-3f1d8e0b7a11","name":"$100 – $240"},
         "copies":2,"range_cards":2,"range_cents":31050,"warn_reasons":["near_range_edge"]}
        """)
        #expect(v.state == .confirmed)
        #expect(v.rangeName == "$100 – $240")
        #expect(LotVerdictText.line(state: v.state, verdict: v).text == "In $100 – $240 · 2 of 3 · near edge")
        #expect(LotVerdictText.line(state: v.state, verdict: v).tone == .good)
    }

    @Test func aLimitBlockListsTheThreeBuys() throws {
        let v = try verdict("""
        {"outcome":"blocked","reason":"limit_reached","existing":[
          {"buyer":"Justin","scanned_at":"2026-09-25T17:42:00+00:00","cert":"1"},
          {"buyer":"Sam","scanned_at":"2026-09-25T18:01:00.123+00:00","cert":"2"},
          {"buyer":"Lead","scanned_at":"2026-09-25T18:30:00Z","cert":"3"}]}
        """)
        #expect(v.state == .blocked)
        #expect(v.existing.map(\.buyer) == ["Justin", "Sam", "Lead"])
        #expect(v.existing.allSatisfy { $0.scannedAt != nil }, "every Postgres timestamp shape parses")
        #expect(LotVerdictText.line(state: v.state, verdict: v).text == "Not in lot — 3 already bought")
        #expect(LotVerdictText.line(state: v.state, verdict: v).tone == .warn, "amber, never red")
    }

    @Test func choosingListsTheCandidates() throws {
        let v = try verdict("""
        {"outcome":"choose_range","price_cents":9300,"candidates":[
          {"range_id":"11111111-1111-1111-1111-111111111111","name":"$75 – $150","cards_left":400,"cents_left":5000000},
          {"range_id":"22222222-2222-2222-2222-222222222222","name":"$50 – $100","cards_left":12,"cents_left":342000}]}
        """)
        #expect(v.state == .chooseRange)
        #expect(v.candidates.map(\.name) == ["$75 – $150", "$50 – $100"])
        #expect(v.candidates[1].centsLeft == 342_000)
        #expect(LotVerdictText.line(state: v.state, verdict: v).text == "Pick a bucket · fits 2")
    }

    @Test func aMissBlockSaysWhichRuleItFailed() throws {
        let grade = try verdict(#"{"outcome":"blocked","reason":"no_matching_range","failed":"grade","grade":"6","price_cents":5000}"#)
        #expect(LotVerdictText.line(state: .blocked, verdict: grade).text == "Not in lot — grade 6 fits no bucket")
        let value = try verdict(#"{"outcome":"blocked","reason":"no_matching_range","failed":"value","price_cents":951}"#)
        #expect(LotVerdictText.line(state: .blocked, verdict: value).text == "Not in lot — no bucket at $9.51")
        let noValue = try verdict(#"{"outcome":"blocked","reason":"no_cl_value"}"#)
        #expect(LotVerdictText.line(state: .blocked, verdict: noValue).text == "Not in lot — no Card Ladder value")
        let dup = try verdict(#"{"outcome":"blocked","reason":"duplicate_cert","by":"Lead"}"#)
        #expect(LotVerdictText.line(state: .blocked, verdict: dup).text == "Not in lot — Lead already has this slab")
    }

    @Test func pendingIsNeverAGreenLight() throws {
        let cold = try verdict(#"{"outcome":"pending","reason":"pending_price"}"#)
        #expect(cold.state == .pending)
        #expect(LotVerdictText.line(state: .pending, verdict: cold).tone == .warn)
        let noCL = LotVerdict(outcome: "pending", reason: "cl_not_connected")
        #expect(LotVerdictText.line(state: .pending, verdict: noCL).text == "Lot · connect Card Ladder to claim")
    }

    @Test func aVerdictRoundTripsOnTheCard() throws {
        let card = Card(scan: CertScan(grader: .psa, certNumber: "66581638", raw: "66581638"))
        card.lotClaimState = .confirmed
        card.lotVerdict = LotVerdict(outcome: "confirmed", rangeName: "$100 – $240", copies: 1)
        #expect(card.lotVerdict?.rangeName == "$100 – $240")
        #expect(card.holdsLotSlot)
        card.lotClaimState = .blocked
        #expect(!card.holdsLotSlot, "a blocked card holds nothing to release")
    }
}
