import Testing
import Foundation
import SwiftData
@testable import Slab3

/// The 0.9 client side of a lot's CL/CY basis and a team's max-buy settings
/// (owner M1–M6, 2026-10-01; ~/.claude/plans/max-buy-for-teams-and-lot-basis.md).
///
/// The server's half — what a claim decides on, the switch, the 3-limit — is pinned
/// in supabase/tests/lot_basis_test.sql. What is pinned here is what the PHONE does
/// with it: which figure each view reads, how a missing one is reported rather than
/// summed as $0, the team's knobs replacing a member's, and max buy on a CY lot
/// pricing on Courtyard alone.
@MainActor
struct LotBasisTests {

    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func claim(cl: Int?, cy: Int?, max: Int?, state: String = "confirmed") -> TeamClaim {
        TeamClaim(id: UUID(), lotId: UUID(), rangeId: nil, cert: String(Int.random(in: 1...99_999_999)),
                  grader: "psa", gradeLabel: "9", priceCents: cl, clConfidence: 4, label: nil,
                  player: "Curry", cardSet: nil, cardYear: nil, cardNumber: nil, imageUrl: nil,
                  buyerId: UUID(), state: state, scannedAt: "2026-10-04T10:00:00Z",
                  cyPriceCents: cy, maxBuyCents: max)
    }

    // ── What a claim carries ──────────────────────────────────────────────────

    @Test func aClaimReadsEachFigureFromItsOwnColumn() {
        let c = claim(cl: 5000, cy: 15000, max: 4100)
        #expect(c.value(in: .cl) == 5000)
        #expect(c.value(in: .cy) == 15000)
        #expect(c.cents(in: .maxBuy) == 4100)
        #expect(c.cents(in: .cy) == 15000)
    }

