import SwiftUI

/// The comps panel on the card detail screen: up to five real completed sales of
/// this card at this grade.
///
/// A view of its own rather than a computed property on CardDetailScreen so its
/// layout can be rendered and LOOKED AT in isolation — ImageRenderer will not lay
/// out the ScrollView the detail screen wraps everything in, and this panel
/// shipped with three overflow bugs that no assertion caught. See
/// ios/Tests/DetailScreenRenderTests.swift.
struct SalesPanel: View {
    let card: Card
    @Binding var source: PriceSource
    let connected: Bool
    let onConnect: () -> Void

    /// Empty is REAL CONTENT, never a hidden panel. "No recent sales" (the source
    /// answered and has none) and "not fetched" are different facts and say
    /// different things. Nothing here is ever synthesized.
    var body: some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            // The header used SectionLabelInline, which is built to be the FULL
            // WIDTH of a panel and carries its own padding — inside an HStack it
            // claimed every point and pushed the grade and the CL|CY toggle past
            // the panel's right edge. A plain label here, and the toggle is
            // fixed-size with priority so it is never the thing that gets
            // squeezed.
            HStack(spacing: Caliper.space3) {
                Text("Recent sales").caliperLabel(Caliper.textTertiary)
                    .fixedSize()
                if let grade = card.grade {
                    // A separator, because the label and the grade are both
                    // tracked mono in tertiary and ran together as one string
                    // ("RECENT SALES PSA 10 GEM MINT").
                    Text("\u{00B7}").caliperMeta(Caliper.line)
                    Text("\(card.grader.rawValue.uppercased()) \(grade)")
                        .caliperMeta(Caliper.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Caliper.space2)
                SourceToggle(value: $source)
                    .fixedSize()
                    .layoutPriority(1)
            }

            let sales = card.sales(for: source)
            if source == .cl && !connected {
                emptyNote("Connect Card Ladder to see sales")
                CaliperButton(title: "Connect Card Ladder", variant: .outline, fullWidth: true) {
                    onConnect()
                }
            } else if card.salesLoading && sales == nil {
                emptyNote("Loading sales\u{2026}")
            } else if let sales, !sales.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(sales.prefix(5).enumerated()), id: \.offset) { index, sale in
                        if index > 0 { Hairline() }
                        saleRow(sale)
                    }
                }
            } else if sales != nil {
                // The source answered: it genuinely has no comps for this card.
                emptyNote(source == .cl
                          ? "No recent sales on Card Ladder"
                          : "No recent sales on Courtyard")
            } else {
                emptyNote("Sales not loaded")
            }
        }
        // caliperPanel draws only a fill and a hairline — the padding is the
        // panel's own job, and without it the content sat on the border.
        .padding(Caliper.rowPad)
        .caliperPanel()
    }

    /// One comp. Money leads at `saleFigure`; the date is pinned to the trailing
    /// edge and the provenance in the middle is the only part allowed to shrink.
    ///
    /// It used to be money / provenance / Spacer / date with nothing pinned or
    /// truncated, so a long provenance ("eBay · Best offer") pushed the date off
    /// the panel. The date is the second most important thing in a comp — a price
    /// without its date is not evidence — so it never yields.
    private func saleRow(_ sale: RecentSale) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Caliper.space3) {
            // Right-aligned in a fixed column so the digits line up down the
            // list: these numbers exist to be compared with each other, and a
            // ragged left edge makes $99 and $1,281 read as the same magnitude.
            // Monospaced digits (saleFigure) do the rest.
            Text(caliperMoney(cents: sale.priceCents))
                .font(.saleFigure)
                .foregroundStyle(Caliper.textPrimary)
                .lineLimit(1)
                .frame(minWidth: 82, alignment: .trailing)
                .layoutPriority(2)

            Text(sale.provenance)
                .caliperMeta(Caliper.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sale.soldAt.formatted(.dateTime.month(.abbreviated).day().year()))
                .caliperMeta(Caliper.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.vertical, Caliper.space3)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .caliperMeta(Caliper.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Caliper.space2)
    }
}
