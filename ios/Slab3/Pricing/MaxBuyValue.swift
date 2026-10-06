import Foundation

/// The one place that decides WHICH comps, WHICH cap and WHICH population a max buy
/// is built from (2026-09-22).
///
/// Before the lens there was one consumer — `MaxBuyPanel` — and it assembled
/// `MaxBuyPrice.Inputs` inline. There are now six: the Cards row, the detail hero,
/// the selection-mode running total, the scan toast, the CSV cell and the panel. Six
/// copies of "prefer Card Ladder's comps, cap at CL Value, take Courtyard's
/// population" is six chances for the list and the screen a sourcer is holding out
/// to a seller to disagree about the same card, silently, the day one of them is
/// edited. So they all come through here.
///
/// `MaxBuyPrice` stays the pure formula; this is only the wiring around it.
@MainActor
enum MaxBuyValue {

    /// Which source's comps this card gets priced from.
    ///
    /// Card Ladder first because it is the better evidence — real sales, filtered to
    /// this card AND grade server-side. Courtyard's are the fallback, and in
    /// practice the common case: CY comps arrive with the scan, while CL comps are
    /// only ever fetched when a card's detail screen is opened with an account
    /// connected (`PriceService.loadSales`). A card therefore re-prices the first
    /// time it is opened — accepted by the owner, and not cheaply fixable, since
    /// fetching comps in bulk is what the 200/day budget forbids.
    ///
    /// An EMPTY Card Ladder list means "CL answered and has none" and falls THROUGH
    /// to Courtyard. Treating it as the answer would turn a card with real Courtyard
    /// comps into an em dash.
    ///
    /// ON A CY LOT (owner M3, 2026-10-01) Card Ladder plays no part: Courtyard's
    /// comps only, capped at Courtyard's value. A card is "on" a lot when it is filed
    /// in that lot's group. A CL lot, and every card in no lot, keep the rule above.
    static func compsSource(for card: Card) -> PriceSource? {
        if basis(for: card) == .cy {
            if let cy = card.courtyardSales, !cy.isEmpty { return .cy }
            return nil
        }
        if let cl = card.cardLadderSales, !cl.isEmpty { return .cl }
        if let cy = card.courtyardSales, !cy.isEmpty { return .cy }
        return nil
    }

    /// The basis of the lot this card is filed in, if any (MaxBuyTeamPolicy).
    static func basis(for card: Card) -> ValueBasis? {
        card.folder?.teamLotId.flatMap { MaxBuyTeamPolicy.shared.basisByLot[$0] }
    }

    /// Whose value is the ceiling: Courtyard's on a CY lot, Card Ladder's
    /// everywhere else — the value the sourcer is paid in.
    static func capSource(for card: Card) -> PriceSource { basis(for: card) == .cy ? .cy : .cl }

    /// The figure plus the basis it was actually built from, so the panel can
    /// disclose which comps answered without the row having to.
    struct Answer {
        var result: MaxBuyPrice.Result
        /// nil when neither source has comps — the `.noComps` case.
        var compsSource: PriceSource?
        /// Whose value capped it: `.cy` on a CY lot, `.cl` everywhere else.
        var capSource: PriceSource = .cl

        var cents: Int? {
            if case .price(let cents, _) = result { return cents }
            return nil
        }
        var breakdown: MaxBuyPrice.Breakdown? {
            if case .price(_, let breakdown) = result { return breakdown }
            return nil
        }
    }

    /// Live and uncached — the panel's per-card tuned figure, and the detail hero
    /// that follows its sliders.
    ///
    /// The cap is Card Ladder Value (Courtyard's on a CY lot) and the population is
    /// Courtyard's WHICHEVER source supplied the comps: he is paid in that value so
    /// it is the ceiling, and Courtyard is the only source that carries a census.
    static func answer(for card: Card, knobs: MaxBuyPrice.Knobs) -> Answer {
        let source = compsSource(for: card)
        let cap = capSource(for: card)
        let comps = source.flatMap { card.sales(for: $0) } ?? []
        return Answer(
            result: MaxBuyPrice.compute(.init(
                comps: comps,
                clValueCents: card.prices[cap],
                population: card.courtyardPopulation,
                knobs: knobs.sanitized
            )),
            compsSource: source,
            capSource: cap
        )
    }

