import Testing
import Foundation
import SwiftData
@testable import Slab3

/// The wiring around the formula: which comps answer, what caps the result, and
/// when the memo is allowed to reuse an old figure.
///
/// `MaxBuyPriceTests` already pins the arithmetic. What is pinned here is the part
/// that six different screens depend on agreeing about — and the cache, which is the
/// one piece that could make them disagree without anything looking wrong.
@MainActor
struct MaxBuyValueTests {

    /// Stored, not per call: a container that deinits while a model is still in use
    /// tears the card out from under the test.
    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func sales(_ dollars: [Int]) -> [RecentSale] {
        dollars.enumerated().map { index, d in
            RecentSale(priceCents: d * 100, soldAt: day0.addingTimeInterval(-Double(index) * 86_400))
        }
    }

    @discardableResult
    private func card(cl: [Int]? = nil, cy: [Int]? = nil,
                      clValue: Int? = nil, population: Int? = nil) -> Card {
        let c = Card(scan: CertScan(grader: .psa, certNumber: "96679812", raw: "96679812"))
        c.grade = "10"
        if let cl { c.cardLadderSales = sales(cl) }
        if let cy { c.courtyardSales = sales(cy) }
        c.cardLadderPriceCents = clValue.map { $0 * 100 }
        c.courtyardPopulation = population
        store.mainContext.insert(c)
        return c
    }

    private func knobs(window: Int = 5, skew: Double = 0, margin: Double = 0) -> MaxBuyPrice.Knobs {
        .init(windowN: window, skew: skew, margin: margin)
    }

    /// `MaxBuyValue.cents` reads the user's SAVED defaults, which carry a 10% margin
    /// and a 30% skew out of the box. Any test going through that path has to pin
    /// them, or it is really asserting whatever is in this machine's preferences —
    /// and has to put them BACK, or the next test (and the simulator app) inherits
    /// this one's knobs. Resets the memo too, since the knobs are part of its stamp.
    private func pinned(skew: Double = 0, margin: Double = 0, _ body: () -> Void) {
        MaxBuyDefaults.withPinned(.init(windowN: 5, skew: skew, margin: margin)) {
            MaxBuyCache.reset()
            body()
        }
    }

    // ── Which comps answer ────────────────────────────────────────────────────

    @Test func prefersCardLadderComps() {
        let c = card(cl: [100, 100, 100], cy: [500, 500, 500])
        #expect(MaxBuyValue.compsSource(for: c) == .cl)
        #expect(MaxBuyValue.answer(for: c, knobs: knobs()).cents == 10_000)
    }

    @Test func fallsBackToCourtyardComps() {
        let c = card(cy: [500, 500, 500])
        #expect(MaxBuyValue.compsSource(for: c) == .cy)
        #expect(MaxBuyValue.answer(for: c, knobs: knobs()).cents == 50_000)
    }

    @Test func anEmptyCardLadderListFallsThroughRatherThanAnswering() {
        // [] means "Card Ladder answered and has none". Treating that as THE answer
        // would blank a card that has perfectly good Courtyard comps — which is the
        // common case, since CL comps only exist for cards that have been opened.
        let c = card(cl: [], cy: [200, 200])
        #expect(MaxBuyValue.compsSource(for: c) == .cy)
        #expect(MaxBuyValue.answer(for: c, knobs: knobs()).cents == 20_000)
    }

    @Test func noCompsOnEitherSourceIsAnEmDashNotZero() {
        pinned {
            let c = card(cl: [], cy: [])
            #expect(MaxBuyValue.compsSource(for: c) == nil)
            #expect(MaxBuyValue.answer(for: c, knobs: knobs()).result == .unavailable(.noComps))
            #expect(MaxBuyValue.cents(for: c) == nil, "nil, so the UI can render an em dash")
        }
    }

    // ── The cap and the census come from fixed sources ────────────────────────

