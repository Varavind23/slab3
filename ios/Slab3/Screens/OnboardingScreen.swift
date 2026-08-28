import SwiftUI

/// Three swipeable cards explaining the loop before first use, replayable from
/// Settings → How it works (README.md §1). The copy is verbatim from the handoff:
/// it's the register the rest of the product's voice is checked against.
struct OnboardingScreen: View {
    let finish: () -> Void
    @State private var step = 0

    private struct Step {
        let glyph: String
        let title: String
        let body: String
        let footnote: String
    }

    private let steps: [Step] = [
        Step(
            glyph: "hand.tap",
            title: "Move through the stack",
            body: "Hold a PSA or CGC code in frame and it captures automatically — the cert number is all the app needs to identify the card.",
            footnote: "Torch lives under the viewfinder for shiny slabs and difficult light."
        ),
        Step(
            glyph: "chart.bar",
            title: "Two markets, one row",
            body: "Every card carries prices from CL and CY, each with a confidence meter showing how sure the match is. Switch which source leads with the toggle up top — the other one never disappears.",
            footnote: "A source with no data shows an em dash. Nothing here ever invents a number."
        ),
        Step(
            glyph: "square.and.arrow.up",
            title: "Group by buyer, export CSV",
            body: "Select cards until the running total hits your target, drop them into a buyer's group, then filter to that group and export. The filename carries the buyer and the date.",
            footnote: "The CSV is usually the only part of this app your buyer ever sees."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Step 0\(step + 1)").caliperLabel(Caliper.cyan)
                Spacer()
                Button("Skip", action: finish)
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space7)

            TabView(selection: $step) {
                ForEach(steps.indices, id: \.self) { i in
                    card(steps[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            progress
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space7)

            CaliperButton(
                title: step == steps.count - 1 ? "Open the scanner" : "Next",
                variant: .primary,
                fullWidth: true
            ) {
                if step == steps.count - 1 { finish() } else { withAnimation(Caliper.easeOut) { step += 1 } }
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.bottom, Caliper.space8)
        }
        .background(Caliper.bg.ignoresSafeArea())
    }

    private func card(_ step: Step) -> some View {
        VStack(spacing: Caliper.space7) {
            Spacer()
            Image(systemName: step.glyph)
                .font(.system(size: 24))
                .foregroundStyle(Caliper.cyan)
                .frame(width: 52, height: 52)
                .background(Caliper.cyan.opacity(0.06))
                .overlay(Rectangle().strokeBorder(Caliper.cyanDim, lineWidth: Caliper.borderWidth))

            Text(step.title)
                .font(.sans(29, .semibold))
                .tracking(-1)
                .foregroundStyle(Caliper.textPrimary)
                .multilineTextAlignment(.center)

            Text(step.body)
                .font(.sans(14, .regular))
                .foregroundStyle(Caliper.textSecondary)
                .lineSpacing(6)
                .multilineTextAlignment(.center)

            Hairline()
            Text(step.footnote)
                .caliperMeta(Caliper.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, Caliper.gutter)
    }

    /// Three 2pt bars, tappable; the active one carries the bloom.
    private var progress: some View {
        HStack(spacing: Caliper.space4) {
            ForEach(steps.indices, id: \.self) { i in
                Rectangle()
                    .fill(i <= step ? Caliper.cyan : Caliper.line)
                    .frame(height: 2)
                    .modifier(BarGlow(active: i == step))
                    .contentShape(Rectangle().inset(by: -12))
                    .onTapGesture { withAnimation(Caliper.easeOut) { step = i } }
            }
        }
    }
}

private struct BarGlow: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.shadow(color: Caliper.cyan.opacity(0.5), radius: 6) } else { content }
    }
}
