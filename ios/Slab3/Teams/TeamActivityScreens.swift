import SwiftUI
import SwiftData

// Team activity (teams-first plan, D17–D27): the lead's view of the team's work.
// Lots as boxes you swipe through → who contributed what → each person's full
// receipt, card by card → one card. Read-only by owner decision.
//
// Every dollar is CL VALUE AT CLAIM — what the lot's budgets count — never what
// anyone paid, which the app never learns. Labelled that way on every screen.
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

    private var boxes: [TeamActivity.LotBox] {
        TeamActivity.boxes(lots: app.lots.lots, claimsByLot: app.lots.claimsByLot)
    }

    var body: some View {
        let boxes = boxes
        let current = CurrentLot.resolve(scanTargetId: app.scanTargetUUID, groups: groups.map(GroupRef.init),
                                         lots: app.lots.lots)?.id
        let chosen = selected ?? TeamActivity.defaultLot(current: current, boxes: boxes)
        VStack(spacing: 0) {
            ScreenHeader(context: "Leads · CL value at claim", title: "Team activity") {
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }
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
                                    LotBoxView(box: box, isSelected: box.id == chosen) {
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
                                     sub: "\(box.cards) \(box.cards == 1 ? "card" : "cards") · \(Money.dollars(box.cents)) CL",
                                     trailing: "›") { app.teamsPath.append(.activityMembers(box.id)) }
                            Hairline()
                        }
                    }
                }
                .padding(.bottom, Caliper.space8)
            }
        }
    }
}

/// One lot, as a box: name, time left (or closed), cards, CL value.
struct LotBoxView: View {
    let box: TeamActivity.LotBox
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
                Text("\(Money.compact(box.cents)) CL").caliperMeta(Caliper.textSecondary)
            }
            .padding(Caliper.rowPad)
            .frame(width: 150, height: 138, alignment: .topLeading)
            .background(Caliper.surface)
            .overlay(Rectangle().strokeBorder(isSelected ? Caliper.textPrimary : Caliper.line,
                                              lineWidth: isSelected ? 1.5 : Caliper.borderWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .accessibilityLabel("\(box.lot.name), \(box.cards) cards, \(Money.dollars(box.cents)) CL value")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Who contributed to one lot: greyed card count and CL value, most value first.
struct ActivityMembersScreen: View {
    @Bindable var app: AppState
    let lotId: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lot = app.lots.lots.first { $0.id == lotId }
        let rows = TeamActivity.members(claims: app.lots.claimsByLot[lotId] ?? [], roster: app.team.members)
        VStack(spacing: 0) {
            ScreenHeader(context: (lot?.name ?? "Lot") + " · CL value at claim", title: "Team members") {
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    Hairline()
                    ForEach(rows) { member in
                        Button { app.teamsPath.append(.receipt(lotId: lotId, userId: member.userId)) } label: {
                            HStack(spacing: Caliper.space5) {
                                Text(member.userId == app.team.myUserId ? "\(member.name) (you)" : member.name)
                                    .font(.calBody).foregroundStyle(Caliper.textPrimary).lineLimit(1)
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
                        .accessibilityLabel("\(member.name), \(member.cards) cards, \(Money.dollars(member.cents)) CL value")
                        Hairline()
                    }
                }
                .padding(.bottom, Caliper.space8)
            }
        }
    }
}

/// One person's full receipt for one lot: every card, three across, newest first.
struct MemberReceiptScreen: View {
    @Bindable var app: AppState
    let lotId: UUID
    let userId: UUID
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [Card]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Caliper.space5, alignment: .top), count: 3)

    var body: some View {
        let lot = app.lots.lots.first { $0.id == lotId }
        let claims = TeamActivity.receipt(claims: app.lots.claimsByLot[lotId] ?? [], userId: userId)
        let name = app.team.members.first { $0.userId == userId }?.displayName ?? "Former member"
        let total = claims.reduce(Int64(0)) { $0 + Int64($1.priceCents ?? 0) }
        VStack(spacing: 0) {
            ScreenHeader(context: "\(name) · \(lot?.name ?? "Lot")",
                         title: "\(claims.count) \(claims.count == 1 ? "card" : "cards")") {
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Caliper.space6) {
                    Text("\(Money.dollars(total)) CL value at claim").caliperLabel(Caliper.textSecondary)
                    LazyVGrid(columns: columns, spacing: Caliper.space6) {
                        ForEach(claims) { claim in
                            Button { app.teamsPath.append(.claim(claim.id)) } label: {
                                ReceiptTile(claim: claim, local: localCard(for: claim))
                            }
                            .buttonStyle(CaliperPressStyle())
                        }
                    }
                    if claims.isEmpty {
                        Text("Nothing bought into this lot yet.").caliperMeta()
                    }
                }
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space8)
            }
        }
    }

    /// This phone's own copy of the slab, for its camera photo.
    private func localCard(for claim: TeamClaim) -> Card? {
        cards.first { $0.certNumber == claim.cert && $0.grader.rawValue == claim.grader }
    }
}

/// A card in a receipt: the picture, the name, the grade and CL value beneath.
struct ReceiptTile: View {
    let claim: TeamClaim
    var local: Card? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            ClaimImage(claim: claim, local: local)
                .aspectRatio(0.72, contentMode: .fit)
            Text(claim.title)
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(claim.grader.uppercased()) \(claim.gradeLabel ?? "\u{2014}") · \(claim.priceCents.map { Money.dollars(Int64($0)) } ?? "\u{2014}")")
                .caliperMeta(Caliper.textSecondary)
                .lineLimit(1)
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

/// One purchase, read-only (D26): picture, identity, CL value at claim, bucket, time.
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
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 0) {
                            fact("CL value at claim", claim.priceCents.map { Money.dollars(Int64($0)) } ?? "\u{2014}")
                            fact("Grade", "\(claim.grader.uppercased()) \(claim.gradeLabel ?? "\u{2014}")")
                            fact("Cert", claim.cert)
                            fact("Set", [claim.cardYear, claim.cardSet, claim.cardNumber.map { "#\($0)" }]
                                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "\u{2014}")
                            fact("Bucket", bucketName(claim) ?? "\u{2014}")
                            fact("Bought by", app.team.members.first { $0.userId == claim.buyerId }?.displayName ?? "Former member")
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
