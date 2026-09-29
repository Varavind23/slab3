import SwiftUI
import SwiftData

/// The Teams tab (teams-first plan, 2026-09-28) — where team members land, and the
/// one place lots are chosen.
///
/// WHY A TAB. Teams used to hang off Settings: a lot took ~10 taps through sheets
/// four deep, its progress hid behind the Cards filter, and a buyer reached it only
/// through the Scan bar. The owner wanted it to BE the workflow. So this screen
/// answers, top to bottom, the questions a buyer has at a show table:
///   1. what can I still buy? — the current lot's room per bucket (D15), with a
///      cyan "Scan into" as the one primary action;
///   2. what else is open? — other open lots (tap to make one current);
///   3. (leads) what am I setting up? — drafts and "+ New lot";
///   4. the team itself — members, activity (leads), buy ranges, code, name.
///
/// Present only while the user is on a team (AppState.visibleTabs); everyone else
/// has the four-tab app exactly as shipped.
struct TeamsScreen: View {
    @Bindable var app: AppState
    @Environment(\.modelContext) private var context
    @Query(sort: \Folder.createdAt, order: .reverse) private var groups: [Folder]
    @AppStorage("caliper_seen_teams_intro") private var seenIntro = false
    @State private var bucket: BucketTarget?
    @State private var confirmRotate = false
    @State private var showName = false
    @State private var error: String?

    struct BucketTarget: Identifiable {
        let range: BuyRange
        let lot: Lot
        var id: UUID { range.id }
    }

    private var current: Lot? {
        CurrentLot.resolve(scanTargetId: app.scanTargetUUID, groups: groups.map(GroupRef.init), lots: app.lots.lots)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(context: headerContext, title: "Teams")
            ScrollViewReader { proxy in
                ScrollView {
                    TeamsContent(team: app.team, lots: app.lots, current: current,
                                 showIntro: !seenIntro, send: handle)
                        .id("top")
                        .padding(.bottom, Caliper.space8)
                }
                .onChange(of: app.tabReselected) { _, _ in
                    withAnimation(Caliper.easeOut) { proxy.scrollTo("top", anchor: .top) }
                }
            }
        }
        .background(Caliper.bg)
        .sheet(item: $bucket) { target in
            BucketSheet(range: target.range, lot: target.lot, lots: app.lots, team: app.team)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showName) {
            TeamDisplayNameSheet(team: app.team).presentationDetents([.height(260)])
        }
        .confirmationDialog("Rotate the team code?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate code") { Task { error = await app.team.rotateCode() } }
        } message: {
            Text("The old code stops working. Everyone already on the team stays on it.")
        }
        .alert("Team", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var headerContext: String {
        guard let team = app.team.team else { return "Loading team…" }
        let n = app.team.members.count
        return "\(team.name) · \(n) \(n == 1 ? "member" : "members")"
    }

    private func handle(_ action: TeamsAction) {
        switch action {
        case .scanInto(let lot): app.scanInto(lot, in: context)
        case .makeCurrent(let lot): withAnimation(Caliper.easeOut) { app.makeCurrent(lot, in: context) }
        case .push(let route): app.teamsPath.append(route)
        case .bucket(let range, let lot): bucket = BucketTarget(range: range, lot: lot)
        case .rotateCode: confirmRotate = true
        case .editName: showName = true
        case .dismissIntro: withAnimation(Caliper.easeOut) { seenIntro = true }
        }
    }
}

/// What the Teams screen asks of its host — kept as values so the content renders
/// in tests without a navigation stack or a model container.
enum TeamsAction {
    case scanInto(Lot)
    case makeCurrent(Lot)
    case push(TeamsRoute)
    case bucket(BuyRange, Lot)
    case rotateCode
    case editName
    case dismissIntro
}

/// The Teams tab's body, without the scroll view — render-testable.
struct TeamsContent: View {
    let team: TeamStore
    let lots: LotStore
    /// The lot the Scan tab is filing into, if it is an open one.
    let current: Lot?
    var showIntro = false
    let send: (TeamsAction) -> Void

    @State private var showClosed = false