    @Test func aLotWithNoBasisFromTheServerIsCL() throws {
        // An older server, or a lot from before the migration: CL, which every lot was.
        let json = #"{"id":"6f1c2d3e-0000-4000-8000-000000000001","name":"Show","deadline":null,"status":"active","banner":null,"created_at":"2026-10-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Lot.self, from: Data(json.utf8)).valueBasis == .cl)
        let cy = json.replacingOccurrences(of: #""banner":null"#, with: #""banner":null,"value_basis":"cy""#)
        #expect(try decoder.decode(Lot.self, from: Data(cy.utf8)).valueBasis == .cy)
    }

    @Test func everyLotDollarNamesItsBasis() {
        #expect(ValueBasis.cl.valueAtClaim == "CL value at claim")
        #expect(ValueBasis.cy.valueAtClaim == "CY value at claim")
        #expect(PriceLens.maxBuy.atClaim == "Max buy at claim")
        #expect(PriceLens.cy.atClaim == "CY value at claim")
    }

    // ── Team activity's MAX · CL · CY (M6) ────────────────────────────────────

    @Test func activityTotalsFollowTheChosenView() {
        let lot = Lot(id: UUID(), name: "Show", deadline: nil, status: .active, createdAt: Date())
        let claims = [claim(cl: 5000, cy: 15000, max: 4100), claim(cl: 2000, cy: nil, max: nil)]
        let byLot = [lot.id: claims]
        #expect(TeamActivity.boxes(lots: [lot], claimsByLot: byLot, lens: .cl).first?.cents == 7000)
        #expect(TeamActivity.boxes(lots: [lot], claimsByLot: byLot, lens: .cy).first?.cents == 15000)
        #expect(TeamActivity.boxes(lots: [lot], claimsByLot: byLot, lens: .maxBuy).first?.cents == 4100)
    }

    @Test func aShortSumSaysItIsShort() {
        // A claim with no figure in this view adds nothing — and the screen says how
        // many it covers, rather than passing the sum off as the whole lot.
        let lot = Lot(id: UUID(), name: "Show", deadline: nil, status: .active, createdAt: Date())
        let box = TeamActivity.boxes(lots: [lot], claimsByLot: [lot.id: [
            claim(cl: 5000, cy: 15000, max: 4100), claim(cl: 2000, cy: nil, max: nil),
        ]], lens: .maxBuy)[0]
        #expect(TeamActivity.coverage(cards: box.cards, valued: box.valued, lens: .maxBuy) == "1 of 2 with a max buy")
        #expect(TeamActivity.coverage(cards: 2, valued: 2, lens: .cl) == nil, "complete sums carry no caveat")
    }

    @Test func theActivityViewDefaultsToTheLotsBasis() {
        let cyLot = Lot(id: UUID(), name: "CY", deadline: nil, status: .active, createdAt: Date(), valueBasis: .cy)
        #expect(TeamActivity.lens(stored: "", lot: cyLot) == .cy)
        #expect(TeamActivity.lens(stored: "", lot: nil) == .cl)
        #expect(TeamActivity.lens(stored: PriceLens.maxBuy.rawValue, lot: cyLot) == .maxBuy, "a picked view sticks")
    }

    @Test func unvaluedSlabsAreCountedAfterASwitch() {
        let range = BuyRange(id: UUID(), name: "$0–$100", valueMinCents: 0, valueMaxCents: 10_000,
                             gradeMin: 1, gradeMax: 10, maxCards: 10, budgetCents: 100_000)
        let usage = [range.id: RangeUsage(rangeId: range.id, cards: 3, usedCents: 5000, valuedCards: 1)]
        #expect(LotRoom.unvalued(ranges: [range], usage: usage) == 2)
        let old = [range.id: RangeUsage(rangeId: range.id, cards: 3, usedCents: 5000)]
        #expect(LotRoom.unvalued(ranges: [range], usage: old) == 0, "an older server reads as all valued")
    }

    // ── Claim outcomes ────────────────────────────────────────────────────────

    @Test func cyOutcomesReadAsCourtyard() {
        let none = LotVerdict(outcome: "blocked", reason: "no_cy_value")
        #expect(LotVerdictText.blockedReason(none) == "no Courtyard value")
        let conf = LotVerdict(outcome: "blocked", reason: "no_matching_range", failed: "confidence", basis: "cy")
        #expect(LotVerdictText.blockedReason(conf) == "CY confidence too low")
        let old = LotVerdict(outcome: "blocked", reason: "no_matching_range", failed: "confidence")
        #expect(LotVerdictText.blockedReason(old) == "CL confidence too low", "a stored pre-0.9 verdict is CL")
    }

    // ── The builder ───────────────────────────────────────────────────────────

    @Test func aNewLotIsCreatedWithItsBasis() {
        var draft = LotBuilderDraft()
        draft.name = "CY show"
        draft.basis = .cy
        guard case let .createLot(_, _, _, _, basis) = draft.operations(existingLot: nil, existingRanges: [],
                                                                         status: .draft).first else {
            Issue.record("create first"); return
        }
        #expect(basis == .cy)
    }

    @Test func anExistingLotsBasisIsNeverADraftEdit() {
        // M4: switching goes through set_lot_basis and its confirmation, never Save.
        let lot = Lot(id: UUID(), name: "Show", deadline: nil, status: .active, createdAt: Date())
        var draft = LotBuilderDraft(lot: lot, ranges: [])
        draft.basis = .cy
        #expect(draft.operations(existingLot: lot, existingRanges: [], status: .active).isEmpty)
    }

    // ── Team max-buy settings (M2) ────────────────────────────────────────────

    @Test func theTeamsKnobsReplaceTheMembers() {
        MaxBuyDefaults.withPinned(.init(windowN: 7, skew: 0.10, margin: 0.05)) {
            MaxBuyDefaults.team = (skew: 0.40, margin: 0.12)
            let k = MaxBuyDefaults.current
            #expect(k.skew == 0.40 && k.margin == 0.12)
            #expect(k.windowN == 7, "Average of N stays the phone's own (Q4)")
            #expect(MaxBuyDefaults.phone.margin == 0.05, "the phone's own setting is kept, just not applied")
        }
    }

    @Test func aMemberCanOnlyGoLowerThanTheLead() {
        MaxBuyDefaults.withPinned(.standard) {
            MaxBuyDefaults.team = (skew: 0.40, margin: 0.12)
            let loosened = MaxBuyDefaults.respectingTeam(.init(windowN: 5, skew: 0.0, margin: 0.0))
            #expect(loosened.skew == 0.40 && loosened.margin == 0.12, "held at the lead's")
            let tightened = MaxBuyDefaults.respectingTeam(.init(windowN: 5, skew: 0.6, margin: 0.2))
            #expect(tightened.skew == 0.6 && tightened.margin == 0.2, "a lower offer is the member's call")
        }
    }

    @Test func higherKnobsNeverRaiseTheFigure() {
        // The property the clamp relies on: at or above the lead's knobs is at or
        // below the lead's figure. Over a spread of comps, every step up lowers or holds.
        let comps = [140, 100, 95, 90, 60].enumerated().map {
            RecentSale(priceCents: $1 * 100, soldAt: day0.addingTimeInterval(-Double($0) * 86_400))
        }
        func vmb(_ skew: Double, _ margin: Double) -> Int {
            guard case .price(let cents, _) = MaxBuyPrice.compute(.init(
                comps: comps, clValueCents: nil, population: 40,
                knobs: .init(windowN: 5, skew: skew, margin: margin))) else { return -1 }
            return cents
        }
        for base in stride(from: 0.0, through: 0.9, by: 0.1) {
            #expect(vmb(base + 0.1, 0.1) <= vmb(base, 0.1))
            #expect(vmb(0.2, base + 0.1) <= vmb(0.2, base))
        }
    }

    // ── Max buy on a CY lot (M3) ──────────────────────────────────────────────

    @Test func aCardInACYLotPricesOnCourtyardAlone() {
        let lotId = UUID()
        let group = Folder(name: "CY show")
        group.teamLotId = lotId
        store.mainContext.insert(group)
        let card = Card(scan: CertScan(grader: .psa, certNumber: "96679812", raw: "96679812"))
        card.cardLadderSales = [RecentSale(priceCents: 100_00, soldAt: day0)]
        card.courtyardSales = [RecentSale(priceCents: 500_00, soldAt: day0)]
        card.cardLadderPriceCents = 120_00
        card.courtyardPriceCents = 450_00
        card.folder = group
        store.mainContext.insert(card)

        let policy = MaxBuyTeamPolicy.shared
        let saved = policy.basisByLot
        defer { policy.basisByLot = saved }

        policy.basisByLot = [lotId: .cl]
        #expect(MaxBuyValue.compsSource(for: card) == .cl, "a CL lot keeps the usual rule")
        #expect(MaxBuyValue.answer(for: card, knobs: .init(windowN: 5, skew: 0, margin: 0)).cents == 100_00)

        policy.basisByLot = [lotId: .cy]
        let answer = MaxBuyValue.answer(for: card, knobs: .init(windowN: 5, skew: 0, margin: 0))
        #expect(answer.compsSource == .cy, "Card Ladder's comps play no part")
        #expect(answer.capSource == .cy)
        #expect(answer.cents == 450_00, "capped at Courtyard's value, not CL's $120")
    }
}
