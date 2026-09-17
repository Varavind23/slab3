import Foundation

/// The Verified Max Buy Price: the most a sourcer should pay for a slab and still
/// clear their cut, computed from comps already on the device.
///
/// Why it exists (2026-09-16, gated pilot for one user). A sourcer who is paid out
/// in Card Ladder Value buys slabs off sellers and resells at CLV, so CLV is his
/// revenue, not a reference price. What he needs is not a price but a CEILING on
/// what he can offer. He reaches it by eye today: average the last few sales, go
/// under, and go further under when those sales are scattered, bottom-heavy, or
/// few — because all three mean the card is low-population and CLV is a shakier
/// estimate of what he will actually be paid.
///
/// This is that judgement as arithmetic, with every term named:
///
///     base = mean(newest N comps)
///     room = base - lowest of those N
///     s    = skew + a1*dispersion + a2*bottomHeaviness + a3*thinness   (clamped 0...1)
///     VMB  = (base - s*room) * (1 - margin),   capped at CL Value
///
/// `s = 0` is the plain average and `s = 1` is the lowest recent sale, so at
/// `margin = 0` the answer is always a figure this card actually sold for — which
/// is what makes it defensible to the seller it gets shown to. `margin` is the
/// only term allowed to cut below that floor.
///
/// Honesty rules, the same ones prices follow: no comps means NO NUMBER, never a
/// fabricated one; an unknown population contributes nothing rather than being
/// guessed at; and the result is capped at CL Value, because offering more than
/// the payout is a loss on its face.
///
/// There is deliberately NO recency decay. The window is "the newest N", which is
/// how the sourcer already thinks, and a half-life would be a second unseen
/// opinion about the same comps. `Breakdown.newestSoldAt` carries the date up
/// instead, so the panel can show how old the evidence is and let him judge.
///
/// Pure and Foundation-only — no network, no SwiftUI, no store — so the vectors
/// are testable off-device, the way `PriceWriteback` is.
enum MaxBuyPrice {

    /// The three knobs. Per-card in the UI, reset to a stored baseline on every
    /// card, so a slider moved during one negotiation cannot silently follow him
    /// into the next.
    struct Knobs: Equatable {
        /// How many of the newest comps to average. 1...50.
        var windowN: Int
        /// How far to pull the average toward the lowest comp. 0 = the mean,
        /// 1 = the lowest comp. The automatic terms add to this.
        var skew: Double
        /// The sourcer's cut, taken after the skew. The only term that may push
        /// the answer below the lowest real sale.
        var margin: Double

        static let standard = Knobs(windowN: 5, skew: 0.30, margin: 0.10)
    }

    struct Inputs {
        /// Newest first, already filtered to this card's own grade by the caller.
        var comps: [RecentSale]
        /// Card Ladder Value — the payout, and therefore the ceiling.
        var clValueCents: Int?
        /// Courtyard's census at this grade. `nil` = not known; contributes zero
        /// rather than being inferred.
        var population: Int?
        var knobs: Knobs
    }

    /// Every intermediate the panel shows, so the number can be explained rather
    /// than trusted.
    struct Breakdown: Equatable {
        /// How many comps were actually averaged — never more than exist, which
        /// matters because the sales panel lists only five.
        var usedCount: Int
        var baseCents: Int
        var lowCents: Int
        var newestSoldAt: Date?
        var dispersion: Double
        var bottomHeaviness: Double
        var thinness: Double
        /// `s` after the automatic terms and the 0...1 clamp.
        var skewApplied: Double
        var marginApplied: Double
        var population: Int?
        /// True when CL Value, not the comps, decided the answer.
        var cappedByClValue: Bool
    }

    enum Unavailable: Equatable {
        /// The source has no usable comps for this grade. There is nothing to
        /// average, and an average of nothing is a fabricated price.
        case noComps
    }

    enum Result: Equatable {
        case price(cents: Int, breakdown: Breakdown)
        case unavailable(Unavailable)
    }

