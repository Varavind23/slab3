import SwiftUI

/// The card detail screen's ONE hero figure: the value from whatever currently
/// LEADS, with that source's last sale beneath it.
///
/// It follows the header toggle (owner decision 2026-08-31). It used to be hardwired
/// to Card Ladder, so selecting Courtyard changed the comps underneath while the big
/// number kept saying CL — two sources' figures stacked on one screen with nothing
/// marking the difference, which is the misreading the toggle exists to prevent. One
/// thing is selected; the whole block speaks for it.
///
/// Since 2026-09-22 that "one thing" can also be our own max-buy figure. Under that
/// lens the block takes `knobs` from the panel below rather than the saved defaults,
/// so moving a slider moves this number too — the same rule, applied to the same
/// hazard: two differently-tuned max buys on one screen, both labelled "Max buy",
/// would be exactly the confusion described above.
///
/// A view of its own rather than a computed property on `CardDetailScreen` because
/// `ImageRenderer` will not lay out the `ScrollView` that screen wraps everything in,
/// and this is the only way its layout can be rendered and LOOKED AT — the same
/// reason `SalesPanel` and `MaxBuyPanel` are their own views.
///
/// Value leads because it is what a reseller decides against; the last sale is the
/// single hard data point behind it, and the comps panel shows the rest of the
/// evidence. Nothing else on that screen may use `.figure`. A missing number is an em
/// dash, never $0 (`caliperMoney`).
struct ValueBlock: View {
    let card: Card
    let lens: PriceLens
    /// Only read under the max-buy lens; the source path ignores it.
    var knobs: MaxBuyPrice.Knobs = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            if let source = lens.source {
                sourceValue(source)
                lastSold(source)
                if source == .cl ? card.cardLadderIsStale : card.courtyardIsStale {
                    Text("Couldn\u{2019}t refresh — showing the last known value")
                        .caliperMeta(Caliper.textTertiary)
                }
            } else {
                maxBuyValue
                // "Last sold" still belongs to a source, so under max buy it names
                // the one whose comps actually answered rather than borrowing
                // whichever source happened to be underneath the lens.
                if let comps = MaxBuyValue.compsSource(for: card) { lastSold(comps) }
            }
        }
    }

    // MARK: A source's value

    private func sourceValue(_ source: PriceSource) -> some View {
        let price = card.prices[source]
        let confidence = card.confidences[source]
        return VStack(alignment: .leading, spacing: Caliper.space1) {
            Text("\(source.rawValue) Value").caliperLabel(Caliper.textTertiary)
            Text(caliperMoney(cents: price))
                .font(.figure)
                .foregroundStyle(price == nil ? Caliper.textTertiary : source.hue)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if confidence > 0 {
                ConfidenceMeter(value: confidence, source: source)
            }
        }
    }

    // MARK: Our own figure

    /// No confidence meter, deliberately. A meter grades how sure we are of the
    /// MATCH — that this is the right card — which is a claim a source makes. Ours
    /// is arithmetic over comps whose weights the owner has not yet calibrated, and
    /// drawing a meter beside it would assert a precision nothing has established.
    private var maxBuyValue: some View {
        let answer = MaxBuyValue.answer(for: card, knobs: knobs)
        return VStack(alignment: .leading, spacing: Caliper.space1) {
            Text("Max buy").caliperLabel(Caliper.textTertiary)
            Text(caliperMoney(cents: answer.cents))
                .font(.figure)
                .foregroundStyle(answer.cents == nil ? Caliper.textTertiary : Caliper.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    // MARK: Last sold

    private func lastSold(_ source: PriceSource) -> some View {
        let sale = lastSale(for: source)
        return VStack(alignment: .leading, spacing: Caliper.space1) {
            Text("Last sold").caliperLabel(Caliper.textTertiary)
            Text(caliperMoney(cents: sale?.cents))
                .font(.figureSmall)
                .foregroundStyle(sale == nil ? Caliper.textTertiary : Caliper.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let at = sale?.at {
                Text(at.formatted(.dateTime.month(.abbreviated).day().year()))
                    .caliperMeta(Caliper.textTertiary)
            }
        }
    }

    /// The selected source's most recent sale.
    ///
    /// Card Ladder states one directly (it rides the estimate call). Courtyard does
    /// not: its scanner response carries the sale HISTORY, already filtered to this
    /// slab's grader and grade and sorted newest first, so the head of that list IS
    /// its last sold. Deriving it beats storing a field that could drift from the
    /// comps shown right below it.
    private func lastSale(for source: PriceSource) -> (cents: Int, at: Date?)? {
        switch source {
        case .cl:
            guard let cents = card.cardLadderLastSaleCents else { return nil }
            return (cents, card.cardLadderLastSaleAt)
        case .cy:
            guard let newest = card.courtyardSales?.first else { return nil }
            return (newest.priceCents, newest.soldAt)
        }
    }
}
