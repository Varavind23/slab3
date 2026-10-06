import SwiftUI
import SwiftData

// Team activity (teams-first plan, D17–D27): the lead's view of the team's work.
// Lots as boxes you swipe through → who contributed what → each person's full
// receipt, card by card → one card. Read-only by owner decision.
//
// Every dollar is a figure RECORDED AT CLAIM — CL value, CY value, or the buyer's
// max buy, picked on the MAX · CL · CY bar (owner M6, 2026-10-01) — never what
// anyone paid, which the app never learns. Labelled that way on every screen.
// The bar is a per-phone view (`TeamActivity.lensKey`); unset, it follows the lot's
// own basis.
//
// LEAD-ONLY IS UI GATING, NOT SECURITY: lot_claims' read policy lets every team
// member read every claim (buyers already see teammates' buys on Cards). These
// screens are simply not offered to buyers (TeamsContent.teamSection).

/// Swipeable lot boxes, then the way into who bought what.
struct TeamActivityScreen: View {
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.createdAt, order: .reverse) private var groups: [Folder]
    @State private var selected: UUID?
    @AppStorage(TeamActivity.lensKey) private var storedLens = ""

    var body: some View {
        let current = CurrentLot.resolve(scanTargetId: app.scanTargetUUID, groups: groups.map(GroupRef.init),
                                         lots: app.lots.lots)?.id
        // The lot decides the default view, so pick it before totalling anything.
        let order = TeamActivity.boxes(lots: app.lots.lots, claimsByLot: [:])
        let chosen = selected ?? TeamActivity.defaultLot(current: current, boxes: order)
        let lens = TeamActivity.lens(stored: storedLens, lot: app.lots.lots.first { $0.id == chosen })
        let boxes = TeamActivity.boxes(lots: app.lots.lots, claimsByLot: app.lots.claimsByLot, lens: lens)
        VStack(spacing: 0) {
            ScreenHeader(context: "Leads · " + lens.atClaim, title: "Team activity") {
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }
            ActivityLensBar(lens: lens) { storedLens = $0.rawValue }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if boxes.isEmpty {
                        Text("No lots have been opened yet. Buys show here once a lot opens.")
                            .font(.calBody)
                            .foregroundStyle(Caliper.textSecondary)
                            .padding(.horizontal, Caliper.gutter)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Caliper.space5) {
                                ForEach(boxes) { box in
                                    LotBoxView(box: box, lens: lens, isSelected: box.id == chosen) {
                                        withAnimation(Caliper.easeOut) { selected = box.id }
                                    }
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, Caliper.gutter)
                        }
                        .scrollTargetBehavior(.viewAligned)

                        if let chosen, let box = boxes.first(where: { $0.id == chosen }) {
                            SectionLabel(text: box.lot.name)
                            SheetRow(label: "Team members",
                                     sub: ["\(box.cards) \(box.cards == 1 ? "card" : "cards") · \(Money.dollars(box.cents)) \(lens.label)",
                                           TeamActivity.coverage(cards: box.cards, valued: box.valued, lens: lens)]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     trailing: "›") { app.teamsPath.append(.activityMembers(box.id)) }
                            Hairline()
                            Text("The lot's budgets count \(box.lot.valueBasis.valueAtClaim).")
                                .caliperMeta(Caliper.textTertiary)
                                .padding(.horizontal, Caliper.gutter)
                                .padding(.top, Caliper.space4)
                        }
                    }
                }
                .padding(.bottom, Caliper.space8)
            }
        }
    }
}

