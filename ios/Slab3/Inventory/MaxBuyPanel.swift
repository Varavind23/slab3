import SwiftUI

/// The Verified Max Buy Price box — the first panel on the card detail screen.
/// Behind a testing passcode until 0.9; available to everyone since (owner,
/// 2026-10-01).
///
/// A view of its own rather than a computed property on CardDetailScreen for the
/// same reason SalesPanel is: ImageRenderer will not lay out the ScrollView the
/// detail screen wraps everything in, so this is the only way its layout can be
/// rendered and LOOKED AT. See ios/Tests/MaxBuyPanelRenderTests.swift.
///
/// COLLAPSED IT SHOWS ONLY THE NUMBER, and that is the point. A sourcer holds this
/// screen out to the person he is buying from, so anything that reveals the figure
/// is tunable — sliders, his margin, the weights — undermines the number he is
/// presenting. "More" is the one affordance, and everything that could be read as
/// negotiating room lives behind it.
///
/// This is a deliberate exception to SalesPanel's "empty is REAL CONTENT, never a
/// hidden panel" rule. That rule is about hiding data from the USER; this hides the
/// user's own negotiating room from the person across the table.
struct MaxBuyPanel: View {
    let card: Card

    /// Per-card, and reset to the stored baseline on every card: a figure tuned
    /// during one negotiation must not silently follow him into the next.
    ///
    /// Owned by `CardDetailScreen` since 2026-09-22, not by this panel, because the
    /// hero above now shows the same figure and has to move with these sliders —
    /// two differently-tuned max buys on one screen, both labelled the same, is the
    /// exact misreading the hero's toggle-following rule exists to prevent.
    @Binding var knobs: MaxBuyPrice.Knobs

    @State private var expanded: Bool

    /// `initiallyExpanded` exists so the render test can photograph the open
    /// state — there is no other way in from outside, and the open state is the
    /// half with the layout worth looking at.
    init(card: Card, knobs: Binding<MaxBuyPrice.Knobs>, initiallyExpanded: Bool = false) {
        self.card = card
        _knobs = knobs
        _expanded = State(initialValue: initiallyExpanded)
    }

    private static let presetWindows = [3, 5, 10]

    /// The payout, and therefore the ceiling — Card Ladder Value (Courtyard's on a
    /// CY lot), whichever source's comps are being read.
    private var capCents: Int? { card.prices[answer.capSource] }
    private var capName: String { answer.capSource == .cl ? "CL Value" : "CY value" }

