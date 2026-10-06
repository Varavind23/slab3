import Testing
import Foundation
@testable import Slab3

/// The one-screen lot builder's save (teams-first plan, D6): what it sends, in
/// what order, and that a save which failed halfway is finished by the next try
/// without duplicating anything.
@MainActor
struct LotBuilderDraftTests {

    private func template(_ name: String, band: String? = nil) -> BuyRange {
        BuyRange(id: UUID(), name: name, valueMinCents: 0, valueMaxCents: 10_000, gradeMin: 7, gradeMax: 10,
                 clConfMin: nil, clConfMax: nil, yearMin: nil, yearMax: nil, maxCards: 400,
                 budgetCents: 4_510_000, notes: nil, band: band)
    }

    private func newDraft(_ templates: [BuyRange]) -> LotBuilderDraft {
        var draft = LotBuilderDraft()
        draft.name = "  Weekend 10/4 "
        draft.banner = "PSA only"
        templates.forEach { draft.add(template: $0) }
        return draft
    }

    /// What the server would hold after `ops` land — a lot and its ranges.
    private func landed(_ ops: [LotBuilderDraft.Op]) -> (Lot?, [BuyRange]) {
        var lot: Lot?, ranges: [BuyRange] = []
        for op in ops {
            switch op {
            case let .createLot(id, name, deadline, banner, _):
                lot = Lot(id: id, name: name, deadline: deadline, status: .draft, createdAt: Date(), banner: banner)
            case let .updateLot(_, name, deadline, banner, status):
                lot?.name = name; lot?.deadline = deadline; lot?.banner = banner; lot?.status = status
            case let .addRange(id, _, templateId, sortOrder, fields):
                var r = template(fields.name)
                r.id = id; r.templateId = templateId; r.sortOrder = sortOrder
                r.valueMinCents = fields.valueMinCents; r.band = fields.band
                ranges.append(r)
            case let .updateRange(id, sortOrder, _):
                if let i = ranges.firstIndex(where: { $0.id == id }) { ranges[i].sortOrder = sortOrder }
            case let .deleteRange(id):
                ranges.removeAll { $0.id == id }
            }
        }
        return (lot, ranges)
    }

    @Test func openingANewLotCreatesItThenItsBucketsThenOpensIt() {
        let low = template("$0–$100"), high = template("$100–$240")
        let draft = newDraft([low, high])
        let ops = draft.operations(existingLot: nil, existingRanges: [], status: .active)
        #expect(ops.count == 4)
        guard case let .createLot(id, name, _, banner, _) = ops[0] else { Issue.record("create first"); return }
        #expect(id == draft.lotId && name == "Weekend 10/4" && banner == "PSA only",
                "trimmed, and the banner goes with the create (it used to be dropped)")
        guard case let .addRange(_, lotId, templateId, order, _) = ops[1] else { Issue.record("then buckets"); return }
        #expect(lotId == draft.lotId && templateId == low.id && order == 0, "a library copy remembers its source")
        guard case .updateLot(_, _, _, _, .active) = ops[3] else { Issue.record("opened LAST"); return }
    }

    @Test func savingANewDraftNeverOpensIt() {
        let ops = newDraft([template("a")]).operations(existingLot: nil, existingRanges: [], status: .draft)
        #expect(!ops.contains { if case .updateLot = $0 { return true }; return false })
    }

    /// The failure this design exists for: the lot and one bucket landed, then the
    /// signal dropped. The next save must send only the rest — no second lot, no
    /// second copy of the bucket that made it.
    @Test func aRetryAfterAHalfFailedSaveSendsOnlyWhatIsMissing() {
        let draft = newDraft([template("a"), template("b")])
        let all = draft.operations(existingLot: nil, existingRanges: [], status: .active)
        let (lot, ranges) = landed(Array(all.prefix(2)))       // create + first bucket landed
        let retry = draft.operations(existingLot: lot, existingRanges: ranges, status: .active)
        #expect(retry.count == 2, "the second bucket, then open")
        guard case let .addRange(id, _, _, _, _) = retry[0] else { Issue.record("add the missing one"); return }
        #expect(id == draft.buckets[1].id)
        let (_, finalRanges) = landed(all.prefix(2) + retry)
        #expect(finalRanges.count == 2)
    }

    @Test func editingAnOpenLotSendsOnlyTheChanges() {
        let draft0 = newDraft([template("a"), template("b")])
        let (lot0, ranges) = landed(draft0.operations(existingLot: nil, existingRanges: [], status: .active))
        let lot = try! #require(lot0)
        var draft = LotBuilderDraft(lot: lot, ranges: ranges)
        #expect(draft.operations(existingLot: lot, existingRanges: ranges, status: .active).isEmpty,
                "opened and untouched: nothing to send")
        draft.buckets.removeFirst()
        draft.banner = ""
        let ops = draft.operations(existingLot: lot, existingRanges: ranges, status: .active)
        #expect(ops.first == .deleteRange(id: ranges[0].id))
        #expect(ops.contains { if case let .updateLot(_, _, _, banner, .active) = $0 { return banner == nil }; return false },
                "an emptied banner clears it")
    }

    @Test func aBucketHoldingCardsCannotBeTakenOut() {
        let (lot, ranges) = landed(newDraft([template("a")]).operations(existingLot: nil, existingRanges: [], status: .active))
        var draft = LotBuilderDraft(lot: lot!, ranges: ranges)
        draft.buckets = []
        #expect(draft.problem(opening: false, existing: ranges, held: [ranges[0].id]) != nil)
        #expect(draft.problem(opening: false, existing: ranges, held: []) == nil)
    }

    @Test func aLotNeedsANameAndOpeningNeedsABucket() {
        var draft = LotBuilderDraft()
        #expect(draft.problem(opening: false, existing: [], held: []) == "Name the lot.")
        draft.name = "Weekend"
        #expect(draft.problem(opening: false, existing: [], held: []) == nil, "an empty draft can be saved")
        #expect(draft.problem(opening: true, existing: [], held: []) != nil, "but not opened")
    }

    @Test func aLibraryCopyCarriesItsBand() {
        let draft = newDraft([template("a", band: "$0–$100")])
        #expect(draft.buckets[0].fields.band == "$0–$100")
    }
}