    // MARK: Weights
    //
    // Best guesses, shipped to be tuned live against the sourcer's own numbers
    // (owner decision) rather than fitted to data we do not have. Each is the
    // most `s` that its term alone can contribute.

    /// Scattered sales mean a thin, uncertain market. The strongest signal.
    static let dispersionWeight = 0.80
    /// A mean dragged up by one high sale should not set the ceiling.
    static let bottomHeavinessWeight = 0.40
    /// Few comps, or few cards in existence at this grade.
    static let thinnessWeight = 0.35

    /// Below this many comps the window starts counting as thin; at one comp it
    /// is maximally thin.
    static let thinCompCount = 5.0
    /// Population at or below this is maximally thin; at or above `popRich` it
    /// contributes nothing.
    static let popThin = 10.0
    static let popRich = 250.0

    static func compute(_ inputs: Inputs) -> Result {
        // A non-positive comp is not evidence of anything. Drop before the window
        // so a junk row cannot displace a real sale.
        let usable = inputs.comps.filter { $0.priceCents > 0 }
        let n = min(max(inputs.knobs.windowN, 1), 50)
        let window = Array(usable.prefix(n))
        guard !window.isEmpty else { return .unavailable(.noComps) }

        let prices = window.map { Double($0.priceCents) }
        let count = Double(prices.count)
        let mean = prices.reduce(0, +) / count
        guard mean > 0, let low = prices.min() else { return .unavailable(.noComps) }
        let room = mean - low

        // Dispersion, as a coefficient of variation so a $2,000 card and a $100
        // card are on the same scale.
        let variance = prices.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        let dispersion = variance.squareRoot() / mean

        // Bottom-heaviness: 0 when the comps sit evenly around their mean, 1 when
        // every one of them is below it — the shape one runaway sale produces,
        // where the mean is not what the card really trades at.
        let below = Double(prices.filter { $0 < mean }.count)
        let bottomHeaviness = max(0, 2 * (below / count - 0.5))

        // Thinness: either too few comps or too few cards in existence is enough
        // on its own, so take the worse of the two rather than averaging them.
        let thinness = max(thinnessFromCount(prices.count),
                           thinnessFromPopulation(inputs.population))

        let s = clamp01(inputs.knobs.skew
                        + dispersionWeight * dispersion
                        + bottomHeavinessWeight * bottomHeaviness
                        + thinnessWeight * thinness)
        let margin = clamp01(inputs.knobs.margin)

        let skewed = mean - s * room
        var cents = Int((skewed * (1 - margin)).rounded())

        var capped = false
        if let clValue = inputs.clValueCents, cents > clValue {
            cents = clValue
            capped = true
        }
        cents = max(cents, 0)

        return .price(cents: cents, breakdown: Breakdown(
            usedCount: window.count,
            baseCents: Int(mean.rounded()),
            lowCents: Int(low.rounded()),
            newestSoldAt: window.map(\.soldAt).max(),
            dispersion: dispersion,
            bottomHeaviness: bottomHeaviness,
            thinness: thinness,
            skewApplied: s,
            marginApplied: margin,
            population: inputs.population,
            cappedByClValue: capped
        ))
    }

    /// One comp is maximally thin; `thinCompCount` or more is not thin at all.
    static func thinnessFromCount(_ count: Int) -> Double {
        clamp01((thinCompCount - Double(count)) / (thinCompCount - 1))
    }

    /// Unknown population contributes NOTHING — it is not evidence of a large
    /// print run, and inferring one would be the same error as inventing a price.
    /// A population of 0 at this grade (CGC's pristine-10 groups report it) is a
    /// real answer and the thinnest possible market.
    static func thinnessFromPopulation(_ population: Int?) -> Double {
        guard let population else { return 0 }
        guard population > 0 else { return 1 }
        let pop = Double(population)
        if pop <= popThin { return 1 }
        if pop >= popRich { return 0 }
        // Log scale: the gap between 10 and 50 matters far more than 210 to 250.
        return clamp01(log10(popRich / pop) / log10(popRich / popThin))
    }

    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
