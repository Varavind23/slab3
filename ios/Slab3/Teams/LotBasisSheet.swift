import SwiftUI

/// Switch an existing lot between CL and CY value (owner M4/M5, 2026-10-01).
///
/// NEVER ONE TAP, by owner decision: the row in the lot builder opens this sheet,
/// the sheet asks the server what the switch would do (`set_lot_basis` with
/// `commit: false`, which writes nothing), and only the named confirm button
/// switches. It can happen with buys already in the lot because every claim
/// records both sources' values; what the sheet spells out is the fallout — slabs
/// the new source cannot value (they keep their slots, add no dollars), slabs now
/// outside their bucket's range, buckets now over budget. Nobody's buy is moved
/// or released.
struct LotBasisSheet: View {
    @Bindable var app: AppState
    let lot: Lot
    @Environment(\.dismiss) private var dismiss

    @State private var impact: LotStore.BasisImpact?
    @State private var error: String?
    @State private var working = false

    private var target: ValueBasis { lot.valueBasis == .cl ? .cy : .cl }

    var body: some View {
        CaliperSheet(title: "Value basis") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space5) {
                Text("This lot counts \(lot.valueBasis.valueAtClaim). Switching counts \(target.valueAtClaim) instead: buckets, budgets and the 3-of-a-card limit all follow \(target.sourceName).")
                    .font(.calBody)
                    .foregroundStyle(Caliper.textPrimary)
                if target == .cy {
                    Text("Members won't need a Card Ladder account to buy into it.").caliperMeta()
                } else {
                    Text("Members will need a Card Ladder account to buy into it.").caliperMeta(Caliper.confMid)
                }

                if let impact {
                    VStack(spacing: 0) {
                        fact("Slabs in the lot", "\(impact.claims)")
                        fact("No \(target.short) value", "\(impact.noValue)",
                             note: impact.noValue > 0 ? "Keep their slots, add no dollars" : nil)
                        fact("Now outside their bucket", "\(impact.outsideRange)",
                             note: impact.outsideRange > 0 ? "Stay where they are" : nil)
                        fact("Buckets over budget", "\(impact.overBudget)",
                             note: impact.overBudget > 0 ? "Take no more cards" : nil)
                    }
                    .caliperPanel()
                    Text("Nobody's buy is moved or released.").caliperMeta()
                } else if error == nil {
                    Text("Checking what changes…").caliperMeta()
                }
                if let error { Text(error).caliperMeta(Caliper.confLow) }
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            CaliperButton(title: "Switch lot to \(target.short) value", variant: .primary, fullWidth: true,
                          disabled: impact == nil || working) {
                Task { await commit() }
            }
        }
        .task { await preview() }
    }

    private func fact(_ label: String, _ value: String, note: String? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).caliperLabel(Caliper.textTertiary)
                    if let note { Text(note).caliperMeta(Caliper.confMid) }
                }
                Spacer(minLength: Caliper.space4)
                Text(value).font(.price).monospacedDigit().foregroundStyle(Caliper.textPrimary)
            }
            .padding(.horizontal, Caliper.rowPad)
            .frame(minHeight: Caliper.hitMin)
            Hairline()
        }
    }

    private func preview() async {
        guard let teamId = app.team.team?.id else { return }
        let result = await app.lots.switchBasis(lot.id, to: target, commit: false, teamId: teamId)
        impact = result.impact
        error = result.error
    }

    private func commit() async {
        guard let teamId = app.team.team?.id else { return }
        working = true
        defer { working = false }
        let result = await app.lots.switchBasis(lot.id, to: target, commit: true, teamId: teamId)
        if let failure = result.error { error = failure; return }
        dismiss()
    }
}
