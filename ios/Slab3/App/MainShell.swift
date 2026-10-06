import SwiftUI
import SwiftData

/// The four-tab shell. Built by hand rather than with `TabView` for one specific
/// reason: Caliper's selection bar rises ABOVE the tab bar without replacing it,
/// and the bar itself is a precise piece of the design (hairline top border, a
/// 17pt glyph over a mono uppercase label, cyan when active). A styled TabView
/// can't do either honestly.
struct MainShell: View {
    let auth: AuthManager
    @State private var app = AppState()
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Card.scannedAt, order: .reverse) private var cards: [Card]

    /// Deletes waiting out their undo window. It lives HERE, at the same tier as
    /// `AppState` and for the same reason the selection bar does: it outlives any
    /// one screen, and rebuilt per screen appearance its timer would be cancelled
    /// by ARC and a pending delete would silently never commit.
    @State private var pendingDeletes = PendingDeletionStore()

    @State private var showGroupSheet = false
    /// The selection bar's Member picker (V4) and anything it could not do.
    @State private var choosingMember = false
    @State private var memberNote: String?
    /// Teams: the connection, so offline lot scans sync the moment it returns, and
    /// the summary of how they landed.
    @State private var connectivity = Connectivity()
    @State private var syncSummary: LotClaims.SyncSummary?
    @State private var shareURL: URL?

    var body: some View {
        ZStack(alignment: .bottom) {
            Caliper.bg.ignoresSafeArea()

            Group {
                if app.tab == .teams {
                    // The one tab with a path: Cards' lot line and the Scan bar send
                    // the user INTO it, and Team activity drills three levels deep.
                    NavigationStack(path: $app.teamsPath) {
                        TeamsScreen(app: app)
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationDestination(for: TeamsRoute.self) { TeamsDestination(app: app, route: $0) }
                    }
                } else {
                    NavigationStack {
                        screen
                            .toolbar(.hidden, for: .navigationBar)
                    }
                }
            }
            // One stack PER TAB. All four used to share one, so a card's detail
            // screen stayed pushed on top when the tab changed underneath it — the
            // tab bar looked dead until you backed out of the card (user report,
            // 0.7). A new identity per tab starts every tab at its own root.
            .id(app.tab)
            .tint(Caliper.cyan)
            .padding(.bottom, Caliper.hitMin
                     + (app.isSelecting ? 96 : 0)
                     + (pendingDeletes.pending != nil ? Caliper.hitMin : 0)
                     + (syncSummary != nil && pendingDeletes.pending == nil && !app.isSelecting ? Caliper.hitMin : 0))

            VStack(spacing: 0) {
                // Selection mode does NOT replace the tab bar.
                if app.isSelecting && !app.selection.isEmpty {
                    SelectionBar(
                        count: app.selection.count,
                        totalCents: selectionTotal.cents,
                        counted: selectionTotal.counted,
                        basis: app.isMaxBuy ? PriceLens.maxBuy.rowLabel : "EST. VALUE",
                        group: { showGroupSheet = true },
                        remove: removeFromGroup,
                        export: exportSelection,
                        delete: deleteSelection,
                        member: app.team.team == nil ? nil : { choosingMember = true }
                    )
                    .transition(.move(edge: .bottom))
                }
                // Shares the selection bar's slot, and in practice never coexists
                // with it: a bulk delete ends selection before enqueueing.
                if let syncSummary, pendingDeletes.pending == nil, !app.isSelecting {
                    LotSyncBar(summary: syncSummary).transition(.move(edge: .bottom))
                }
                if let pending = pendingDeletes.pending {
                    UndoBar(label: pending.label) {
                        withAnimation(Caliper.easeOut) { pendingDeletes.undo() }
                    }
                    .transition(.move(edge: .bottom))
                }
                CaliperTabBar(tab: $app.tab, tabs: app.visibleTabs,
                              onChange: {
                                  app.endSelecting()
                                  app.tabTouched = true
                                  // Picking Teams from the bar starts it at its root.
                                  app.teamsPath = []
                              },
                              onReselect: {
                                  if app.tab == .teams { app.teamsPath = [] }
                                  app.tabReselected += 1
                              })
            }
        }
        // Every path that has to make a pending delete real. Leaving Cards is what
        // keeps the Export tab honest about what is still inventory; backgrounding
        // is the last checkpoint iOS guarantees, and the one that stops a deleted
        // card from reappearing after a relaunch.
        .onChange(of: app.tab) { previous, _ in
            if previous == .cards { pendingDeletes.flush() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { pendingDeletes.flush() }
            if phase == .active { Task { await refreshTeam() } }
        }
        // Teams (all inert unless TeamsFeature.isAvailable). A lot is a shared
        // group, so the team's lots become local groups here — and only when the
        // lot list actually CHANGED after a successful load, never on a failure.
        .onChange(of: app.team.team?.id) { _, id in
            Task {
                await loadLots()
                // Live totals only while on a team; a user with none holds no socket.
                if let id {
                    await app.lots.startLive(teamId: id)
                    connectivity.start()
                } else {
                    await app.lots.stopLive()
                    connectivity.stop()
                }
            }
        }
        .onChange(of: app.lots.lots) { _, _ in syncLotGroups() }
        // A lead released one of this phone's slabs: the card says so.
        .onChange(of: app.lots.loadedAt) { _, loadedAt in
            LotClaims.reconcile(app.lots.claimsByLot, lots: app.lots.lots, loadedAt: loadedAt,
                                myUserId: app.team.myUserId, in: context)
        }
        // A claim or release moved the lot's totals; the dashboard re-reads them.
        .onReceive(NotificationCenter.default.publisher(for: LotClaims.changed)) { _ in
            guard TeamsFeature.isAvailable, app.team.lastLoadOK, let id = app.team.team?.id else { return }
            app.lots.requestReload(teamId: id)
        }
        .onChange(of: connectivity.isOnline) { _, online in
            if online { Task { await refreshTeam() } }
        }
        // Left the team (or it was deleted) while looking at Teams: back to Scan,
        // never a tab that is no longer in the bar.
        .onChange(of: app.visibleTabs) { _, tabs in
            if !tabs.contains(app.tab) { app.tab = .scan; app.teamsPath = [] }
        }
        .onChange(of: app.team.isLead) { _, _ in
            // A promoted lead starts seeing drafts; a demoted one stops. On a cold
            // launch this flips BEFORE the lots arrive — syncLotGroups' gate is what
            // keeps that from detaching every lot group.
            syncLotGroups()
        }
        .fullScreenCover(isPresented: Binding(
            get: { !app.hasSeenOnboarding },
            set: { if !$0 { app.hasSeenOnboarding = true } }
        )) {
            OnboardingScreen { app.hasSeenOnboarding = true }
        }
        .sheet(isPresented: $showGroupSheet) {
            GroupSheet(app: app, cards: cards, pendingDeletes: pendingDeletes).presentationDetents([.large])
        }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        .confirmationDialog("Who sourced these \(app.selection.count)?", isPresented: $choosingMember,
                            titleVisibility: .visible) {
            ForEach(app.team.buyerChoices) { buyer in
                Button(buyer.isVirtual ? "\(buyer.name) · virtual" : buyer.name) { tagSelection(buyer) }
            }
            Button("Clear tag") { tagSelection(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cards in a lot are tagged for the whole team; the rest on this phone only.")
        }
        .alert("Member", isPresented: Binding(get: { memberNote != nil }, set: { if !$0 { memberNote = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(memberNote ?? "")
        }
        // Before anything waits on a refresh flag: none is running on a fresh launch.
        .task { PriceService.clearStaleLoading(in: context) }
        // Returns at once, with no request, unless TeamsFeature.isAvailable.
        .task { await refreshTeam() }
        .preferredColorScheme(.dark) // Caliper is dark-only; cyan-on-black doesn't invert.
    }

    /// Launch, the app coming forward, the connection returning and a repair can
    /// all ask at once; a second run while one is going would re-submit every
    /// waiting claim and count offline scans twice in the sync bar. One at a time.
    @State private var refreshingTeam = false

    private func refreshTeam() async {
        guard TeamsFeature.isAvailable, !refreshingTeam else { return }
        refreshingTeam = true
        defer { refreshingTeam = false }
        await app.team.load()
        if app.team.lastLoadOK {
            let wasOnTeam = app.onTeamHint
            let onTeam = app.team.team != nil
            app.onTeamHint = onTeam
            // Just found to be on a team (the first launch after joining on another
            // device, say): land on Teams — once, and only if the user has not
            // started doing something else (D1). Never moves anyone mid-use.
            if onTeam, !wasOnTeam, !app.tabTouched, app.tab == .scan { app.tab = .teams }
        }
        await loadLots()
        // Anything that couldn't get an answer last time (no signal, no CL price),
        // oldest first; if offline scans were among them, say how they landed.
        if app.team.team != nil, let summary = await LotClaims.retryPending(in: context) {
            withAnimation(Caliper.easeOut) { syncSummary = summary }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(Caliper.easeOut) { if syncSummary == summary { syncSummary = nil } }
        }
    }

    /// Mirror the team's lots as local groups — only once `lots` is known to be
    /// THIS team's loaded list (TeamSync) — then heal any group an earlier build
    /// split, and keep Scan's stored group pointing at something real.
    private func syncLotGroups() {
        guard TeamSync.shouldSyncGroups(teamLoadOK: app.team.lastLoadOK, teamId: app.team.team?.id,
                                        lotsLoadedAt: app.lots.loadedAt,
                                        lotsTeamId: app.lots.loadedTeamId) else { return }
        let released = LotFolders.sync(app.lots.lots, isLead: app.team.isLead, in: context)
        let repair = LotFolders.repair(app.lots.lots, isLead: app.team.isLead, in: context)
        var stored = app.scanTargetUUID
        if let id = stored, let kept = repair.merged[id] {
            stored = kept
        } else if let id = stored, released.contains(id), !repair.reattached.contains(id) {
            // That group is not a lot any more; filing into it would skip the claim.
            stored = nil
        }
        // Resume, drop a closed lot, or pick the only open one (ScanTargetRule).
        let groups = ((try? context.fetch(FetchDescriptor<Folder>())) ?? []).map(GroupRef.init)
        let target = ScanTargetRule.resolve(stored: stored, explicitNone: app.scanTargetExplicitNone,
                                            groups: groups, lots: app.lots.lots, lotsLoaded: true,
                                            onTeam: app.team.team != nil)
        let targetId = target?.uuidString ?? ""
        if app.scanTargetId != targetId { app.scanTargetId = targetId }
        if repair.requeued > 0 { Task { await refreshTeam() } }
    }

    private func loadLots() async {
        guard TeamsFeature.isAvailable, app.team.lastLoadOK else { return }
        await app.lots.load(teamId: app.team.team?.id)
    }

    @ViewBuilder private var screen: some View {
        switch app.tab {
        case .scan: ScanScreen(app: app, pendingDeletes: pendingDeletes)
        case .cards: CardsScreen(app: app, pendingDeletes: pendingDeletes)
        case .teams: TeamsScreen(app: app)   // drawn by its own stack in body
        case .export: ExportScreen(app: app, pendingDeletes: pendingDeletes)
        case .settings: SettingsScreen(app: app, auth: auth)
        }
    }

    // MARK: Selection actions

    private var selected: [Card] { cards.filter { app.selection.contains($0.localId) } }

    /// The running total the whole selection mode exists for — sourcers select until
    /// they hit a target. Under the max-buy lens that target is what they can PAY for
    /// the pile, not what it is worth, so the figure follows the lens.
    ///
    /// `compactMap` either way: a card with no figure contributes nothing rather than
    /// a zero. Worth knowing that comps-less cards are far more common than
    /// price-less ones, so this total can cover fewer cards than are selected.
    private var selectionTotal: (cents: Int, counted: Int) {
        LensTotal.of(selected, lens: app.lens)
    }

    private func removeFromGroup() {
        CardFiling.unfile(selected, in: context)
        app.endSelecting()
    }

    private func tagSelection(_ buyer: Buyer?) {
        let chosen = selected
        app.endSelecting()
        Task {
            memberNote = await CardTagging.tag(chosen, to: buyer, team: app.team, lots: app.lots, in: context)
        }
    }

    private func exportSelection() {
        shareURL = CSVExport.write(
            selected,
            columns: app.exportColumns,
            scope: nil,
            payoutPercent: app.payoutPercent,
            maxBuyCents: MaxBuyValue.centsByCard(selected),
            buyers: Dictionary(selected.compactMap { card in
                CardTagging.buyerName(for: card, claimsByLot: app.lots.claimsByLot,
                                      members: app.team.members, people: app.team.people).map { (card.localId, $0) }
            }, uniquingKeysWith: { a, _ in a })
        )
        app.endSelecting()
    }

    /// Bulk delete is the more dangerous of the two delete paths — dozens of cards
    /// on one tap — so it goes through the same undo window the swipe does rather
    /// than deleting outright. Selection ends first, which is also what keeps the
    /// selection bar and the undo bar from ever sharing their slot.
    private func deleteSelection() {
        let ids = Set(selected.map(\.localId))
        guard !ids.isEmpty else { return }
        let label = ids.count == 1 ? "Card deleted" : "\(ids.count) cards deleted"
        app.endSelecting()
        withAnimation(Caliper.easeOut) {
            pendingDeletes.enqueue(ids, label: label) { doomed in commitDeletes(doomed) }
        }
    }

    /// The actual delete, run when the undo window closes. Shared with the Cards
    /// swipe so both paths delete identically.
    private func commitDeletes(_ ids: Set<UUID>) {
        CardDeletion.commit(ids, in: context)
    }
}

/// Four columns — five on a team — 1pt line top border, bg fill. Active is cyan
/// with a heavier stroke; inactive is textSecondary.
struct CaliperTabBar: View {
    @Binding var tab: AppTab
    var tabs: [AppTab] = AppTab.visible(teamsAvailable: false, onTeam: false)
    var onChange: () -> Void = {}
    /// The active tab was tapped again.
    var onReselect: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                ForEach(tabs) { destination in
                    let active = destination == tab
                    Button {
                        if destination != tab { onChange() } else { onReselect() }
                        tab = destination
                    } label: {
                        VStack(spacing: Caliper.space2) {
                            Image(systemName: destination.glyph)
                                .font(.system(size: 17, weight: active ? .semibold : .regular))
                            Text(destination.title).caliperLabel(active ? Caliper.cyan : Caliper.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(active ? Caliper.cyan : Caliper.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: Caliper.hitMin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CaliperPressStyle())
                    .accessibilityAddTraits(active ? [.isSelected] : [])
                }
            }
            .padding(.top, Caliper.space3)
        }
        .background(Caliper.bg)
    }
}
