import Testing
import Foundation
import SwiftData
@testable import Slab3

/// Buy ranges and lot groups (teams phase 2).
///
/// Money is pinned hardest: a range's value bounds and budget decide which cards a
/// lot takes, so a typed "$0.29" has to be 29 cents, not 28 (what a Double gives).
/// The validation cases mirror the CHECK constraints in
/// supabase/migrations/20260925000000_teams_lots.sql — if one of those changes,
/// these should fail first.
@MainActor
struct BuyRangeTests {

    // MARK: Money

    @Test func dollarsParseToExactCents() {
        #expect(Money.cents(fromDollars: "45,100") == 4_510_000)
        #expect(Money.cents(fromDollars: "$17,332.43") == 1_733_243)
        #expect(Money.cents(fromDollars: "0.29") == 29, "a Double would make this 28")
        #expect(Money.cents(fromDollars: "99.9") == 9_990)
        #expect(Money.cents(fromDollars: " 100 ") == 10_000)
    }

    @Test func notMoneyIsNil() {
        for bad in ["", "abc", "-5", "1.234", "1.2.3", "$"] {
            #expect(Money.cents(fromDollars: bad) == nil, "\(bad) is not an amount")
        }
    }

    @Test func centsRenderWholeWhenWhole() {
        #expect(Money.dollars(4_510_000) == "$45,100")
        #expect(Money.dollars(1_733_243) == "$17,332.43")
        #expect(Money.dollars(5) == "$0.05")
        #expect(Money.field(4_510_000) == "45100")
        #expect(Money.field(1_733_243) == "17332.43")
        #expect(Money.field(nil) == "")
    }

    // MARK: How a range reads

    @Test func valueLabelReadsLikeALeadWritesIt() {
        #expect(BuyRangeText.value(min: 0, max: 10_000) == "$0 – $100")
        #expect(BuyRangeText.value(min: 24_000, max: nil) == "$240+")
    }

