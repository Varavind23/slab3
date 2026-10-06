import SwiftUI
import SwiftData

/// One card in full. The row is deliberately dense; this is where the sourcer
/// corrects identity, sees why a price is missing, and files the card.
///
/// Both sources get a line stating what the last fetch actually
/// returned — "not listed" and "couldn't be reached" are different facts, and the
/// row can only ever show an em dash for both.
struct CardDetailScreen: View {
    @Bindable var card: Card
    @Bindable var app: AppState
    /// The same undo window as the list's swipe and bulk delete — a delete from
    /// here is just as irreversible, so it must not be the one path that skips it.
    let pendingDeletes: PendingDeletionStore
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.createdAt, order: .reverse) private var groups: [Folder]

    @AppStorage(PriceService.connectedKey) private var cardLadderConnected = false
    @State private var showConnect = false

    /// The max-buy knobs for THIS card. Owned here rather than inside `MaxBuyPanel`
    /// because the hero shows the same figure and has to move with the panel's
    /// sliders (owner, 2026-09-22).
    ///
    /// Per-card, and reset to the stored baseline on every card: a figure tuned
    /// during one negotiation must not silently follow him into the next. The Cards
    /// list always shows the baseline figure, so a card tuned here can legitimately
    /// read differently there — the panel is the negotiation scratchpad, the list is
    /// the one consistent basis.
    @State private var maxBuyKnobs = MaxBuyDefaults.current

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                context: "#\(card.certNumber)",
                title: card.displayTitle,
                lens: $app.lens,
                lenses: app.availableLenses
            ) {
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }

            ScrollView {
                VStack(spacing: Caliper.rowGap) {
                    slabPanel
                    // The first box, above the evidence it is built from.
                    MaxBuyPanel(card: card, knobs: $maxBuyKnobs)
                    SalesPanel(card: card, source: $app.activeSource,
                               connected: cardLadderConnected) { showConnect = true }
                    pricePanel
                    identityPanel
                    LotClaimPanel(card: card)
                    groupPanel
                    if app.team.team != nil { CardMemberPanel(card: card, app: app) }
                    notesPanel

                    CaliperButton(title: "Refresh prices now", variant: .accent, icon: "arrow.clockwise", fullWidth: true,
                                  disabled: card.pricesLoading) {
                        // One card, so bypassing the 24h Card Ladder cache costs a
                        // single request from the daily budget. This is now the
                        // ONLY way a price is re-fetched by hand: the Cards tab's
                        // refresh-all was removed 2026-09-16, because one tap there
                        // fired a stack-sized burst at the endpoint that 403s an IP
                        // for hammering it.
                        Task { await PriceService.refresh(card, in: context, force: true) }
                    }
                    CaliperButton(title: "Delete card", variant: .danger, fullWidth: true) {
                        let id = card.localId
                        dismiss()
                        pendingDeletes.enqueue([id], label: "Card deleted") { ids in
                            CardDeletion.commit(ids, in: context)
                        }
                    }
                }
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space8)
            }
        }
        .background(Caliper.bg)
        .sheet(isPresented: $showConnect) { CardLadderConnectView() }
        // Comps are fetched here and ONLY here — never on a scan or a bulk
        // refresh, which would spend the 200/day Card Ladder budget on cards
        // nobody opened. Server-side cache makes re-opening a card free.
        .task(id: card.localId) { await PriceService.loadSales(card, in: context) }
        // Defensive: this screen is pushed per card, but if it is ever reused the
        // knobs must not carry a previous negotiation's tuning into this card.
        .onChange(of: card.localId) { _, _ in maxBuyKnobs = MaxBuyDefaults.current }
        // A lead's change lands mid-screen: the baseline moves to it, and no card's
        // tuned knobs may sit below the team's (owner M2).
        .onChange(of: MaxBuyTeamPolicy.shared.knobs) { _, _ in
            maxBuyKnobs = MaxBuyDefaults.respectingTeam(maxBuyKnobs)
        }
    }

    /// The card, big enough to actually check against the slab in your hand.
    ///
    /// The caption is not decoration: the picture may be the user's own camera
    /// grab or an official render from PSA, Card Ladder or Courtyard, and a
    /// reseller needs to know which before they put it in a listing. `imageUrl`
    /// is loaded when present because the stored copy is capped at ~1024 px,
    /// with the cached bytes standing in while it loads.
    private var slabPanel: some View {
        HStack(alignment: .top, spacing: Caliper.space4) {
            VStack(alignment: .leading, spacing: Caliper.space3) {
                slabImage
                Text(card.imageSource.imageCaption)
                    .caliperMeta(Caliper.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ValueBlock(card: card, lens: app.lens, knobs: maxBuyKnobs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The picture, big enough to actually check against the slab in your hand.
    private var slabImage: some View {
        Group {
            ZStack {
                if let url = card.imageUrl.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        cachedImage ?? AnyView(SlabPlaceholder(card: card, scale: 2))
                    }
                } else if let cachedImage {
                    cachedImage
                } else {
                    SlabPlaceholder(card: card, scale: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.72, contentMode: .fit)
            .clipped()
            .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
        }
    }

    // MARK: Comps

    /// Real completed sales of this card at this grade. Evidence, not a derived
    /// figure — which is the whole point: the user prices the slab themselves.
    ///

    private var cachedImage: AnyView? {
        guard let data = card.thumbnailData, let image = UIImage(data: data) else { return nil }
        return AnyView(Image(uiImage: image).resizable().scaledToFit())
    }

    // MARK: Prices

    private var pricePanel: some View {
        VStack(spacing: 0) {
            ForEach(PriceSource.allCases) { source in
                HStack(alignment: .firstTextBaseline, spacing: Caliper.space5) {
                    Circle().fill(source.hue).frame(width: 6, height: 6)
                    Text(source.accessibilityName).font(.calBody).foregroundStyle(Caliper.textPrimary)
                    Spacer(minLength: Caliper.space4)
                    ConfidenceMeter(value: card.confidences[source], source: source)
                    Text(caliperMoney(cents: card.prices[source]))
                        .font(.price)
                        .foregroundStyle(card.prices[source] == nil ? Caliper.textTertiary : source.hue)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(Caliper.rowPad)

                if let note = note(for: source) {
                    HStack {
                        Text(note).caliperMeta(Caliper.textTertiary)
                        Spacer(minLength: 0)
                        if source == .cl && !cardLadderConnected {
                            Button("Connect") { showConnect = true }
                                .font(.mono(9, .medium))
                                .foregroundStyle(Caliper.cyan)
                        }
                    }
                    .padding(.horizontal, Caliper.rowPad)
                    .padding(.bottom, Caliper.rowPad)
                }
                if source != PriceSource.allCases.last { Hairline() }
            }
        }
        .caliperPanel()
    }

    /// One quiet line per source saying WHICH kind of missing this is.
    private func note(for source: PriceSource) -> String? {
        let (status, cents) = switch source {
        case .cl: (card.cardLadderStatus, card.cardLadderPriceCents)
        case .cy: (card.courtyardStatus, card.courtyardPriceCents)
        }
        switch status {
        case .ok, .unknown: return nil
        case .notListed: return "Not listed on \(source.accessibilityName) right now."
        case .notConnected: return "Connect your own Card Ladder account to see this price."
        case .unavailable:
            return cents == nil
                ? "\(source.accessibilityName) couldn't be reached. Try again."
                : "Couldn't be re-checked — this is the last price we saw."
        }
    }

    // MARK: Identity

    private var identityPanel: some View {
        VStack(spacing: 0) {
            field("Name", bind(\.name), placeholder: "Card name")
            Hairline()
            field("Set", bind(\.set), placeholder: "Set")
            Hairline()
            field("Grade", bind(\.grade), placeholder: card.grader.rawValue.uppercased())
            Hairline()
            HStack {
                Text("Year").caliperLabel()
                Spacer()
                TextField("Year", value: $card.year, format: .number)
                    .font(.price)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Caliper.textPrimary)
            }
            .padding(Caliper.rowPad)
            Hairline()
            HStack {
                Text("Manual price").caliperLabel()
                Spacer()
                TextField("—", value: dollars, format: .number.precision(.fractionLength(0)))
                    .font(.price)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Caliper.textPrimary)
            }
            .padding(Caliper.rowPad)
        }
        .caliperPanel()
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: Caliper.space5) {
            Text(label).caliperLabel()
            Spacer(minLength: Caliper.space4)
            TextField(placeholder, text: text)
                .font(.calBody)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Caliper.textPrimary)
                .onSubmit { card.refreshCardKey() }
        }
        .padding(Caliper.rowPad)
    }

    // MARK: Group

    /// The card's own group is always listed — whatever state its lot is in, the
    /// buyer must be able to take the card out of it.
    private var filableGroups: [Folder] {
        let open = app.lots.openLotIds
        return groups.filter { g in
            g.localId == card.folder?.localId
                || LotFolders.isFileable(g, openLots: open, lotsLoaded: app.lots.hasLoaded)
        }
    }

    private var groupPanel: some View {
        VStack(spacing: 0) {
            SectionLabelInline(text: "Group")
            // Open team lots are offered like any group — filing claims (CardFiling).
            ForEach(filableGroups) { group in
                SheetRow(
                    label: group.name,
                    active: card.folder?.localId == group.localId,
                    leading: { Circle().fill(group.hue).frame(width: 8, height: 8) }
                ) {
                    // Filing — not un-filing — is what makes this the group the
                    // Cards swipe offers next; CardFiling holds that rule.
                    CardFiling.toggle(card, group: group, in: context)
                }
            }
            if filableGroups.isEmpty {
                Text("No groups yet. Select cards on Inventory to make one.")
                    .caliperMeta()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Caliper.rowPad)
            }
        }
        .caliperPanel()
    }

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: Caliper.space4) {
            Text("Notes").caliperLabel()
            TextField("—", text: bind(\.notes), axis: .vertical)
                .font(.calBody)
                .foregroundStyle(Caliper.textPrimary)
                .lineLimit(2...5)
        }
        .padding(Caliper.rowPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .caliperPanel()
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<Card, String?>) -> Binding<String> {
        Binding(get: { card[keyPath: keyPath] ?? "" },
                set: { card[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    /// Manual price in whole dollars, backed by the integer-cents field.
    private var dollars: Binding<Double?> {
        Binding(
            get: { card.manualPriceCents.map { Double($0) / 100 } },
            set: { card.manualPriceCents = $0.map { Int(($0 * 100).rounded()) } }
        )
    }
}

/// A section label that sits inside a panel rather than above one.
struct SectionLabelInline: View {
    let text: String
    var body: some View {
        Text(text)
            .caliperLabel(Caliper.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Caliper.rowPad)
            .padding(.top, Caliper.rowPad)
            .padding(.bottom, Caliper.space3)
    }
}
