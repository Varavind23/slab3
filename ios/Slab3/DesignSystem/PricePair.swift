import SwiftUI

/// The two market prices for a card, side by side (design.md §1, §2, §6). This
/// is one of only two places identity shows up, so it carries the system's one
/// moment of delight: the winning price gets softened green + a subtle glow.
///
/// Accessibility is load-bearing, not decorative (design.md §1): the winner is
/// ALSO bold weight + a leading ▲ glyph, so a red-green colorblind user reads
/// the winner from weight and glyph alone. The loser stays regular weight, no
/// glyph. Color is the fast path, never the only channel.
///
/// States: both-missing / tied → neither wins (muted "—"); loading → quiet
/// placeholder, no false "no price" flash.
struct PricePair: View {
    let courtyardCents: Int?
    let cardLadderCents: Int?
    var loading: Bool = false

    private enum Winner { case courtyard, cardLadder, none }
    private var winner: Winner {
        guard let c = courtyardCents, let l = cardLadderCents else { return .none }
        if c == l { return .none }
        return c > l ? .courtyard : .cardLadder
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            column("Courtyard", cents: courtyardCents, isWinner: winner == .courtyard)
            column("Card Ladder", cents: cardLadderCents, isWinner: winner == .cardLadder)
        }
    }

    @ViewBuilder
    private func column(_ label: String, cents: Int?, isWinner: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if loading {
                ProgressView().controlSize(.small).frame(height: 30)
            } else {
                HStack(spacing: 3) {
                    if isWinner {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.win)
                    }
                    Text(priceText(cents))
                        .font(isWinner ? .priceLarge : .priceSmall)
                        .foregroundStyle(color(isWinner: isWinner, hasValue: cents != nil))
                }
                .modifier(WinGlow(active: isWinner))
            }
            Text(label).slabLabel()
        }
    }

    private func priceText(_ cents: Int?) -> String {
        guard let cents else { return "—" }
        return "$" + (Double(cents) / 100).formatted(.number.precision(.fractionLength(0)))
    }

    private func color(isWinner: Bool, hasValue: Bool) -> Color {
        if !hasValue { return Palette.textSecondary } // no-price: muted, no red/green
        if isWinner { return Palette.win }
        // A present loser: red only when there's an actual comparison (a winner exists).
        return winner == .none ? Palette.textPrimary : Palette.lose
    }
}

/// The one glow in the whole system — only the winning green price gets it.
private struct WinGlow: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content
                .shadow(color: Palette.win.opacity(0.55), radius: 7)
                .shadow(color: Palette.win.opacity(0.30), radius: 14)
        } else {
            content
        }
    }
}

#Preview {
    VStack(spacing: 28) {
        PricePair(courtyardCents: 53700, cardLadderCents: 61200) // CL wins
        PricePair(courtyardCents: 76120, cardLadderCents: 54000) // CY wins
        PricePair(courtyardCents: nil, cardLadderCents: nil)     // no price
        PricePair(courtyardCents: 5000, cardLadderCents: 5000)   // tied
        PricePair(courtyardCents: nil, cardLadderCents: nil, loading: true)
    }
    .padding()
    .background(Palette.bg)
}