    private var visible: [Lot] { lots.visibleLots(isLead: team.isLead) }
    private var open: [Lot] {
        visible.filter { $0.status == .active }.sorted { a, b in
            switch (a.deadline, b.deadline) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.createdAt > b.createdAt
            }
        }
    }
    /// The card on top: the lot being scanned into, else the most urgent open one.
    private var featured: Lot? { current ?? open.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showIntro {
                TeamIntroCard(teamName: team.team?.name, dismiss: { send(.dismissIntro) })
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.bottom, Caliper.space6)
            }

            if let featured {
                CurrentLotCard(lot: featured, lots: lots, isCurrent: featured.id == current?.id, send: send)
                    .padding(.horizontal, Caliper.gutter)
            } else {
                emptyLots.padding(.horizontal, Caliper.gutter)
            }

            let others = open.filter { $0.id != featured?.id }
            if !others.isEmpty {
                SectionLabel(text: "Open lots")
                ForEach(others) { lot in
                    LotRow(lot: lot, room: LotRoom.lot(ranges: lots.ranges(for: lot), usage: lots.usage),
                           tap: { send(.makeCurrent(lot)) }, open: { send(.push(.lot(lot.id))) })
                    Hairline()
                }
            }

            // With no open lot the empty card's cyan "New lot" is the way in; a second
            // one here would be the same action twice.
            if team.isLead, featured != nil || visible.contains(where: { $0.status == .draft }) {
                HStack {
                    SectionLabel(text: "Drafts")
                    if featured != nil {
                        newLotLink
                    }
                }
                draftRows
            }

            let closed = visible.filter { $0.status == .closed }.sorted { $0.createdAt > $1.createdAt }
            if !closed.isEmpty {
                Button { withAnimation(Caliper.easeOut) { showClosed.toggle() } } label: {
                    HStack {
                        Text("Closed · \(closed.count)").caliperLabel(Caliper.textTertiary)
                        Spacer()
                        Image(systemName: showClosed ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(Caliper.textTertiary)
                    }
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.top, Caliper.space7)
                    .frame(minHeight: Caliper.hitMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CaliperPressStyle())
                if showClosed {
                    ForEach(closed) { lot in
                        SheetRow(label: lot.name, sub: LotText.summary(lot, rangeCount: lots.ranges(for: lot).count),
                                 trailing: "›") { send(.push(.lot(lot.id))) }
                        Hairline()
                    }
                }
            }

            teamSection
        }
    }

    private var newLotLink: some View {
        Button { send(.push(.builder(nil))) } label: {
            Label("New lot", systemImage: "plus")
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
                .frame(minHeight: Caliper.hitMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .padding(.trailing, Caliper.gutter)
        .padding(.top, Caliper.space5)
    }

    @ViewBuilder
    private var draftRows: some View {
        let drafts = visible.filter { $0.status == .draft }
        ForEach(drafts) { lot in
            SheetRow(label: lot.name, sub: LotText.summary(lot, rangeCount: lots.ranges(for: lot).count),
                     trailing: "›") { send(.push(.builder(lot.id))) }
            Hairline()
        }
        if drafts.isEmpty {
            Text("None. A new lot stays a draft, visible only to leads, until you open it.")
                .caliperMeta()
                .padding(.horizontal, Caliper.gutter)
        }
    }

    // MARK: No open lot

    private var emptyLots: some View {
        VStack(alignment: .leading, spacing: Caliper.space5) {
            Text(team.isLead ? "No open lots" : "Nothing to buy into yet")
                .font(.calHeading)
                .foregroundStyle(Caliper.textPrimary)
            Text(team.isLead
                 ? "Build a lot from your saved buy ranges, then open it. Your buyers see it here the moment it opens."
                 : "When your lead opens a lot, it shows here with what's left to buy.")
                .font(.calBody)
                .foregroundStyle(Caliper.textSecondary)
            if team.isLead {
                // The screen's one primary action when there is nothing to scan into.
                CaliperButton(title: "New lot", variant: .primary, icon: "plus", fullWidth: true) {
                    send(.push(.builder(nil)))
                }
            }
        }
        .padding(Caliper.rowPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .caliperPanel()
    }

    // MARK: The team

    @ViewBuilder
    private var teamSection: some View {
        SectionLabel(text: "Team")
        row("Members", value: "\(team.members.count)") { send(.push(.members)) }
        Hairline()
        if team.isLead {
            row("Team activity", value: "") { send(.push(.activity)) }
            Hairline()
        }
        row("Buy ranges", value: "\(lots.library.count) saved") { send(.push(.library)) }
        Hairline()
        row("Team code", value: team.team.map { JoinCode.display($0.joinCode) } ?? "\u{2014}",
            tap: team.isLead ? { send(.rotateCode) } : nil)
        Hairline()
        row("Your name", value: team.me?.displayName ?? "\u{2014}", verbatim: true) { send(.editName) }
    }

    private func row(_ label: String, value: String, verbatim: Bool = false,
                     tap: (() -> Void)? = nil) -> some View {
        Button { tap?() } label: {
            HStack(spacing: Caliper.space5) {
                Text(label).font(.calBody).foregroundStyle(Caliper.textPrimary)
                Spacer(minLength: Caliper.space4)
                if verbatim {
                    Text(value).font(.calBody).foregroundStyle(Caliper.textSecondary).lineLimit(1)
                } else {
                    Text(value).caliperLabel(tap == nil ? Caliper.textTertiary : Caliper.textSecondary)
                }
                if tap != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Caliper.textTertiary)
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .frame(height: Caliper.hitMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .disabled(tap == nil)
    }
}

// MARK: - The current lot

/// The lot on top of Teams: WHAT I CAN STILL BUY leads (D15) — room left for the
/// whole lot, then per bucket, each over its bar. Tapping a bucket shows what is in
/// it; the title opens the lot's full screen. The cyan "Scan into" is the screen's
/// one primary action.
struct CurrentLotCard: View {
    let lot: Lot
    let lots: LotStore
    /// It IS the Scan tab's target (vs. shown because nothing is picked yet).
    let isCurrent: Bool
    let send: (TeamsAction) -> Void

    private var ranges: [BuyRange] { lots.ranges(for: lot) }
    private var bands: [LotDashboard.Band] {
        LotDashboard.build(ranges: ranges, usage: lots.usage)
    }

    var body: some View {
        let room = LotRoom.lot(ranges: ranges, usage: lots.usage)
        VStack(alignment: .leading, spacing: 0) {
            header.padding(Caliper.rowPad)
            if let banner = lot.banner, !banner.isEmpty {
                HStack(spacing: Caliper.space4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(banner.uppercased()).font(.mono(10, .semibold)).tracking(0.5).lineLimit(2)
                }
                .foregroundStyle(Caliper.confMid)
                .padding(.horizontal, Caliper.rowPad)
                .padding(.bottom, Caliper.space5)
            }
            Hairline()

            VStack(alignment: .leading, spacing: Caliper.space3) {
                Text("What you can still buy").caliperLabel(Caliper.textTertiary)
                Text(ranges.isEmpty ? "\u{2014}" : room.leftLine)
                    .font(.figureSmall)
                    .monospacedDigit()
                    .foregroundStyle(room.isFull ? Caliper.confMid : Caliper.textPrimary)
                if !ranges.isEmpty {
                    Text("\(room.percentUsed)% used · CL value at claim").caliperMeta(Caliper.textTertiary)
                }
            }
            .padding(Caliper.rowPad)

            ForEach(bands) { band in
                Hairline()
                if band.buckets.count > 1 {
                    bandHeader(band)
                }
                ForEach(band.buckets) { bucket in
                    bucketRow(bucket.range)
                }
            }
            if ranges.isEmpty {
                Hairline()
                Text("No buckets in this lot yet.").caliperMeta().padding(Caliper.rowPad)
            }

            Hairline()
            CaliperButton(title: "Scan into \(lot.name)", variant: .primary, icon: "barcode.viewfinder",
                          fullWidth: true) { send(.scanInto(lot)) }
                .padding(Caliper.rowPad)
        }
        .background(Caliper.surface)
        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
    }

    private var header: some View {
        Button { send(.push(.lot(lot.id))) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Caliper.space4) {
                VStack(alignment: .leading, spacing: Caliper.space2) {
                    Text(isCurrent ? "Scanning into" : "Open lot").caliperLabel(Caliper.textTertiary)
                    HStack(spacing: Caliper.space3) {
                        Text(lot.name).font(.calHeading).foregroundStyle(Caliper.textPrimary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Caliper.textTertiary)
                    }
                }
                Spacer(minLength: Caliper.space4)
                LotCountdown(deadline: lot.deadline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .accessibilityHint("Opens the lot")
    }

    private func bandHeader(_ band: LotDashboard.Band) -> some View {
        let room = LotRoom.sum(band.buckets.map { LotRoom.bucket($0.range, usage: lots.usage[$0.id]) })
        return HStack {
            Text(band.valueLabel).caliperLabel(Caliper.textSecondary)
            Spacer()
            Text(room.leftLine).caliperLabel(room.isNear ? Caliper.confMid : Caliper.textTertiary)
        }
        .padding(.horizontal, Caliper.rowPad)
        .padding(.top, Caliper.space5)
    }

    private func bucketRow(_ range: BuyRange) -> some View {
        let room = LotRoom.bucket(range, usage: lots.usage[range.id])
        return Button { send(.bucket(range, lot)) } label: {
            VStack(alignment: .leading, spacing: Caliper.space3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(range.valueLabel).font(.calBody).foregroundStyle(Caliper.textPrimary)
                    Spacer(minLength: Caliper.space4)
                    Text(room.leftLine)
                        .font(.price)
                        .monospacedDigit()
                        .foregroundStyle(room.isNear ? Caliper.confMid : Caliper.textPrimary)
                }
                UsageBar(fraction: room.fraction).frame(height: 4)
                Text("\(room.cardsUsed)/\(room.maxCards) cards · \(Money.compact(room.centsUsed))/\(Money.compact(room.budgetCents))")
                    .caliperMeta(Caliper.textTertiary)
            }
            .padding(.horizontal, Caliper.rowPad)
            .padding(.vertical, Caliper.space5)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .accessibilityLabel("\(range.valueLabel), \(room.leftLine)")
    }
}

/// "4D 23:17 LEFT", ticking by the minute; "Past deadline" once it has gone.
struct LotCountdown: View {
    let deadline: Date?
    var body: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(LotDashboard.countdown(to: deadline, now: context.date).map { String($0.dropLast(3)) + " left" }
                     ?? "Past deadline")
                    .caliperLabel(Caliper.textSecondary)
                    .monospacedDigit()
            }
        } else {
            Text("No deadline").caliperLabel(Caliper.textTertiary)
        }
    }
}

/// On Cards, filtered to a lot's group: how full the lot is, one tap from its
/// full screen on Teams (D9 — the dashboard lives there, Cards is cards).
struct LotLinkLine: View {
    let lot: Lot
    let room: LotRoom.Room
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Caliper.space4) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(LotText.shortLine(percent: room.percentUsed, deadline: lot.deadline, now: context.date))
                        .caliperLabel(room.isNear ? Caliper.confMid : Caliper.textSecondary)
                }
                Spacer(minLength: Caliper.space4)
                Text("Open lot").caliperLabel(Caliper.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Caliper.textTertiary)
            }
            .frame(minHeight: Caliper.hitMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .accessibilityHint("Opens the lot on the Teams tab")
    }
}

