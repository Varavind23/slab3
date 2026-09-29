import Testing
import Foundation
@testable import Slab3

/// The pure rules under the teams-first overhaul: what a buyer can still buy,
/// which lot scans go into, and the lead's per-person activity.
@MainActor
struct TeamsFirstLogicTests {

    private func range(maxCards: Int = 400, budget: Int64 = 4_510_000) -> BuyRange {
        BuyRange(id: UUID(), name: "$0–$100", valueMinCents: 0, valueMaxCents: 10_000,
                 gradeMin: 7, gradeMax: 10, clConfMin: nil, clConfMax: nil, yearMin: nil, yearMax: nil,
                 maxCards: maxCards, budgetCents: budget, notes: nil)
    }

    private func usage(_ r: BuyRange, cards: Int, cents: Int64) -> RangeUsage {
        RangeUsage(rangeId: r.id, cards: cards, usedCents: cents)
    }

    private func lot(_ status: LotStatus = .active, deadline: Date? = nil, created: Date = Date(),
                     id: UUID = UUID()) -> Lot {
        Lot(id: id, name: "Lot", deadline: deadline, status: status, createdAt: created)
    }

    // MARK: LotRoom — what I can still buy

    @Test func theHeadlineReadsLikeTheDesign() {
        let r = range()
        let room = LotRoom.bucket(r, usage: usage(r, cards: 231, cents: 1_733_243))
        #expect(room.leftLine == "169 cards · $27.7k left")
        #expect(!room.isNear)
    }

    @Test func eitherCapFillsTheBucket() {
        let r = range(maxCards: 10, budget: 100_000)
        let byCards = LotRoom.bucket(r, usage: usage(r, cards: 10, cents: 20_000))
        #expect(byCards.isFull && byCards.centsLeft == 0, "no dollars on offer in a bucket that takes no cards")
        #expect(byCards.leftLine == "Full")
        let byBudget = LotRoom.bucket(r, usage: usage(r, cards: 2, cents: 100_000))
        #expect(byBudget.isFull && byBudget.cardsLeft == 0)
    }

    @Test func theTighterCapDrivesTheBar() {
        let r = range(maxCards: 10, budget: 100_000)
        let room = LotRoom.bucket(r, usage: usage(r, cards: 9, cents: 10_000))
        #expect(room.fraction == 0.9)
        #expect(room.isNear, "amber at 90% of the cap that binds first")
    }

    @Test func anOverspentBucketClampsAndNothingUsedIsEmpty() {
        let r = range(maxCards: 10, budget: 100_000)
        let over = LotRoom.bucket(r, usage: usage(r, cards: 3, cents: 150_000))
        #expect(over.fraction == 1 && over.centsLeft == 0)
        let fresh = LotRoom.bucket(r, usage: nil)
        #expect(fresh.fraction == 0 && fresh.leftLine == "10 cards · $1k left")
    }

    @Test func aFullBucketAddsNothingToTheLotsRoom() {
        let a = range(maxCards: 10, budget: 100_000), b = range(maxCards: 5, budget: 50_000)
        let lot = LotRoom.lot(ranges: [a, b], usage: [a.id: usage(a, cards: 10, cents: 30_000),
                                                      b.id: usage(b, cards: 1, cents: 10_000)])
        #expect(lot.cardsLeft == 4 && lot.centsLeft == 40_000)
    }

    @Test func compactMoneyNeverRoundsUp() {
        #expect(Money.compact(95_099) == "$950")
        #expect(Money.compact(2_779_999) == "$27.7k")
        #expect(Money.compact(1_000_000) == "$10k")
        #expect(Money.compact(125_000_000) == "$1.2M")
        #expect(Money.compact(-5) == "$0")
    }

    // MARK: ScanTargetRule — which lot scans go into

    private let plainId = UUID(), lotGroupId = UUID()

    private func groups(lotId: UUID) -> [GroupRef] {
        [GroupRef(id: plainId, lotId: nil), GroupRef(id: lotGroupId, lotId: lotId)]
    }

