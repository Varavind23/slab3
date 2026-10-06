import SwiftUI

// The consignor's side of virtual members (V5, 2026-10-04). A lead's roster entry
// can be linked to an account with a one-time code; the account then sees the slabs
// credited to it — read-only, through my_credited_cards — and nothing else of the
// team. Linking is not joining: the one-team-per-account rule is untouched.

/// Enter a lead's link code.
struct LinkCodeSheet: View {
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        CaliperSheet(title: "Link to a team") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space5) {
                TextField("K7Q-2MX", text: $code)
                    .font(.price)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .foregroundStyle(Caliper.textPrimary)
                    .padding(.horizontal, Caliper.rowPad)
                    .frame(height: Caliper.hitMin)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                Text(error ?? "A lead who tracks your cards gives you this code. You'll see the cards tagged to you, read-only. It doesn't put you on their team.")
                    .caliperMeta(error == nil ? Caliper.textSecondary : Caliper.confMid)
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            CaliperButton(title: "Link", variant: .primary, fullWidth: true,
                          disabled: !JoinCode.isComplete(code) || team.isWorking) {
                Task {
                    if let failure = await team.link(code: code) { error = failure } else { dismiss() }
                }
            }
        }
    }
}

/// Every slab a lead has credited to this account, grouped by team and lot, newest
/// first. Read-only by owner decision (V5). Values are the lot's own basis at claim.
struct MyCardsSheet: View {
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var cards: [CreditedCard]?
    @State private var failed = false
    @State private var confirmUnlink: PersonLink?

    var body: some View {
        CaliperSheet(title: "My cards") {
            Button("Done") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if let cards {
                    if cards.isEmpty {
                        Text("No cards are tagged to you yet.")
                            .caliperMeta()
                            .padding(Caliper.gutter)
                    }
                    ForEach(Self.sections(cards), id: \.key) { section in
                        SectionLabel(text: section.key)
                        Hairline()
                        ForEach(section.cards) { card in
                            row(card)
                            Hairline()
                        }
                    }
                } else if failed {
                    Text("No connection. Your cards show once you're back online.")
                        .caliperMeta()
                        .padding(Caliper.gutter)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(Caliper.gutter)
                }
                SectionLabel(text: "Linked to")
                ForEach(team.links) { link in
                    SheetRow(label: link.teamName, sub: "As \(link.displayName)", trailing: "Unlink") {
                        confirmUnlink = link
                    }
                    Hairline()
                }
            }
        } confirm: {
            EmptyView()
        }
        .task { await reload() }
        .confirmationDialog("Unlink from \(confirmUnlink?.teamName ?? "")?",
                            isPresented: Binding(get: { confirmUnlink != nil }, set: { if !$0 { confirmUnlink = nil } }),
                            titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                guard let link = confirmUnlink else { return }
                Task { _ = await team.unlinkMine(link); await reload() }
            }
        } message: {
            Text("You'll stop seeing their cards here. They keep the record.")
        }
    }

    private func reload() async {
        if let fetched = await team.creditedCards() { cards = fetched; failed = false } else { failed = cards == nil }
    }

    /// "Team · Lot" sections in the order their newest card arrived.
    static func sections(_ cards: [CreditedCard]) -> [(key: String, cards: [CreditedCard])] {
        var order: [String] = []
        var by: [String: [CreditedCard]] = [:]
        for card in cards {
            let key = "\(card.teamName) · \(card.lotName)"
            if by[key] == nil { order.append(key) }
            by[key, default: []].append(card)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    private func row(_ card: CreditedCard) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Caliper.space5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.calBody).foregroundStyle(Caliper.textPrimary).lineLimit(1)
                Text(["\(card.grader.uppercased()) \(card.gradeLabel ?? "\u{2014}")", "#\(card.cert)",
                      "added by \(card.addedBy)",
                      card.scannedDate?.formatted(.dateTime.month(.abbreviated).day())]
                        .compactMap { $0 }.joined(separator: " · "))
                    .caliperMeta(Caliper.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Caliper.space4)
            // A missing value is an em dash, never $0 (Caliper).
            Text(card.valueCents.map { Money.dollars(Int64($0)) } ?? "\u{2014}")
                .font(.price).monospacedDigit().foregroundStyle(Caliper.textPrimary)
            Text(card.basisLabel).caliperLabel(Caliper.textTertiary)
        }
        .padding(.horizontal, Caliper.gutter)
        .frame(minHeight: Caliper.hitMin + 8)
    }
}