/// Another open lot: tap to make it the one being scanned into; the chevron opens it.
struct LotRow: View {
    let lot: Lot
    let room: LotRoom.Room
    let tap: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: tap) {
                HStack(spacing: Caliper.space5) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lot.name).font(.calBody).foregroundStyle(Caliper.textPrimary).lineLimit(1)
                        Text(room.leftLine).caliperMeta(room.isNear ? Caliper.confMid : Caliper.textTertiary)
                    }
                    Spacer(minLength: Caliper.space4)
                    LotCountdown(deadline: lot.deadline)
                }
                .padding(.leading, Caliper.gutter)
                .frame(minHeight: Caliper.hitMin + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityHint("Makes this the lot you're scanning into")

            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Caliper.textTertiary)
                    .frame(width: Caliper.hitMin, height: Caliper.hitMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityLabel("Open \(lot.name)")
            .padding(.trailing, Caliper.space4)
        }
    }
}

/// Shown once, the first time the Teams tab appears (D16). No cyan: it explains,
/// it does not compete with "Scan into".
struct TeamIntroCard: View {
    let teamName: String?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Caliper.space5) {
            VStack(alignment: .leading, spacing: Caliper.space3) {
                Text(teamName.map { "You're on \($0)" } ?? "You're on a team")
                    .font(.calHeading)
                    .foregroundStyle(Caliper.textPrimary)
                Text("Pick a lot and tap Scan into it. Every slab you scan is checked against the lot's limits, and the team sees it land.")
                    .font(.calBody)
                    .foregroundStyle(Caliper.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Caliper.textSecondary)
                    .frame(width: Caliper.hitMin, height: Caliper.hitMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Caliper.rowPad)
        .padding(.vertical, Caliper.space3)
        .overlay(Rectangle().strokeBorder(Caliper.line, lineWidth: Caliper.borderWidth))
    }
}

