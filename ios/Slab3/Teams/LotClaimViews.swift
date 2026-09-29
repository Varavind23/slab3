import SwiftUI
import SwiftData

extension LotVerdictText.Tone {
    /// Amber for anything that needs the buyer's eye (Caliper's duplicate tone —
    /// never red, which is Delete's alone); quiet grey while checking.
    var color: Color {
        switch self {
        case .quiet: Caliper.textTertiary
        case .good: Caliper.textPrimary
        case .warn: Caliper.confMid
        }
    }
}

/// The one-line lot state, wherever a card is listed: the scan toast's fourth
/// line, the Recent scans row, the Cards row's third line.
struct LotVerdictLabel: View {
    let card: Card
    var body: some View {
        if let state = card.lotClaimState {
            let line = LotVerdictText.line(state: state, verdict: card.lotVerdict)
            Text(line.text).caliperLabel(line.tone.color).lineLimit(1)
        }
    }
}

/// The card detail screen's Lot panel: where the buyer ACTS on a verdict — pick a
/// bucket, see the three buys that filled a card's slots, retry, or clear a block.
///
/// Sits low on the screen, beside Group, on purpose: this screen gets held out to
/// the seller (MaxBuyPanel's rationale), and a teammate's name and what they paid
/// have no business at the top of it.
struct LotClaimPanel: View {
    let card: Card
    @Environment(\.modelContext) private var context

    var body: some View {
        if let state = card.lotClaimState, let lotId = card.lotClaimLotId {
            let verdict = card.lotVerdict
            let line = LotVerdictText.line(state: state, verdict: verdict)
            VStack(alignment: .leading, spacing: Caliper.space4) {
                Text("Lot").caliperLabel()
                Text(line.text).caliperLabel(line.tone.color)

                if state == .blocked, verdict?.reason == "limit_reached", let existing = verdict?.existing {
                    ForEach(Array(existing.enumerated()), id: \.offset) { _, buy in
                        HStack {
                            Text(buy.buyer ?? "A teammate").font(.calBody).foregroundStyle(Caliper.textPrimary)
                            Spacer()
                            Text(buy.scannedAt.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "\u{2014}")
                                .caliperMeta()
                        }
                    }
                }

                if state == .chooseRange, let candidates = verdict?.candidates {
                    Text("It fits more than one bucket. Pick where it goes — nothing is held until you do.")
                        .caliperMeta()
                    ForEach(candidates) { c in
                        CaliperButton(title: "\(c.name) · \(c.cardsLeft) cards · \(Money.dollars(c.centsLeft)) left",
                                      variant: .outline, fullWidth: true) {
                            Task { await LotClaims.claim(card, lotId: lotId, rangeId: c.rangeId, in: context) }
                        }
                    }
                }

                if state == .pending {
                    CaliperButton(title: "Check again", variant: .outline, icon: "arrow.clockwise", fullWidth: true) {
                        Task { await LotClaims.claim(card, lotId: lotId, in: context) }
                    }
                }

                if state == .blocked {
                    Button("Clear") {
                        card.lotClaimState = nil
                        card.lotClaimLotId = nil
                        card.lotVerdict = nil
                        try? context.save()
                    }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
                    .frame(minHeight: Caliper.hitMin)
                }
            }
            .padding(Caliper.rowPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .caliperPanel()
        }
    }
}
