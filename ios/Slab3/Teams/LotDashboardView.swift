import SwiftUI

/// The lot dashboard (plan §8): laid out like the allocation screen the team
/// already works from every day, so a buyer reads it without being taught —
/// same order, same words, same shapes. Deadline card with a live countdown; the
/// warning banner; the grade line; then each price band — its span,
/// `$used / $allocated`, its rules, a bar, `N% used`, and `N buckets ⌄`, which
/// opens the band's bar chart. Shown on the lot's own screen (Teams → a lot).
///
/// Teams-first (2026-09-28): categories and the disabled Rates switch went with
/// the band rows (bands are a label on the bucket now), and the lot buyer's
/// reported numbers are hidden (owner, D23) — `LotDashboard.reported` and the
/// server table stay, so bringing them back is only this view.
///
/// Caliper, not the other screen's orange (owner decision): square, hairlines, no
/// elevation. Bars are neutral and turn amber from 90% — the figure is our own sum,
/// so it must never wear cyan (the one action colour) or a source hue (which would
/// claim CL asserted it). Warm amber is already Caliper's "look at this".
struct LotDashboardView: View {
    let lot: Lot
    let lots: LotStore
    /// For lead actions (entering reported figures, over-limit decisions). nil in
    /// render tests: the dashboard then reads exactly as a buyer sees it.
    var team: TeamStore? = nil

    @State private var showOverLimit = false
    @State private var expanded: Set<UUID>
    @State private var selectedBucket: [UUID: UUID]

    /// `expanded` / `selected` only for render tests, to draw the chart open.
    init(lot: Lot, lots: LotStore, team: TeamStore? = nil, expanded: Set<UUID> = [], selected: [UUID: UUID] = [:]) {
        self.lot = lot
        self.lots = lots
        self.team = team
        _expanded = State(initialValue: expanded)
        _selectedBucket = State(initialValue: selected)
    }

    private var bands: [LotDashboard.Band] {
        LotDashboard.build(ranges: lots.ranges(for: lot), usage: lots.usage)
    }

    var body: some View {
        VStack(spacing: Caliper.space6) {
            deadlineCard
            if let banner = lot.banner, !banner.isEmpty { bannerView(banner) }
            if lot.status != .active { statusNote }
            if team?.isLead == true, !overLimit.isEmpty { overLimitBanner }
            allocationPanel
        }
        .sheet(isPresented: $showOverLimit) {
            if let team { OverLimitSheet(lot: lot, lots: lots, team: team).presentationDetents([.large]) }
        }
    }

    private var overLimit: [TeamClaim] { lots.claims(for: lot).filter(\.isOverLimit) }

    /// Offline buys that landed after their card's three slots were full (teams.md
    /// §5.1). Recorded so nothing is lost; counted nowhere until a lead decides.
    private var overLimitBanner: some View {
        Button { showOverLimit = true } label: {
            HStack(spacing: Caliper.space5) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 13))
                Text(overLimit.count == 1 ? "1 over-limit buy needs a decision" : "\(overLimit.count) over-limit buys need a decision")
                    .font(.calBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .foregroundStyle(Caliper.confMid)
            .padding(Caliper.rowPad)
            .overlay(Rectangle().strokeBorder(Caliper.confMid.opacity(0.6), lineWidth: Caliper.borderWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
    }

    // MARK: Deadline

    private var deadlineCard: some View {
        HStack(alignment: .center, spacing: Caliper.space6) {
            Image(systemName: "hourglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Caliper.confMid)
                .frame(width: 44, height: 44)
                .background(Caliper.confMid.opacity(0.12))
            VStack(alignment: .leading, spacing: Caliper.space2) {
                Text(lot.deadline.map { $0.formatted(.dateTime.month(.wide).day().year()) } ?? "No deadline set")
                    .font(.calHeading)
                    .foregroundStyle(Caliper.textPrimary)
                HStack(alignment: .firstTextBaseline) {
                    Text("Time left to submit").caliperLabel(Caliper.textSecondary)
                    Spacer(minLength: Caliper.space4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdownText(now: context.date))
                            .font(.figureSmall)
                            .monospacedDigit()
                            .foregroundStyle(Caliper.textPrimary)
                    }
                }
            }
        }
        .padding(Caliper.rowPad)
        .background(Caliper.surface)
        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
    }

    private func countdownText(now: Date) -> String {
        guard let deadline = lot.deadline else { return "\u{2014}" }
        return LotDashboard.countdown(to: deadline, now: now) ?? "Passed"
    }

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Caliper.space5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(text.uppercased())
                .font(.mono(12, .semibold))
                .tracking(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Caliper.confMid)
        .padding(Caliper.rowPad)
        .background(Caliper.confMid.opacity(0.08))
        .overlay(Rectangle().strokeBorder(Caliper.confMid.opacity(0.6), lineWidth: Caliper.borderWidth))
    }

    private var unvalued: Int { LotRoom.unvalued(ranges: lots.ranges(for: lot), usage: lots.usage) }

    private var statusNote: some View {
        Text(lot.status == .draft ? "Draft · buyers can't see this lot yet" : "Closed · this lot takes no more cards")
            .caliperLabel(Caliper.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Allocation panel

    private var allocationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            let bands = bands
            if !bands.isEmpty {
                HStack(spacing: Caliper.space3) {
                    Image(systemName: "rectangle.portrait").font(.system(size: 10))
                    // Every lot dollar names its basis, so a CY figure is never
                    // read as CL (ValueBasis).
                    Text(LotDashboard.gradeLine(lots.ranges(for: lot)) + " · " + lot.valueBasis.valueAtClaim)
                        .caliperLabel(Caliper.textSecondary)
                }
                .foregroundStyle(Caliper.textSecondary)
                .padding(.bottom, unvalued > 0 ? Caliper.space3 : Caliper.space6)
                if unvalued > 0 {
                    // After a lead switches the basis: slabs the new source cannot
                    // value keep their slots and add no dollars. Say so, never $0.
                    Text("\(unvalued) \(unvalued == 1 ? "slab has" : "slabs have") no \(lot.valueBasis.short) value · counted as cards, not dollars")
                        .caliperMeta(Caliper.confMid)
                        .padding(.bottom, Caliper.space6)
                }

                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    if index > 0 { Hairline().padding(.vertical, Caliper.space6) }
                    bandView(band)
                }
            } else {
                Text("No buckets yet. A lead adds them in the lot's setup.")
                    .font(.calBody)
                    .foregroundStyle(Caliper.textSecondary)
                    .padding(.vertical, Caliper.space7)
            }
        }
        .padding(Caliper.rowPad + 4)
        .background(Caliper.surface)
        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
    }

