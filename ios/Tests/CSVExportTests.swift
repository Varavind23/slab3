import Testing
import Foundation
@testable import Slab3

/// The two claims the Export screen makes that a user can catch us lying about:
/// selection order IS column order in the file, and the filename carries the scope.
struct CSVExportTests {

    @Test func columnOrderFollowsSelectionOrder() {
        let picked: [CSVColumn] = [.grade, .cert, .cyPrice]
        let header = CSVExport.rows([], columns: picked, payoutPercent: nil).first
        #expect(header == "grade,cert,cy_price")
    }

    @Test func filenameCarriesScopeAndDate() {
        let day = Date(timeIntervalSince1970: 1_755_561_600) // 2025-08-19
        #expect(CSVExport.filename(scope: nil, date: day) == "inventory_2025-08-19.csv")
        #expect(CSVExport.filename(scope: "pete", date: day) == "inventory_pete_2025-08-19.csv")
        // Group names are whatever the user typed; the filename has to survive them.
        #expect(CSVExport.filename(scope: "Triumph 7/24", date: day) == "inventory_triumph-7-24_2025-08-19.csv")
    }

    @Test func aMissingPriceExportsEmptyNotZero() {
        let card = Card(scan: CertScan(grader: .psa, certNumber: "84920117", raw: "84920117"))
        let row = CSVExport.rows([card], columns: [.clPrice, .cyPrice], payoutPercent: nil).last
        #expect(row == ",") // two empty cells — never "0.00"
    }

    @Test func payoutIsBlankUntilARateIsSet() {
        let card = Card(scan: CertScan(grader: .psa, certNumber: "84920117", raw: "84920117"))
        card.courtyardPriceCents = 10_000
        let without = CSVExport.rows([card], columns: [.payoutUsd], payoutPercent: nil).last
        #expect(without == "")
        let with = CSVExport.rows([card], columns: [.payoutUsd], payoutPercent: 12.5).last
        #expect(with == "12.50")
    }
}

/// The row reads both sources through one index; totals read `best`.
struct PriceSetTests {

    @Test func activeSourceLeadsButFallsBackForTotals() {
        let set = PriceSet(cl: nil, cy: 5_071)
        #expect(set[.cl] == nil) // an em dash on the row — not borrowed from CY
        #expect(set.best(preferring: .cl) == 5_071) // but the card still has a value
    }

    @Test func aCardWithNoQuoteHasNoValue() {
        let set = PriceSet(cl: nil, cy: nil)
        #expect(set.best(preferring: .cy) == nil)
    }
}