    @Test func criteriaShowOnlyWhatWasSet() {
        #expect(BuyRangeText.criteria(gradeMin: 7, gradeMax: 10, confMin: nil, confMax: nil,
                                      yearMin: nil, yearMax: nil) == "GRADE 7–10")
        #expect(BuyRangeText.criteria(gradeMin: 8.5, gradeMax: 10, confMin: 4, confMax: nil,
                                      yearMin: 1999, yearMax: 2026) == "GRADE 8.5–10 · CONF 4+ · 1999–2026")
        #expect(BuyRangeText.criteria(gradeMin: 10, gradeMax: 10, confMin: nil, confMax: 3,
                                      yearMin: nil, yearMax: 2005) == "GRADE 10 · CONF ≤3 · ≤2005")
    }

    // MARK: The editor refuses what the server would

    private func draft(_ edit: (inout BuyRangeDraft) -> Void) -> BuyRangeDraft {
        var d = BuyRangeDraft()
        d.name = "Under $100"; d.valueMax = "100"; d.gradeMin = "7"; d.maxCards = "400"; d.budget = "45,100"
        edit(&d)
        return d
    }

    @Test func aCompleteRangeIsValid() {
        let fields = draft { _ in }.validated().fields
        #expect(fields?.valueMinCents == 0)
        #expect(fields?.valueMaxCents == 10_000)
        #expect(fields?.gradeMin == 7)
        #expect(fields?.clConfMin == nil, "a blank bound is no limit")
        #expect(fields?.budgetCents == 4_510_000)
        #expect(fields?.notes == nil, "blank notes are not an empty string on the server")
    }

    @Test func eachBadFieldIsNamed() {
        #expect(draft { $0.name = "  " }.validated().issues.keys.contains(.name))
        #expect(draft { $0.valueMin = "200" }.validated().issues[.value] == "Max must be above min.")
        #expect(draft { $0.valueMax = "100" ; $0.valueMin = "100" }.validated().issues[.value] != nil,
                "max is exclusive, so min == max is an empty range")
        #expect(draft { $0.gradeMin = "0" }.validated().issues.keys.contains(.grade))
        #expect(draft { $0.gradeMin = "7.3" }.validated().issues.keys.contains(.grade), "halves only")
        #expect(draft { $0.gradeMin = "9"; $0.gradeMax = "8" }.validated().issues.keys.contains(.grade))
        #expect(draft { $0.confMin = "6" }.validated().issues.keys.contains(.confidence))
        #expect(draft { $0.confMin = "4"; $0.confMax = "2" }.validated().issues.keys.contains(.confidence))
        #expect(draft { $0.yearMin = "99" }.validated().issues.keys.contains(.year))
        #expect(draft { $0.maxCards = "" }.validated().issues.keys.contains(.maxCards))
        #expect(draft { $0.budget = "0" }.validated().issues.keys.contains(.budget), "a budget is required")
    }

    @Test func halfGradesAreAllowed() {
        #expect(draft { $0.gradeMin = "8.5" }.validated().fields?.gradeMin == 8.5)
    }

    @Test func aRangeRoundTripsThroughTheEditor() {
        let range = BuyRange(id: UUID(), name: "Mid", valueMinCents: 10_000, valueMaxCents: 24_000,
                             gradeMin: 8.5, gradeMax: 10, clConfMin: 4, clConfMax: nil, yearMin: 1999,
                             yearMax: nil, maxCards: 150, budgetCents: 2_000_050, notes: "No promos")
        #expect(BuyRangeDraft(range).validated().fields == range.fields)
    }

    // MARK: A lot is a shared group

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Card.self, Folder.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func lot(_ name: String, _ status: LotStatus, id: UUID = UUID()) -> Lot {
        Lot(id: id, name: name, deadline: nil, status: status, createdAt: Date())
    }

    private func folders(_ context: ModelContext) -> [Folder] {
        (try? context.fetch(FetchDescriptor<Folder>())) ?? []
    }

    @Test func eachVisibleLotBecomesOneGroup() throws {
        let context = try makeContext()
        let open = lot("Show 7/24", .active)
        LotFolders.sync([open], isLead: false, in: context)
        LotFolders.sync([open], isLead: false, in: context)
        let all = folders(context)
        #expect(all.count == 1, "syncing twice does not duplicate the group")
        #expect(all.first?.teamLotId == open.id)
        #expect(all.first?.name == "Show 7/24")
    }

    @Test func buyersNeverSeeADraft() throws {
        let context = try makeContext()
        LotFolders.sync([lot("Next week", .draft)], isLead: false, in: context)
        #expect(folders(context).isEmpty)
        LotFolders.sync([lot("Next week", .draft)], isLead: true, in: context)
        #expect(folders(context).count == 1, "the lead setting it up does")
    }

    @Test func aRenamedLotRenamesItsGroup() throws {
        let context = try makeContext()
        let id = UUID()
        LotFolders.sync([lot("Show", .active, id: id)], isLead: false, in: context)
        LotFolders.sync([lot("Show 7/24", .active, id: id)], isLead: false, in: context)
        #expect(folders(context).map(\.name) == ["Show 7/24"])
    }

    /// The rule that matters: a lot disappearing must never take cards with it.
    @Test func aGoneLotDetachesAGroupWithCardsAndRemovesAnEmptyOne() throws {
        let context = try makeContext()
        let kept = lot("Has cards", .active), empty = lot("Empty", .active)
        LotFolders.sync([kept, empty], isLead: false, in: context)
        let withCards = folders(context).first { $0.teamLotId == kept.id }!
        let card = Card(scan: CertScan(grader: .psa, certNumber: "12345678", raw: "12345678"))
        context.insert(card)
        card.folder = withCards

        LotFolders.sync([], isLead: false, in: context)
        let left = folders(context)
        #expect(left.count == 1, "the empty lot group is gone")
        #expect(left.first?.name == "Has cards")
        #expect(left.first?.teamLotId == nil, "the other is an ordinary group now")
        #expect(left.first?.cards.count == 1, "and its card is still in it")
    }

    @Test func ordinaryGroupsAreNeverTouched() throws {
        let context = try makeContext()
        context.insert(Folder(name: "consignment"))
        LotFolders.sync([], isLead: true, in: context)
        #expect(folders(context).map(\.name) == ["consignment"])
    }

    @Test func lotGroupsAreNotOfferedForFilingYet() {
        let lotGroup = Folder(name: "Show 7/24")
        lotGroup.teamLotId = UUID()
        lotGroup.markUsed()
        #expect(Folder.mostRecentlyUsed(in: [lotGroup]) == nil,
                "the swipe must not file into a lot until filing claims (phase 3–4)")
    }
}
