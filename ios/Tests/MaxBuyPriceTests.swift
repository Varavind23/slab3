import Testing
import Foundation
@testable import Slab3

/// The vectors behind the Verified Max Buy Price. This number is a recommendation
/// to spend money, so the rules that keep it honest — no comps means no number, an
/// unknown population is not a small one, and it never exceeds the payout — are
/// pinned here rather than left to the panel.
///
/// The three worked cases are the ones the feature was specified against: a tight
/// high-population card, a scattered low-population one, and a bottom-heavy set
/// where one runaway sale drags the mean above where the card really trades.
struct MaxBuyPriceTests {

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Newest first, the order every source hands them over in.
    private func comps(_ dollars: [Int]) -> [RecentSale] {
        dollars.enumerated().map { index, d in
            RecentSale(priceCents: d * 100,
                       soldAt: day0.addingTimeInterval(-Double(index) * 86_400))
        }
    }

    private func knobs(window: Int = 5, skew: Double = 0, margin: Double = 0) -> MaxBuyPrice.Knobs {
        .init(windowN: window, skew: skew, margin: margin)
    }

    private func compute(_ dollars: [Int], knobs k: MaxBuyPrice.Knobs,
                         clValue: Int? = nil, population: Int? = nil) -> MaxBuyPrice.Result {
        MaxBuyPrice.compute(.init(comps: comps(dollars),
                                  clValueCents: clValue.map { $0 * 100 },
                                  population: population,
                                  knobs: k))
    }

    private func cents(_ result: MaxBuyPrice.Result) -> Int? {
        guard case .price(let c, _) = result else { return nil }
        return c
    }

    private func breakdown(_ result: MaxBuyPrice.Result) -> MaxBuyPrice.Breakdown? {
        guard case .price(_, let b) = result else { return nil }
        return b
    }

    // ── The two ends of the skew ──────────────────────────────────────────────

    @Test func noSkewOnIdenticalSalesIsJustTheAverage() {
        // Identical comps mean every automatic term is zero, so this isolates the
        // slider: skew 0 must be the plain mean and nothing else.
        let result = compute([100, 100, 100, 100, 100], knobs: knobs())
        #expect(cents(result) == 10_000)
        #expect(breakdown(result)?.skewApplied == 0)
    }

    @Test func fullSkewLandsOnTheLowestRecentSale() {
        // The floor that makes the number defensible: at margin 0 it is always a
        // price this card actually sold for.
        let result = compute([100, 110, 120, 110, 115], knobs: knobs(skew: 1))
        #expect(cents(result) == 10_000, "full skew is the lowest of the window")
    }

    @Test func onlyMarginMayCutBelowTheLowestRealSale() {
        let result = compute([100, 110, 120, 110, 115], knobs: knobs(skew: 1, margin: 0.2))
        #expect(cents(result) == 8_000)
    }

    // ── The three specified cases ─────────────────────────────────────────────

    @Test func aTightHighPopulationCardPricesNearTheMiddle() {
        let result = compute([100, 110, 120, 110, 115], knobs: knobs(skew: 0.3), population: 400)
        let b = try! #require(breakdown(result))
        // mean 111, low 100. Middle-low: below the average, nowhere near the floor.
        #expect(cents(result)! < 11_100)
        #expect(cents(result)! > 10_500)
        #expect(b.dispersion < 0.1, "a tight tape is a low spread")
    }

    @Test func aScatteredLowPopulationCardSkewsFurtherDown() {
        let tight = compute([100, 110, 120, 110, 115], knobs: knobs(skew: 0.3))
        let scattered = compute([1000, 2000, 1500, 1500], knobs: knobs(skew: 0.3))

        let tightSkew = try! #require(breakdown(tight)?.skewApplied)
        let scatteredSkew = try! #require(breakdown(scattered)?.skewApplied)
        #expect(scatteredSkew > tightSkew, "scatter is the strongest signal we have")

        // Expressed as a fraction of its own mean, so the two cards compare.
        let tightRatio = Double(cents(tight)!) / Double(breakdown(tight)!.baseCents)
        let scatteredRatio = Double(cents(scattered)!) / Double(breakdown(scattered)!.baseCents)
        #expect(scatteredRatio < tightRatio)
    }

    @Test func oneRunawaySaleDoesNotSetTheCeiling() {
        // 1000/1000/1100/2000: the mean is 1275 but the card trades near 1050.
        // Three of four comps sit below the mean, and that shape is what pulls it
        // back down to the cluster.
        let result = compute([2000, 1100, 1000, 1000], knobs: knobs(skew: 0.3))
        let b = try! #require(breakdown(result))
        #expect(b.bottomHeaviness > 0, "three of four below the mean is bottom-heavy")
        #expect(cents(result)! < 127_500, "never above the mean it was drawn from")
        #expect(cents(result)! < 115_000, "and pulled toward where it really trades")
    }