    @Test func theCapIsAlwaysCardLadderValueEvenOnCourtyardComps() {
        // He is paid CLV, so offering above it is a loss on its face — whichever
        // source's sales the figure was reasoned from.
        let c = card(cy: [500, 500, 500], clValue: 300)
        let answer = MaxBuyValue.answer(for: c, knobs: knobs())
        #expect(answer.cents == 30_000)
        #expect(answer.breakdown?.cappedByClValue == true)
    }

    @Test func thePopulationIsAlwaysCourtyards() {
        // Courtyard is the only source that carries a census at all, so it applies
        // even when Card Ladder supplied the comps.
        let scarce = card(cl: [100, 110, 120, 110, 115], population: 8)
        let unknown = card(cl: [100, 110, 120, 110, 115])
        let scarceCents = MaxBuyValue.answer(for: scarce, knobs: knobs(skew: 0.2)).cents!
        let unknownCents = MaxBuyValue.answer(for: unknown, knobs: knobs(skew: 0.2)).cents!
        #expect(scarceCents < unknownCents, "a thin census pulls the ceiling down")
    }

    // ── The memo ──────────────────────────────────────────────────────────────

    @Test func doesNotRecomputeWhenNothingChanged() {
        pinned {
            let c = card(cl: [100, 100, 100])
            _ = MaxBuyValue.cents(for: c)
            _ = MaxBuyValue.cents(for: c)
            _ = MaxBuyValue.cents(for: c)
            #expect(MaxBuyCache.computeCount == 1, "the list re-reads this constantly")
        }
    }

    @Test func recomputesWhenCompsChange() {
        pinned {
            let c = card(cl: [100, 100, 100])
            #expect(MaxBuyValue.cents(for: c) == 10_000)
            // Written through the accessor, which is what bumps compsRevision.
            c.cardLadderSales = sales([200, 200, 200])
            #expect(MaxBuyValue.cents(for: c) == 20_000)
            #expect(MaxBuyCache.computeCount == 2)
        }
    }

    @Test func recomputesWhenTheCapChanges() {
        pinned {
            let c = card(cl: [100, 100, 100], clValue: 500)
            #expect(MaxBuyValue.cents(for: c) == 10_000)
            c.cardLadderPriceCents = 5_000
            #expect(MaxBuyValue.cents(for: c) == 5_000, "the cap is part of the answer")
        }
    }

    @Test func recomputesWhenThePopulationChanges() {
        pinned {
            let c = card(cl: [100, 110, 120, 110, 115])
            let before = MaxBuyValue.cents(for: c)!
            c.courtyardPopulation = 4
            #expect(MaxBuyValue.cents(for: c)! < before)
        }
    }

    @Test func recomputesWhenTheDefaultsChange() {
        pinned {
            let c = card(cl: [100, 100, 100])
            #expect(MaxBuyValue.cents(for: c) == 10_000)
            // A slider moved in Settings has to reprice every row, not just the next
            // card that happens to change.
            MaxBuyDefaults.save(.init(windowN: 5, skew: 0, margin: 0.5))
            #expect(MaxBuyValue.cents(for: c) == 5_000)
        }
    }

    @Test func forgetsADeletedCard() {
        pinned {
            let c = card(cl: [100, 100, 100])
            _ = MaxBuyValue.cents(for: c)
            MaxBuyCache.forget([c.localId])
            _ = MaxBuyValue.cents(for: c)
            #expect(MaxBuyCache.computeCount == 2)
        }
    }

    // ── The CSV hand-off ──────────────────────────────────────────────────────

    @Test func theCsvMapOmitsCardsWithNoFigure() {
        pinned {
            // Absent, not zero — `cell` renders a missing key as an empty string, the
            // same way a missing price does.
            let priced = card(cl: [100, 100, 100])
            let blank = card(cl: [], cy: [])
            let map = MaxBuyValue.centsByCard([priced, blank])
            #expect(map[priced.localId] == 10_000)
            #expect(map[blank.localId] == nil)
        }
    }
}