    /// Which comps, which cap, which population all live in `MaxBuyValue` now, so
    /// this panel and the five other places that show the figure cannot drift.
    private var answer: MaxBuyValue.Answer {
        MaxBuyValue.answer(for: card, knobs: knobs.sanitized)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            header
            figure
            if expanded { controls }
        }
        .padding(Caliper.rowPad)
        .caliperPanel()
        .onChange(of: card.localId) { _, _ in expanded = false }
    }

    private var header: some View {
        HStack(spacing: Caliper.space3) {
            Text("Verified max buy price").caliperLabel(Caliper.textTertiary)
                .fixedSize()
            Spacer(minLength: Caliper.space2)
            Button {
                withAnimation(Caliper.easeOut) { expanded.toggle() }
            } label: {
                HStack(spacing: Caliper.space2) {
                    Text(expanded ? "Less" : "More").caliperLabel(Caliper.textSecondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Caliper.textTertiary)
                }
                .frame(minHeight: Caliper.hitMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityLabel(expanded ? "Hide controls" : "Show controls")
        }
        // The chevron's 44pt target would otherwise stretch the collapsed panel.
        .frame(height: Caliper.hitMin)
    }

    @ViewBuilder
    private var figure: some View {
        switch answer.result {
        case .price(let cents, _):
            // figureSmall, never .figure: valueBlock holds this screen's one hero
            // number and this panel deliberately does not take it. textPrimary
            // rather than a source hue — the figure is ours, not Card Ladder's or
            // Courtyard's, and colouring it either way would claim otherwise.
            Text(caliperMoney(cents: cents))
                .font(.figureSmall)
                .foregroundStyle(Caliper.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: Caliper.space2) {
                Text(caliperMoney(cents: nil))
                    .font(.figureSmall)
                    .foregroundStyle(Caliper.textTertiary)
                Text(note(for: reason)).caliperMeta(Caliper.textTertiary)
            }
        }
    }

    /// Names the source only when one actually answered. With no comps anywhere,
    /// blaming a source the user did not choose would be worse than saying plainly
    /// that nothing has sold.
    private func note(for reason: MaxBuyPrice.Unavailable) -> String {
        switch reason {
        case .noComps:
            switch answer.compsSource {
            case .cl: return "No Card Ladder sales at this grade to price against"
            case .cy: return "No Courtyard sales at this grade to price against"
            case nil: return "No recent sales at this grade to price against"
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Caliper.space5) {
            Hairline()

            windowRow

            knobRow(label: "Skew to the low end", value: knobs.skew) {
                MaxBuyKnobSlider(value: $knobs.skew, floor: MaxBuyDefaults.team?.skew ?? 0)
            }

            knobRow(label: "Margin", value: knobs.margin) {
                MaxBuyKnobSlider(value: $knobs.margin, floor: MaxBuyDefaults.team?.margin ?? 0)
            }

            if case .price(let cents, let breakdown) = answer.result {
                Hairline()
                Text(summary(breakdown))
                    .caliperMeta(Caliper.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                impliedMargin(vmbCents: cents)
            }
        }
    }

    private var windowRow: some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            HStack {
                Text("Average of").caliperLabel(Caliper.textTertiary)
                Spacer()
                Text("\(knobs.sanitized.windowN) sales").caliperMeta(Caliper.textSecondary)
            }
            HStack(spacing: Caliper.space3) {
                ForEach(Self.presetWindows, id: \.self) { n in
                    Button {
                        knobs.windowN = n
                    } label: {
                        // NOT `.filled`: that tone fills with cyan, and this
                        // screen has already spent its one cyan primary on
                        // "Refresh prices now". Selected/unselected reads as
                        // standard vs quiet, the same language the export column
                        // grid uses for included vs not.
                        Chip(text: "\(n)",
                             tone: knobs.sanitized.windowN == n ? .source : .quiet,
                             color: Caliper.textPrimary,
                             size: .tap)
                        .frame(minHeight: Chip.Size.tap.hitHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CaliperPressStyle())
                    .accessibilityLabel("Average the last \(n) sales")
                }

                TextField("N", value: $knobs.windowN, format: .number)
                    .font(.price)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Caliper.textPrimary)
                    .frame(width: 58, height: Chip.Size.tap.hitHeight)
                    .overlay(Rectangle().strokeBorder(Caliper.line, lineWidth: Caliper.borderWidth))
                    .accessibilityLabel("Custom number of sales to average")

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func knobRow(label: String, value: Double,
                         @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            HStack {
                Text(label).caliperLabel(Caliper.textTertiary)
                Spacer()
                Text((value * 100).formatted(.number.precision(.fractionLength(0))) + "%")
                    .caliperMeta(Caliper.textSecondary)
            }
            control()
        }
    }

    /// What the number was actually built from. The sales panel below lists only
    /// five, so when the window is wider than that this line is the only place the
    /// real count is stated.
    ///
    /// It is ALSO the only place the comps basis is disclosed now that the row and
    /// the hero deliberately say nothing about it (owner, 2026-09-22): the figure
    /// gets held out to the person being bought from, and a `MAX BUY · CL` suffix
    /// on it would put our evidence in their hands. Here, behind "More", it is for
    /// the sourcer.
    private func summary(_ b: MaxBuyPrice.Breakdown) -> String {
        var parts = ["avg of \(b.usedCount)"]
        // Population comes from Courtyard even when Card Ladder supplied the
        // comps — it is the only source that carries one — so the line names the
        // comp source to keep the two straight.
        if let pop = b.population { parts.append("pop \(pop)") }
        parts.append("spread \((b.dispersion * 100).formatted(.number.precision(.fractionLength(0))))%")
        if let source = answer.compsSource { parts.append("\(source.rawValue) comps") }
        if b.cappedByClValue { parts.append("held at \(capName)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func impliedMargin(vmbCents: Int) -> some View {
        HStack {
            Text("Margin vs \(capName)").caliperLabel(Caliper.textTertiary)
            Spacer()
            if let clValue = capCents, clValue > 0 {
                let pct = Double(clValue - vmbCents) / Double(clValue) * 100
                Text(caliperMoney(cents: clValue) + "  \u{2192}  "
                     + pct.formatted(.number.precision(.fractionLength(0))) + "%")
                    .caliperMeta(pct > 0 ? Caliper.payout : Caliper.confLow)
            } else {
                // No CL Value means no payout to measure against. Saying nothing
                // is honest; a percentage of an unknown is not.
                Text(caliperMoney(cents: nil)).caliperMeta(Caliper.textTertiary)
            }
        }
    }
}