    @Test func theLastTargetIsResumed() {
        let open = lot()
        #expect(ScanTargetRule.resolve(stored: lotGroupId, explicitNone: false, groups: groups(lotId: open.id),
                                       lots: [open], lotsLoaded: true, onTeam: true) == lotGroupId)
        #expect(ScanTargetRule.resolve(stored: plainId, explicitNone: false, groups: groups(lotId: open.id),
                                       lots: [open], lotsLoaded: true, onTeam: true) == plainId,
                "a plain group is the user's own choice — never swapped for a lot")
    }

    @Test func aClosedLotIsDroppedOnlyOnceTheLotsHaveLoaded() {
        let closed = lot(.closed)
        #expect(ScanTargetRule.resolve(stored: lotGroupId, explicitNone: false, groups: groups(lotId: closed.id),
                                       lots: [closed], lotsLoaded: true, onTeam: true) == nil)
        #expect(ScanTargetRule.resolve(stored: lotGroupId, explicitNone: false, groups: groups(lotId: closed.id),
                                       lots: [], lotsLoaded: false, onTeam: true) == lotGroupId,
                "offline at a show the local lot group is trusted")
    }

    @Test func theOnlyOpenLotIsPickedUnlessNoneWasChosen() {
        let open = lot()
        #expect(ScanTargetRule.resolve(stored: nil, explicitNone: false, groups: groups(lotId: open.id),
                                       lots: [open], lotsLoaded: true, onTeam: true) == lotGroupId)
        #expect(ScanTargetRule.resolve(stored: nil, explicitNone: true, groups: groups(lotId: open.id),
                                       lots: [open], lotsLoaded: true, onTeam: true) == nil)
        #expect(ScanTargetRule.resolve(stored: nil, explicitNone: false, groups: groups(lotId: open.id),
                                       lots: [open], lotsLoaded: true, onTeam: false) == nil,
                "never for someone off the team")
    }

    @Test func twoOpenLotsAreNeverGuessedBetween() {
        let a = lot(), b = lot()
        let refs = [GroupRef(id: UUID(), lotId: a.id), GroupRef(id: UUID(), lotId: b.id)]
        #expect(ScanTargetRule.resolve(stored: nil, explicitNone: false, groups: refs, lots: [a, b],
                                       lotsLoaded: true, onTeam: true) == nil)
    }

    @Test func theCurrentLotIsTheOpenLotBeingScannedInto() {
        let open = lot(), closed = lot(.closed)
        #expect(CurrentLot.resolve(scanTargetId: lotGroupId, groups: groups(lotId: open.id), lots: [open])?.id == open.id)
        #expect(CurrentLot.resolve(scanTargetId: lotGroupId, groups: groups(lotId: closed.id), lots: [closed]) == nil)
        #expect(CurrentLot.resolve(scanTargetId: plainId, groups: groups(lotId: open.id), lots: [open]) == nil)
    }

    // MARK: TeamActivity — each person's contribution

    private let lead = UUID(), buyer = UUID()

    private func claim(_ buyerId: UUID, cents: Int?, state: String = "confirmed", lotId: UUID = UUID(),
                       at: String = "2026-10-04T10:00:00Z") -> TeamClaim {
        TeamClaim(id: UUID(), lotId: lotId, rangeId: nil, cert: String(Int.random(in: 1...99_999_999)),
                  grader: "psa", gradeLabel: "9", priceCents: cents, clConfidence: 4, label: nil,
                  player: "Charizard", cardSet: nil, cardYear: nil, cardNumber: nil, imageUrl: nil,
                  buyerId: buyerId, state: state, scannedAt: at)
    }

    private var roster: [TeamStore.Member] {
        [TeamStore.Member(userId: lead, role: .lead, displayName: "Lead"),
         TeamStore.Member(userId: buyer, role: .buyer, displayName: "Justin")]
    }

    @Test func overLimitBuysCountAndReleasedOnesDoNot() {
        let claims = [claim(buyer, cents: 41_200), claim(buyer, cents: 8_800, state: "over_limit"),
                      claim(buyer, cents: 99_900, state: "removed")]
        let justin = TeamActivity.members(claims: claims, roster: roster).first { $0.userId == buyer }
        #expect(justin?.cards == 2)
        #expect(justin?.cents == 50_000)
    }

    @Test func membersAreOrderedByClValueAndEveryoneIsListed() {
        let formerId = UUID()
        let claims = [claim(buyer, cents: 10_000), claim(formerId, cents: 90_000)]
        let rows = TeamActivity.members(claims: claims, roster: roster)
        #expect(rows.map(\.name) == ["Former member", "Justin", "Lead"],
                "most CL value first; a member with nothing yet still shows, as a zero")
        #expect(rows.last?.cards == 0)
    }

    @Test func aClaimWithNoPriceCountsAsACardButNoDollars() {
        let rows = TeamActivity.members(claims: [claim(buyer, cents: nil)], roster: roster)
        let justin = rows.first { $0.userId == buyer }
        #expect(justin?.cards == 1 && justin?.cents == 0)
    }

    @Test func boxesListOpenLotsBySoonestDeadlineThenClosedNewest() {
        let now = Date()
        let later = lot(deadline: now.addingTimeInterval(86_400 * 5))
        let sooner = lot(deadline: now.addingTimeInterval(86_400))
        let old = lot(.closed, created: now.addingTimeInterval(-86_400 * 30))
        let recent = lot(.closed, created: now.addingTimeInterval(-86_400))
        let draft = lot(.draft)
        let boxes = TeamActivity.boxes(lots: [old, later, draft, recent, sooner], claimsByLot: [:])
        #expect(boxes.map(\.id) == [sooner.id, later.id, recent.id, old.id], "no drafts — nothing bought yet")
        #expect(TeamActivity.defaultLot(current: later.id, boxes: boxes) == later.id)
        #expect(TeamActivity.defaultLot(current: nil, boxes: boxes) == sooner.id)
    }

    @Test func aReceiptIsNewestFirst() {
        let first = claim(buyer, cents: 1, at: "2026-10-04T09:00:00Z")
        let second = claim(buyer, cents: 2, at: "2026-10-04T11:00:00Z")
        let receipt = TeamActivity.receipt(claims: [first, second, claim(lead, cents: 3)], userId: buyer)
        #expect(receipt.map(\.id) == [second.id, first.id])
    }
}