    @Test func bottomHeavySkewsFurtherThanBalanced() {
        // Same count, same low, same mean — only the shape differs.
        let balanced = compute([1400, 1200, 900, 700], knobs: knobs())
        let heavy = compute([2000, 1000, 900, 300], knobs: knobs())
        let balancedShape = try! #require(breakdown(balanced)?.bottomHeaviness)
        let heavyShape = try! #require(breakdown(heavy)?.bottomHeaviness)
        #expect(heavyShape > balancedShape)
    }

    // ── Population ────────────────────────────────────────────────────────────

    @Test func anUnknownPopulationContributesNothing() {
        // The rule that matters most: a missing census is not evidence of a small
        // print run, and inferring one would be inventing the input.
        #expect(MaxBuyPrice.thinnessFromPopulation(nil) == 0)
    }

    @Test func aPopulationOfZeroIsTheThinnestMarketThereIs() {
        // Courtyard reports a real 0 for CGC pristine-10 groups.
        #expect(MaxBuyPrice.thinnessFromPopulation(0) == 1)
    }

    @Test func aLowPopulationSkewsFurtherThanAHighOne() {
        let scarce = compute([100, 110, 120, 110, 115], knobs: knobs(skew: 0.2), population: 8)
        let common = compute([100, 110, 120, 110, 115], knobs: knobs(skew: 0.2), population: 900)
        #expect(cents(scarce)! < cents(common)!)
    }

    @Test func populationThinnessFallsAwayAsThePopulationGrows() {
        let steps = [10, 25, 50, 120, 250].map { MaxBuyPrice.thinnessFromPopulation($0) }
        for (a, b) in zip(steps, steps.dropFirst()) {
            #expect(a > b, "more copies in existence is never a thinner market")
        }
        #expect(steps.last == 0)
    }

    // ── The window ────────────────────────────────────────────────────────────

    @Test func theWindowTakesTheNewestSales() {
        let result = compute([500, 100, 100, 100], knobs: knobs(window: 2))
        let b = try! #require(breakdown(result))
        #expect(b.usedCount == 2)
        #expect(b.baseCents == 30_000, "the newest two, not the cheapest two")
    }

    @Test func fewerSalesThanTheWindowUsesWhatExistsAndSaysSo() {
        // The sales panel below lists only five, so the count the number was
        // actually built from has to be reported, not implied.
        let result = compute([100, 120, 140], knobs: knobs(window: 10))
        #expect(breakdown(result)?.usedCount == 3)
    }

    @Test func fewSalesSkewFurtherDownThanMany() {
        let thin = compute([100, 120], knobs: knobs(skew: 0.2))
        let deep = compute([100, 120, 110, 105, 115], knobs: knobs(skew: 0.2))
        let thinSkew = try! #require(breakdown(thin)?.skewApplied)
        let deepSkew = try! #require(breakdown(deep)?.skewApplied)
        #expect(thinSkew > deepSkew)
    }

    // ── The honesty rules ─────────────────────────────────────────────────────

    @Test func noCompsIsNoNumber() {
        #expect(compute([], knobs: knobs()) == .unavailable(.noComps))
    }

    @Test func nonPositiveSalesAreNotEvidence() {
        // A zero-price row must not displace a real sale out of the window, and a
        // window of nothing but zeroes has nothing to average.
        let result = compute([0, 0, 100, 100], knobs: knobs(window: 2))
        #expect(breakdown(result)?.baseCents == 10_000)
        #expect(compute([0, 0], knobs: knobs()) == .unavailable(.noComps))
    }

    @Test func itNeverExceedsCardLadderValue() {
        // Offering more than the payout is a loss on its face.
        let result = compute([100, 100, 100], knobs: knobs(), clValue: 60)
        #expect(cents(result) == 6_000)
        #expect(breakdown(result)?.cappedByClValue == true)
    }

    @Test func noCardLadderValueMeansNoCapRatherThanNoNumber() {
        // An unconnected account is not a reason to withhold the comp read.
        let result = compute([100, 100, 100], knobs: knobs(), clValue: nil)
        #expect(cents(result) == 10_000)
        #expect(breakdown(result)?.cappedByClValue == false)
    }

    @Test func theResultCarriesTheDateOfTheNewestSaleItUsed() {
        // No recency decay in the formula on purpose — the date rides up instead,
        // so the panel can show how old the evidence is.
        let result = compute([100, 110, 120], knobs: knobs())
        #expect(breakdown(result)?.newestSoldAt == day0)
    }

    @Test func aNonsenseWindowFallsBackRatherThanReturningNothing() {
        let sanitized = MaxBuyPrice.Knobs(windowN: 0, skew: 2, margin: -1).sanitized
        #expect(sanitized.windowN == MaxBuyPrice.Knobs.standard.windowN)
        #expect(sanitized.skew == 1)
        #expect(sanitized.margin == 0)
    }
}