/// One lot, as a box: name, time left (or closed), cards, and the chosen figure.
struct LotBoxView: View {
    let box: TeamActivity.LotBox
    var lens: PriceLens = .cl
    let isSelected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: Caliper.space3) {
                Text(box.lot.name).font(.calBody.weight(.semibold)).foregroundStyle(Caliper.textPrimary).lineLimit(1)
                if box.lot.status == .closed {
                    Text("Closed").caliperLabel(Caliper.textTertiary)
                } else {
                    LotCountdown(deadline: box.lot.deadline)
                }
                Spacer(minLength: Caliper.space4)
                Text("\(box.cards) \(box.cards == 1 ? "card" : "cards")")
                    .font(.figureSmall)
                    .monospacedDigit()
                    .foregroundStyle(Caliper.textPrimary)
                Text("\(Money.compact(box.cents)) \(lens.label)").caliperMeta(Caliper.textSecondary)
            }
            .padding(Caliper.rowPad)
            .frame(width: 150, height: 138, alignment: .topLeading)
            .background(Caliper.surface)
            .overlay(Rectangle().strokeBorder(isSelected ? Caliper.textPrimary : Caliper.line,
                                              lineWidth: isSelected ? 1.5 : Caliper.borderWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .accessibilityLabel("\(box.lot.name), \(box.cards) cards, \(Money.dollars(box.cents)) \(lens.accessibilityName)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Who contributed to one lot: greyed card count and the chosen figure, most first.
struct ActivityMembersScreen: View {
    @Bindable var app: AppState
    let lotId: UUID
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TeamActivity.lensKey) private var storedLens = ""

    var body: some View {
        let lot = app.lots.lots.first { $0.id == lotId }
        let lens = TeamActivity.lens(stored: storedLens, lot: lot)
        let rows = TeamActivity.members(claims: app.lots.claimsByLot[lotId] ?? [], roster: app.team.members,
                                        people: app.team.people, lens: lens)
        VStack(spacing: 0) {
            ScreenHeader(context: (lot?.name ?? "Lot") + " · " + lens.atClaim, title: "Team members") {
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }
            ActivityLensBar(lens: lens) { storedLens = $0.rawValue }
            ScrollView {
                VStack(spacing: 0) {
                    Hairline()
                    ForEach(rows) { member in
                        Button { app.teamsPath.append(.receipt(lotId: lotId, userId: member.userId)) } label: {
                            HStack(spacing: Caliper.space5) {
                                Text(member.userId == app.team.myUserId ? "\(member.name) (you)" : member.name)
                                    .font(.calBody).foregroundStyle(Caliper.textPrimary).lineLimit(1)
                                if member.isVirtual { Text("Virtual").caliperLabel(Caliper.textTertiary) }
                                Spacer(minLength: Caliper.space4)
                                Text("\(member.cards) \(member.cards == 1 ? "card" : "cards")")
                                    .font(.price).monospacedDigit().foregroundStyle(Caliper.textTertiary)
                                Text(Money.dollars(member.cents))
                                    .font(.price).monospacedDigit().foregroundStyle(Caliper.textTertiary)
                                    .frame(minWidth: 84, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Caliper.textTertiary)
                            }
                            .padding(.horizontal, Caliper.gutter)
                            .frame(minHeight: Caliper.hitMin + 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CaliperPressStyle())
                        .accessibilityLabel("\(member.name), \(member.cards) cards, \(Money.dollars(member.cents)) \(lens.accessibilityName)")
                        Hairline()
                    }
                }
                .padding(.bottom, Caliper.space8)
            }
        }
    }
}

/// One buyer's full receipt for one lot: every card, three across, newest first.
///
/// A LEAD can tag slabs here (V2, 2026-10-04): Tag → pick slabs → pick who sourced
/// them. Tagged slabs move to that person's receipt, because they are now that
/// person's buys (V1); the scanner stays on each slab as "added by".
struct MemberReceiptScreen: View {
    @Bindable var app: AppState
    let lotId: UUID
    let userId: UUID
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [Card]
    @AppStorage(TeamActivity.lensKey) private var storedLens = ""
    @State private var tagging = false
    @State private var picked: Set<UUID> = []
    @State private var choosing = false
    @State private var error: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Caliper.space5, alignment: .top), count: 3)

    var body: some View {
        let lot = app.lots.lots.first { $0.id == lotId }
        let claims = TeamActivity.receipt(claims: app.lots.claimsByLot[lotId] ?? [], userId: userId,
                                          roster: app.team.members, people: app.team.people)
        let name = app.team.buyerChoices.first { $0.id == userId }?.name
            ?? claims.first.map { BuyerResolver.buyer(of: $0, members: app.team.members, people: app.team.people).name }
            ?? "Former member"
        let lens = TeamActivity.lens(stored: storedLens, lot: lot)
        let valued = claims.compactMap { $0.cents(in: lens) }
        let total = valued.reduce(Int64(0)) { $0 + Int64($1) }
        VStack(spacing: 0) {
            ScreenHeader(context: "\(name) · \(lot?.name ?? "Lot")",
                         title: tagging ? "\(picked.count) picked" : "\(claims.count) \(claims.count == 1 ? "card" : "cards")") {
                HStack(spacing: Caliper.space5) {
                    if app.team.isLead && !claims.isEmpty {
                        Button(tagging ? "Cancel" : "Tag") {
                            tagging.toggle(); picked = []; error = nil
                        }
                        .font(.mono(10, .medium))
                        .foregroundStyle(Caliper.textSecondary)
                        .accessibilityHint(tagging ? "" : "Credit slabs to the member who sourced them")
                    }
                    Button("Done") { dismiss() }
                        .font(.mono(10, .medium))
                        .foregroundStyle(Caliper.textSecondary)
                }
            }
            ActivityLensBar(lens: lens) { storedLens = $0.rawValue }
            ScrollView {
                VStack(alignment: .leading, spacing: Caliper.space6) {
                    Text(["\(Money.dollars(total)) " + lens.atClaim.lowercased(),
                          TeamActivity.coverage(cards: claims.count, valued: valued.count, lens: lens)]
                            .compactMap { $0 }.joined(separator: " · "))
                        .caliperLabel(Caliper.textSecondary)
                    if tagging {
                        Button(picked.count == claims.count ? "Pick none" : "Pick all") {
                            picked = picked.count == claims.count ? [] : Set(claims.map(\.id))
                        }
                        .font(.mono(10, .medium))
                        .foregroundStyle(Caliper.textSecondary)
                        .frame(minHeight: Caliper.hitMin)
                    }
                    LazyVGrid(columns: columns, spacing: Caliper.space6) {
                        ForEach(claims) { claim in
                            Button {
                                if tagging {
                                    if picked.contains(claim.id) { picked.remove(claim.id) } else { picked.insert(claim.id) }
                                } else {
                                    app.teamsPath.append(.claim(claim.id))
                                }
                            } label: {
                                ReceiptTile(claim: claim, lens: lens, local: localCard(for: claim),
                                            addedBy: addedBy(claim))
                                    .overlay(alignment: .topTrailing) {
                                        if tagging {
                                            Image(systemName: picked.contains(claim.id) ? "checkmark.square.fill" : "square")
                                                .font(.system(size: 16))
                                                .foregroundStyle(picked.contains(claim.id) ? Caliper.cyan : Caliper.textSecondary)
                                                .padding(Caliper.space3)
                                        }
                                    }
                            }
                            .buttonStyle(CaliperPressStyle())
                            .accessibilityAddTraits(tagging && picked.contains(claim.id) ? [.isSelected] : [])
                        }
                    }
                    if let error { Text(error).caliperMeta(Caliper.confMid) }
                    if claims.isEmpty {
                        Text("Nothing bought into this lot yet.").caliperMeta()
                    }
                }
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space8)
            }
            if tagging {
                VStack(spacing: 0) {
                    Hairline()
                    CaliperButton(title: "Tag \(picked.count) \(picked.count == 1 ? "card" : "cards") to…",
                                  variant: .primary, fullWidth: true,
                                  disabled: picked.isEmpty || app.lots.isWorking || app.team.isWorking) {
                        choosing = true
                    }
                    .padding(Caliper.gutter)
                }
            }
        }
        .confirmationDialog("Who sourced these?", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(app.team.buyerChoices.filter { $0.id != userId }) { buyer in
                Button(buyer.isVirtual ? "\(buyer.name) · virtual" : buyer.name) {
                    Task { await tag(claims.filter { picked.contains($0.id) }, to: buyer) }
                }
            }
            Button("Untag — back to who scanned them") {
                Task { await tag(claims.filter { picked.contains($0.id) }, to: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They become that person's buys in Team activity and the CSV.")
        }
    }

    /// The scanner, when the slab is credited to someone else.
    private func addedBy(_ claim: TeamClaim) -> String? {
        guard claim.creditedPersonId != nil, claim.buyerId != userId else { return nil }
        return app.team.members.first { $0.userId == claim.buyerId }?.displayName ?? "Former member"
    }

    private func tag(_ chosen: [TeamClaim], to buyer: Buyer?) async {
        guard let teamId = app.team.team?.id, !chosen.isEmpty else { return }
        error = nil
        var personId: UUID?
        if let buyer {
            let (id, failure) = await app.team.personId(for: buyer)
            if let failure { error = failure; return }
            personId = id
        }
        if let failure = await app.lots.setPerson(personId, claims: chosen, lotId: lotId, teamId: teamId) {
            error = failure
        } else {
            tagging = false; picked = []
        }
    }

    /// This phone's own copy of the slab, for its camera photo.
    private func localCard(for claim: TeamClaim) -> Card? {
        cards.first { $0.certNumber == claim.cert && $0.grader.rawValue == claim.grader }
    }
}

/// A card in a receipt: the picture, the name, the grade and the chosen figure.
struct ReceiptTile: View {
    let claim: TeamClaim
    var lens: PriceLens = .cl
    var local: Card? = nil
    /// Who scanned it, when it is credited to someone else (V1).
    var addedBy: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            ClaimImage(claim: claim, local: local)
                .aspectRatio(0.72, contentMode: .fit)
            Text(claim.title)
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(claim.grader.uppercased()) \(claim.gradeLabel ?? "\u{2014}") · \(claim.cents(in: lens).map { Money.dollars(Int64($0)) } ?? "\u{2014}") \(lens.label)")
                .caliperMeta(Caliper.textSecondary)
                .lineLimit(1)
            if let addedBy { Text("Added by \(addedBy)").caliperMeta(Caliper.textTertiary).lineLimit(1) }
            if claim.isOverLimit { Text("Over limit").caliperLabel(Caliper.confMid) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The slab's picture: this phone's own photo if it holds the card, else the
/// Card Ladder render the server saved with the claim.
struct ClaimImage: View {
    let claim: TeamClaim
    var local: Card? = nil

    var body: some View {
        Group {
            if let local {
                SlabThumbnail(card: local)
            } else {
                AsyncImage(url: claim.imageUrl.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Rectangle().fill(Caliper.surface2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(Caliper.line, lineWidth: Caliper.borderWidth))
    }
}

/// One purchase, read-only (D26): picture, identity, every figure recorded at claim,
/// bucket, time. All three figures at once — this is the full receipt.
struct ClaimDetailScreen: View {
    @Bindable var app: AppState
    let claimId: UUID
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [Card]

    var body: some View {
        let claim = app.lots.claimsByLot.values.flatMap { $0 }.first { $0.id == claimId }
        VStack(spacing: 0) {
            ScreenHeader(context: claim.map { "#\($0.cert)" } ?? "", title: claim?.title ?? "Card") {
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }
            if let claim {
                ScrollView {
                    VStack(alignment: .leading, spacing: Caliper.space6) {
                        ClaimImage(claim: claim, local: cards.first {
                            $0.certNumber == claim.cert && $0.grader.rawValue == claim.grader
                        })
                        // A slab's shape even with no picture — the placeholder has
                        // no size of its own and would collapse to a line.
                        .aspectRatio(0.72, contentMode: .fit)
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 0) {
                            ForEach(PriceLens.allCases) { lens in
                                fact(lens.atClaim, claim.cents(in: lens).map { Money.dollars(Int64($0)) } ?? "\u{2014}")
                            }
                            fact("Grade", "\(claim.grader.uppercased()) \(claim.gradeLabel ?? "\u{2014}")")
                            fact("Cert", claim.cert)
                            fact("Set", [claim.cardYear, claim.cardSet, claim.cardNumber.map { "#\($0)" }]
                                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "\u{2014}")
                            fact("Bucket", bucketName(claim) ?? "\u{2014}")
                            let buyer = BuyerResolver.buyer(of: claim, members: app.team.members, people: app.team.people)
                            fact("Bought by", buyer.isVirtual ? "\(buyer.name) · virtual" : buyer.name)
                            if buyer.id != claim.buyerId {
                                fact("Added by", app.team.members.first { $0.userId == claim.buyerId }?.displayName ?? "Former member")
                            }
                            fact("When", claim.scannedDate.map {
                                $0.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                            } ?? "\u{2014}")
                            if claim.isOverLimit { fact("Status", "Over the limit") }
                        }
                        .caliperPanel()
                    }
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.bottom, Caliper.space8)
                }
            } else {
                Text("This buy is no longer in the lot.")
                    .font(.calBody).foregroundStyle(Caliper.textSecondary).padding(Caliper.gutter)
                Spacer()
            }
        }
    }

    private func bucketName(_ claim: TeamClaim) -> String? {
        guard let rangeId = claim.rangeId else { return nil }
        return app.lots.rangesByLot[claim.lotId]?.first { $0.id == rangeId }?.valueLabel
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).caliperLabel(Caliper.textTertiary)
                Spacer(minLength: Caliper.space4)
                Text(value).font(.price).foregroundStyle(Caliper.textPrimary).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, Caliper.rowPad)
            .frame(minHeight: Caliper.hitMin)
            Hairline()
        }
    }
}

/// The MAX · CL · CY bar under Team activity's headers (owner M6): which figure
/// recorded at claim the screen totals. A view only — nothing on the server moves.
struct ActivityLensBar: View {
    let lens: PriceLens
    let select: (PriceLens) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Showing").caliperLabel(Caliper.textTertiary)
                Spacer()
                LensToggle(value: Binding(get: { lens }, set: select), lenses: PriceLens.allCases)
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.vertical, Caliper.space4)
            Hairline()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
