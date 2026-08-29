import Foundation
import Testing
@testable import Slab3

/// Comps are the evidence a reseller prices against, so the rules that matter are
/// about honesty rather than arithmetic: never invent a sale, never lose one the
/// user already saw, and never let "the source has none" and "we never asked"
/// collapse into the same blank panel — which is the mistake prices already made
/// once (see PriceStatus) and the reason that distinction is stored, not implied.
@MainActor
struct RecentSalesTests {

    private func card() -> Card {
        Card(scan: CertScan(grader: .psa, certNumber: "20360362", raw: "20360362"))
    }
    private func sale(_ cents: Int, _ day: Int, platform: String? = "eBay", type: String? = nil) -> RecentSale {
        RecentSale(
            priceCents: cents,
            soldAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400),
            platform: platform,
            listingType: type,
            title: nil,
            url: nil
        )
    }

    // ── never fetched vs fetched-and-empty ───────────────────────────────────

    @Test func salesStartUnfetched() {
        #expect(card().cardLadderSales == nil)
        #expect(card().courtyardSales == nil)
    }

    @Test func anEmptyListIsAnAnswerNotAnAbsence() {
        let c = card()
        c.cardLadderSales = []
        // Distinct from nil: "Card Ladder has no comps for this card" is a fact
        // the detail screen states, and it must not read as "not loaded".
        #expect(c.cardLadderSales != nil)
        #expect(c.cardLadderSales?.isEmpty == true)
    }

    @Test func salesSurviveAStoreRoundTrip() {
        let c = card()
        let sales = [sale(12000, 3), sale(9800, 1)]
        c.cardLadderSales = sales
        #expect(c.cardLadderSales == sales)
    }

    // ── the two sources are independent ──────────────────────────────────────

    @Test func eachSourceKeepsItsOwnSales() {
        let c = card()
        c.cardLadderSales = [sale(12000, 3)]
        c.courtyardSales = []
        #expect(c.sales(for: .cl)?.count == 1)
        #expect(c.sales(for: .cy)?.isEmpty == true)
    }

    @Test func writingOneSourceLeavesTheOtherUntouched() {
        let c = card()
        c.cardLadderSales = [sale(12000, 3)]
        c.courtyardSales = [sale(11000, 2)]
        c.cardLadderSales = []
        #expect(c.courtyardSales?.count == 1)
    }

    // ── corrupt storage degrades, never crashes ──────────────────────────────

    @Test func unreadableStoredSalesReadAsNeverFetched() {
        let c = card()
        c.cardLadderSalesData = Data("not json".utf8)
        // Better to offer to load them again than to trap the user in a crash on
        // a screen they can reach from any row.
        #expect(c.cardLadderSales == nil)
    }

    // ── provenance line ──────────────────────────────────────────────────────

    @Test func provenanceExpandsCardLaddersListingTypes() {
        #expect(sale(1, 1, type: "BestOffer").provenance == "eBay · Best offer")
        #expect(sale(1, 1, type: "FixedPrice").provenance == "eBay · Fixed price")
        #expect(sale(1, 1, type: "Auction").provenance == "eBay · Auction")
    }

    @Test func provenanceOmitsWhatTheSourceDidNotSay() {
        #expect(sale(1, 1, type: nil).provenance == "eBay")
        #expect(sale(1, 1, platform: nil, type: "Auction").provenance == "Auction")
        #expect(sale(1, 1, platform: nil, type: nil).provenance == "")
    }

    // ── wire-format dates ────────────────────────────────────────────────────

    // A plain JSONDecoder cannot read an ISO date (its default strategy expects a
    // NUMBER), and supabase-swift's invoke uses exactly that. Decoding straight
    // into a Date threw, the catch reported "unavailable", and the panel said
    // "Sales not loaded" for a perfectly good 200. Dates cross as strings now.
    @Test func parsesCardLaddersFractionalSecondTimestamps() {
        let d = ISO8601.date("2026-08-28T15:04:10.000Z")
        #expect(d != nil)
        #expect(d?.timeIntervalSince1970 == 1787929450) // 2026-08-28T15:04:10Z
    }

    @Test func parsesTimestampsWithoutFractionalSeconds() {
        // Postgres timestamptz commonly comes back in this shape.
        #expect(ISO8601.date("2026-08-28T15:04:10Z") != nil)
    }

    @Test func refusesWhatItCannotRead() {
        #expect(ISO8601.date(nil) == nil)
        #expect(ISO8601.date("") == nil)
        #expect(ISO8601.date("yesterday") == nil)
        #expect(ISO8601.date("1787670250") == nil)
    }

    // ── the metric change itself ─────────────────────────────────────────────

    // The regression this release exists for: v1 showed a 30-day average, which is
    // empty for plenty of cards Card Ladder knows well, so those rows showed no
    // price at all. Value and last sale are separate figures and neither may be
    // inferred from the other.
    @Test func valueAndLastSaleAreStoredSeparately() {
        let c = card()
        c.cardLadderPriceCents = 8900   // CL Value
        c.cardLadderLastSaleCents = 4600 // Last Sold — genuinely different
        #expect(c.cardLadderPriceCents == 8900)
        #expect(c.cardLadderLastSaleCents == 4600)
    }

    @Test func aCardWithNoValueShowsAnEmDashNeverZero() {
        let c = card()
        c.cardLadderPriceCents = nil
        c.cardLadderLastSaleCents = nil
        #expect(caliperMoney(cents: c.cardLadderPriceCents) == "—")
        #expect(caliperMoney(cents: c.cardLadderLastSaleCents) == "—")
    }
}
