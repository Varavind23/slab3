import SwiftUI
import SwiftData

/// The card detail screen's Member panel (V4, 2026-10-04): who sourced this slab.
///
/// A lot slab shows its claim's buyer — the team's record, changed by a lead in the
/// lot's receipt, so it is read-only here. Any other card can be tagged on this phone.
/// Sits low, beside Group and Lot, for LotClaimPanel's reason: this screen gets held
/// out to the seller.
struct CardMemberPanel: View {
    @Bindable var card: Card
    @Bindable var app: AppState
    @Environment(\.modelContext) private var context
    @State private var choosing = false

    var body: some View {
        let claim = CardTagging.claim(for: card, in: app.lots.claimsByLot)
        let name = CardTagging.buyerName(for: card, claimsByLot: app.lots.claimsByLot,
                                         members: app.team.members, people: app.team.people)
        VStack(alignment: .leading, spacing: 0) {
            SectionLabelInline(text: "Member")
            if claim != nil {
                Text(name ?? "\u{2014}").font(.calBody).foregroundStyle(Caliper.textPrimary)
                    .padding(.horizontal, Caliper.rowPad)
                Text("Set for the whole team in the lot's receipt" + (app.team.isLead ? " (Team activity)." : ", by a lead."))
                    .caliperMeta()
                    .padding(.horizontal, Caliper.rowPad)
                    .padding(.bottom, Caliper.rowPad)
            } else {
                SheetRow(label: name ?? "No one", sub: "Who sourced it · this phone only", trailing: "›") {
                    choosing = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .caliperPanel()
        .confirmationDialog("Who sourced this card?", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(app.team.buyerChoices) { buyer in
                Button(buyer.isVirtual ? "\(buyer.name) · virtual" : buyer.name) { set(buyer) }
            }
            if card.creditedPersonId != nil { Button("Clear", role: .destructive) { set(nil) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func set(_ buyer: Buyer?) {
        card.creditedPersonId = buyer?.id
        card.creditedName = buyer?.name
        try? context.save()
    }
}