// MARK: - A bucket

/// What is in one bucket (D14): its caps and rules, then every slab the team put
/// in it, newest first — whose, and when. A read-out, so no primary action.
struct BucketSheet: View {
    let range: BuyRange
    let lot: Lot
    let lots: LotStore
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss

    private var claims: [TeamClaim] {
        TeamActivity.counted(lots.claims(for: lot)).filter { $0.rangeId == range.id }
            .sorted { ($0.scannedDate ?? .distantPast) > ($1.scannedDate ?? .distantPast) }
    }

    var body: some View {
        let room = LotRoom.bucket(range, usage: lots.usage[range.id])
        CaliperSheet(title: range.valueLabel) {
            Button("Done") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Caliper.space3) {
                    Text(room.leftLine)
                        .font(.figureSmall)
                        .foregroundStyle(room.isNear ? Caliper.confMid : Caliper.textPrimary)
                    UsageBar(fraction: room.fraction).frame(height: 4)
                    Text("\(room.cardsUsed) of \(range.maxCards) cards · \(Money.dollars(room.centsUsed)) of \(Money.dollars(range.budgetCents)) CL")
                        .caliperMeta()
                    Text(range.criteriaLine).caliperLabel(Caliper.textSecondary).padding(.top, Caliper.space3)
                    if range.name != range.valueLabel {
                        Text(range.name).caliperMeta(Caliper.textTertiary)
                    }
                    if let notes = range.notes, !notes.isEmpty {
                        Text(notes).font(.calBody).foregroundStyle(Caliper.textSecondary)
                    }
                }
                .padding(.horizontal, Caliper.gutter)
                .padding(.top, Caliper.space6)

                SectionLabel(text: "In this bucket · \(claims.count)")
                VStack(spacing: Caliper.rowGap) {
                    ForEach(claims) { claim in
                        TeammateClaimRow(claim: claim,
                                         buyer: team.members.first { $0.userId == claim.buyerId }?.displayName ?? "Former member",
                                         isMine: claim.buyerId == team.myUserId)
                    }
                }
                .padding(.horizontal, Caliper.gutter)
                if claims.isEmpty {
                    Text("Nothing bought into this bucket yet.")
                        .caliperMeta()
                        .padding(.horizontal, Caliper.gutter)
                }
            }
        } confirm: {
            EmptyView()
        }
    }
}

// MARK: - Scanning into a lot

extension AppState {
    /// Make `lot` the one new scans file into — the team's current lot.
    func makeCurrent(_ lot: Lot, in context: ModelContext) {
        var folder = LotFolders.folder(for: lot.id, in: context)
        if folder == nil {
            // The lot opened moments ago and its group has not been made yet.
            LotFolders.sync(lots.lots, isLead: team.isLead, in: context)
            folder = LotFolders.folder(for: lot.id, in: context)
        }
        guard let folder else { return }
        scanTargetId = folder.localId.uuidString
        scanTargetExplicitNone = false
    }

    /// Teams' primary action: this lot, and straight to the camera.
    func scanInto(_ lot: Lot, in context: ModelContext) {
        makeCurrent(lot, in: context)
        tabTouched = true
        tab = .scan
    }
}
