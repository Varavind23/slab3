import SwiftUI

/// "12 cards deleted · Undo" — the few seconds between a delete and it being real.
///
/// It takes the slot `SelectionBar` occupies, above the tab bar, for the same
/// reason that one lives there: it belongs to no single screen. The two are
/// mutually exclusive by construction — a bulk delete ends selection first — so
/// they never stack.
///
/// On the one-cyan-action rule: while this bar is up, Undo IS the screen's
/// committed action. It is transient, it is the only action it offers, and the
/// selection bar cannot be on screen beside it, so nothing is competing for that
/// role. Deleting is the destructive thing here and it has already happened
/// visually — the red belongs to the act, not to the way back from it.
struct UndoBar: View {
    let label: String
    let undo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Caliper.line).frame(height: Caliper.borderWidth)
            HStack(spacing: Caliper.space4) {
                Text(label).caliperLabel(Caliper.textSecondary)
                Spacer(minLength: Caliper.space4)
                Button(action: undo) {
                    Text("Undo")
                        .caliperLabel(Caliper.cyan)
                        .frame(minHeight: Caliper.hitMin)
                        .padding(.horizontal, Caliper.space4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CaliperPressStyle())
                .accessibilityLabel("Undo delete")
            }
            .padding(.leading, Caliper.gutter)
            .padding(.trailing, Caliper.gutter - Caliper.space4)
        }
        .background(Caliper.surface)
    }
}