    // MARK: A band

    private func bandView(_ band: LotDashboard.Band) -> some View {
        let isOpen = expanded.contains(band.id)
        return VStack(alignment: .leading, spacing: Caliper.space4) {
            HStack(alignment: .firstTextBaseline, spacing: Caliper.space5) {
                Text(band.valueLabel)
                    .font(.calTitle)
                    .foregroundStyle(Caliper.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Caliper.space4)
                Text(LotDashboard.usedOfAllocated(band.usedCents, band.allocatedCents))
                    .font(.figureSmall)
                    .monospacedDigit()
                    .foregroundStyle(Caliper.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            if !band.rules.isEmpty {
                Text(band.rules).caliperLabel(Caliper.textSecondary)
            }
            UsageBar(fraction: band.fraction)
                .padding(.top, Caliper.space3)
            HStack {
                Text("\(band.percentUsed)% used").font(.calBody).foregroundStyle(Caliper.textSecondary)
                Spacer()
                Button {
                    withAnimation(Caliper.easeOut) {
                        if isOpen { expanded.remove(band.id) } else { expanded.insert(band.id) }
                    }
                } label: {
                    HStack(spacing: Caliper.space3) {
                        Text(band.bucketCountLabel).font(.calBody.weight(.semibold))
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Caliper.textPrimary)
                    .frame(minHeight: Caliper.hitMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CaliperPressStyle())
                .accessibilityLabel("\(band.bucketCountLabel), \(isOpen ? "hide" : "show") chart")
            }
            if isOpen { chart(band) }
        }
    }

    // MARK: The bar chart

    private func chart(_ band: LotDashboard.Band) -> some View {
        let tallest = max(1, band.buckets.map(\.allocatedCents).max() ?? 1)
        let selected = selectedBucket[band.id].flatMap { id in band.buckets.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: Caliper.space5) {
            HStack(spacing: Caliper.space5) {
                legend("Allocated", Caliper.lineStrong)
                legend("Used", Caliper.textSecondary)
                Spacer()
                Text(band.bucketCountLabel).font(.calBody).foregroundStyle(Caliper.textSecondary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(band.buckets) { bucket in
                    let isSelected = selected?.id == bucket.id
                    GeometryReader { geo in
                        let full = geo.size.height
                        let allocated = full * CGFloat(Double(bucket.allocatedCents) / Double(tallest))
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(Caliper.lineStrong).frame(height: allocated)
                            Rectangle()
                                .fill(bucket.fraction >= 0.9 ? Caliper.confMid : Caliper.textSecondary)
                                .frame(height: allocated * CGFloat(bucket.fraction))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Rectangle().strokeBorder(Caliper.textPrimary, lineWidth: 1).frame(height: max(allocated, 2))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedBucket[band.id] = isSelected ? nil : bucket.id
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(bucket.valueLabel), \(LotDashboard.usedOfAllocated(bucket.usedCents, bucket.allocatedCents))")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .frame(height: 120)
            HStack {
                Text(Money.dollars(band.valueMinCents)).caliperMeta(Caliper.textSecondary)
                Spacer()
                Text(band.valueMaxCents.map(Money.dollars) ?? "No max").caliperMeta(Caliper.textSecondary)
            }
            if let selected {
                VStack(alignment: .leading, spacing: Caliper.space2) {
                    Text([selected.valueLabel, selected.ruleText].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.calBody.weight(.semibold))
                        .foregroundStyle(Caliper.textPrimary)
                    Text("\(LotDashboard.usedOfAllocated(selected.usedCents, selected.allocatedCents)) · \(selected.cards) of \(selected.range.maxCards) cards")
                        .font(.price)
                        .foregroundStyle(Caliper.textSecondary)
                    if selected.range.name != selected.valueLabel {
                        Text(selected.range.name).caliperMeta(Caliper.textTertiary)
                    }
                    if let notes = selected.range.notes {
                        Text(notes).font(.calBody).foregroundStyle(Caliper.textSecondary)
                    }
                }
            } else {
                Text("Tap a bar for that bucket").caliperMeta(Caliper.textTertiary)
            }
        }
        .padding(Caliper.rowPad)
        .overlay(Rectangle().strokeBorder(Caliper.line, lineWidth: Caliper.borderWidth))
        .padding(.top, Caliper.space3)
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: Caliper.space3) {
            Rectangle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.calBody).foregroundStyle(Caliper.textSecondary)
        }
    }
}

/// A band's progress: neutral fill on the inset, amber from 90%.
struct UsageBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Caliper.surface2)
                Rectangle()
                    .fill(fraction >= 0.9 ? Caliper.confMid : Caliper.textSecondary)
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// Offline buys that landed after their card's three slots (or their bucket) were
/// full (teams.md §5.1): recorded so nothing is lost, counted toward no cap until a
/// lead decides. Leads only.
struct OverLimitSheet: View {
    let lot: Lot
    let lots: LotStore
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var rows: [TeamClaim] { lots.claims(for: lot).filter(\.isOverLimit) }

    var body: some View {
        CaliperSheet(title: "Over the limit · \(rows.count)") {
            Button("Done") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Text("Bought offline after three of the same card at the same grade were already in the lot. They count toward nothing until you decide.")
                    .caliperMeta()
                    .padding(Caliper.gutter)
                ForEach(rows) { claim in
                    TeammateClaimRow(claim: claim, buyer: name(claim.buyerId), isMine: claim.buyerId == team.myUserId)
                        .padding(.horizontal, Caliper.gutter)
                    Button("Drop from lot") {
                        Task {
                            guard let teamId = team.team?.id else { return }
                            error = await lots.release(claim, teamId: teamId)
                        }
                    }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.danger)
                    .frame(minHeight: Caliper.hitMin)
                    .padding(.horizontal, Caliper.gutter)
                    Hairline()
                }
                if let error {
                    Text(error).caliperMeta(Caliper.confMid).padding(Caliper.gutter)
                }
            }
        } confirm: { EmptyView() }
    }

    private func name(_ id: UUID) -> String {
        team.members.first { $0.userId == id }?.displayName ?? "A teammate"
    }
}

/// A teammate's slab in the lot — the Cards row's shape, read-only (plan §7.5).
/// The thumbnail is Card Ladder's render (there is no camera photo from another
/// phone); line three names the buyer and when, where an own card shows its cert.
struct TeammateClaimRow: View {
    let claim: TeamClaim
    let buyer: String
    var isMine = false

    var body: some View {
        HStack(alignment: .top, spacing: Caliper.space5) {
            AsyncImage(url: claim.imageUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Caliper.surface2)
            }
            .frame(width: 46, height: 64)
            .clipped()
            .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))

            VStack(alignment: .leading, spacing: Caliper.space3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(claim.title).font(.calBody).foregroundStyle(Caliper.textPrimary).lineLimit(1)
                    Spacer(minLength: Caliper.space4)
                    // Both sources on every row (Caliper), each as the server
                    // recorded it at claim. Claims from before 0.9 never recorded
                    // Courtyard, and that stays an honest em dash.
                    Text(claim.priceCents.map { Money.dollars(Int64($0)) } ?? "\u{2014}")
                        .font(.price).foregroundStyle(Caliper.srcCL)
                    Text("CL").font(.mono(8, .medium)).foregroundStyle(Caliper.srcCL.opacity(0.75))
                    Text(claim.cyPriceCents.map { Money.dollars(Int64($0)) } ?? "\u{2014}")
                        .font(.price).foregroundStyle(Caliper.srcCY)
                    Text("CY").font(.mono(8, .medium)).foregroundStyle(Caliper.srcCY.opacity(0.75))
                }
                Text([claim.cardYear, claim.cardSet, claim.cardNumber.map { "#\($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .caliperMeta().lineLimit(1)
                HStack(spacing: Caliper.space4) {
                    Text((isMine ? "You" : buyer) + (claim.scannedDate.map { " · " + $0.formatted(.dateTime.hour().minute()) } ?? ""))
                        .caliperLabel(Caliper.textSecondary)
                    if claim.isOverLimit { Text("Over limit").caliperLabel(Caliper.confMid) }
                    Spacer(minLength: Caliper.space3)
                    GradeBadge(grader: Grader(rawValue: claim.grader) ?? .psa, grade: claim.gradeLabel)
                }
            }
        }
        .padding(Caliper.rowPad)
        .background(Caliper.surface)
        .overlay(Rectangle().strokeBorder(Caliper.line, lineWidth: Caliper.borderWidth))
    }
}
