import Testing
import Foundation
@testable import Slab3

/// Price paid (2026-10-02) is opt-in: off, a stored value must reach nothing —
/// no column, no payout, no total. On, it is the real cost and wins over the
/// estimate everywhere Export reads money.
@MainActor
struct PricePaidTests {

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "slabs.test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func card(cl: Int? = 5_080, paid: Int? = nil) -> Card {
        let card = Card(scan: CertScan(grader: .psa, certNumber: "84920117", raw: "84920117"))
        card.cardLadderPriceCents = cl
        card.paidCents = paid
        return card
    }

    @Test func offByDefaultAndSurvivesALaunch() {
        let defaults = freshDefaults()
        let app = AppState(defaults: defaults)
        #expect(!app.tracksPaid)
        app.tracksPaid = true
        #expect(AppState(defaults: defaults).tracksPaid)
    }

    @Test func aStoredValueIsInvisibleWhileOff() {
        let app = AppState(defaults: freshDefaults())
        let c = card(paid: 4_572)
        #expect(app.paidCents(c) == nil)
        app.tracksPaid = true
        #expect(app.paidCents(c) == 4_572)
    }

    @Test func columnIsGatedAtBothEnds() {
        #expect(!CSVColumn.available().contains(.paid))
        #expect(CSVColumn.available(tracksPaid: true).contains(.paid))
        #expect(!CSVColumn.defaults.contains(.paid))

        let app = AppState(defaults: freshDefaults())
        app.enabledColumns = [.cert, .paid]
        #expect(app.exportColumns == [.cert])
        app.tracksPaid = true
        #expect(app.exportColumns == [.cert, .paid])

        // A column that slipped past the chip grid still never reaches the file.
        let header = CSVExport.rows([], columns: [.cert, .paid], payoutPercent: nil).first
        #expect(header == "cert")
    }

    @Test func paidCellIsEmptyNotZero() {
        let rows = CSVExport.rows([card(paid: nil), card(paid: 4_572)], columns: [.paid],
                                  payoutPercent: nil, tracksPaid: true)
        #expect(rows == ["paid_usd", "", "45.72"])
    }

    @Test func payoutIsWhatWasPaidWhenKnown() {
        let paid = card(paid: 4_000), estimated = card(paid: nil)
        let on = CSVExport.rows([paid, estimated], columns: [.payoutUsd], payoutPercent: 90, tracksPaid: true)
        #expect(on == ["payout_usd", "40.00", "45.72"]) // paid, then 90% of 50.80
        let off = CSVExport.rows([card(paid: 4_000)], columns: [.payoutUsd], payoutPercent: 90)
        #expect(off.last == "45.72", "off, the stored value is ignored")
        let noRate = CSVExport.rows([card(paid: 4_000)], columns: [.payoutUsd], payoutPercent: nil, tracksPaid: true)
        #expect(noRate.last == "40.00", "a known cost needs no rate")
    }

    @Test func totalUsesPaidOverMarketValue() {
        let cards = [card(cl: 5_080, paid: 4_000), card(cl: 1_000), card(cl: nil, paid: nil)]
        let on = CSVExport.total(cards, preferring: .cl, tracksPaid: true)
        #expect(on.cents == 5_000)
        #expect(on.paidCount == 1)
        let off = CSVExport.total(cards, preferring: .cl, tracksPaid: false)
        #expect(off.cents == 6_080)
        #expect(off.paidCount == 0)
    }

    /// Old builds let anyone type a "Manual price"; that value is not a cost and
    /// must not surface when the feature is switched on.
    @Test func aLegacyManualPriceIsNeverPaid() {
        let c = card(cl: 5_080)
        c.manualPriceCents = 9_999
        let app = AppState(defaults: freshDefaults())
        app.tracksPaid = true
        #expect(app.paidCents(c) == nil)
        #expect(CSVExport.total([c], preferring: .cl, tracksPaid: true).paidCount == 0)
        #expect(CSVExport.rows([c], columns: [.paid], payoutPercent: nil, tracksPaid: true).last == "")
    }
}