    /// The baseline figure a row, the selection total, the toast and the CSV show —
    /// the user's saved defaults, never a card's tuned knobs, so the list is one
    /// consistent basis rather than a record of which cards he happened to fiddle
    /// with.
    ///
    /// Memoized: see `MaxBuyCache` for why that is required rather than an
    /// optimisation. `nil` is a real answer (no comps) and renders as an em dash.
    static func cents(for card: Card) -> Int? {
        MaxBuyCache.cents(for: card, knobs: MaxBuyDefaults.current)
    }

    /// The same figures as plain data, for the CSV layer.
    ///
    /// `CSVExport` is deliberately nonisolated — isolating it to reach this
    /// main-actor memo would isolate the whole CSV path and its offline tests with
    /// it — so the caller resolves the values here and hands them over. Cards with
    /// no max buy are simply absent, which the cell renders as empty.
    static func centsByCard(_ cards: [Card]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for card in cards {
            if let cents = cents(for: card) { map[card.localId] = cents }
        }
        return map
    }
}

/// The memo behind `MaxBuyValue.cents`.
///
/// Not an optimisation. `CardsScreen.visible` is evaluated several times per body
/// pass and body re-runs on every scroll tick, `card.cardLadderSales` and
/// `card.courtyardSales` run a `JSONDecoder` on EVERY property read, and sorting by
/// max buy values every card in the store. Uncached, a 255-card stack costs tens of
/// thousands of decodes a frame.
///
/// Deliberately a `@MainActor enum` with a static dictionary rather than anything
/// `@Observable`: entries are written during `body`, and a cache SwiftUI could see
/// would either trip "Modifying state during view update" or loop.
@MainActor
enum MaxBuyCache {

    /// Every input to the row-path calculation, and nothing else. Equality of this
    /// IS the invalidation rule: an entry is used if and only if the card's stamp
    /// still matches the one it was computed under.
    ///
    /// The card's grade is deliberately absent — comps arrive already filtered to
    /// this slab's grader and grade, so editing the grade does not re-price the
    /// comps already stored. That is a pre-existing property of the feature, not a
    /// gap this cache introduces.
    struct Stamp: Hashable {
        var comps: Int
        var cap: Int
        var population: Int
        var knobs: MaxBuyPrice.Knobs
        /// A CY lot changes both the comps and the cap (0.9).
        var cyLot: Bool

        @MainActor init(card: Card, knobs: MaxBuyPrice.Knobs) {
            cyLot = MaxBuyValue.basis(for: card) == .cy
            comps = card.compsRevision ?? 0
            cap = (cyLot ? card.courtyardPriceCents : card.cardLadderPriceCents) ?? -1
            population = card.courtyardPopulation ?? -1
            self.knobs = knobs
        }
    }

    private static var entries: [UUID: (stamp: Stamp, cents: Int?)] = [:]

    /// How many times the formula has actually run. Only a test reads it — it is
    /// the sole way to assert that the memo memoizes.
    private(set) static var computeCount = 0

    /// Reading the stamp is what keeps the row correct, not the dictionary: those
    /// three fields are read inside `body`, so SwiftData's observation redraws the
    /// row AND misses the cache on the same pass. A cache invalidated only by
    /// explicit calls would have no observation dependency at all, and would hold a
    /// stale figure on screen until something unrelated moved.
    static func cents(for card: Card, knobs: MaxBuyPrice.Knobs) -> Int? {
        let stamp = Stamp(card: card, knobs: knobs)
        if let hit = entries[card.localId], hit.stamp == stamp { return hit.cents }
        computeCount += 1
        let cents = MaxBuyValue.answer(for: card, knobs: knobs).cents
        entries[card.localId] = (stamp, cents)
        return cents
    }

    /// Hygiene on delete — entries are a few bytes each, but a store that is emptied
    /// should not leave the dictionary holding every card it ever showed.
    static func forget(_ ids: Set<UUID>) {
        for id in ids { entries.removeValue(forKey: id) }
    }

    /// Tests only.
    static func reset() {
        entries.removeAll()
        computeCount = 0
    }
}
