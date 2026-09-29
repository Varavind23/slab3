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
    /// Teams: the connection, so offline lot scans sync the moment it returns, and
    /// the summary of how they landed.
    @State private var connectivity = Connectivity()
    @State private var syncSummary: LotClaims.SyncSummary?
    @State private var shareURL: URL?

    /// Mirrored into `AppState.testingUnlocked` below — see there for why.
    @AppStorage(TestingGate.unlockedKey) private var testingUnlocked = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Caliper.bg.ignoresSafeArea()

            NavigationStack {
                screen
                    .toolbar(.hidden, for: .navigationBar)
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
                        delete: deleteSelection
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
                CaliperTabBar(tab: $app.tab, onChange: { app.endSelecting() },
                              onReselect: { app.tabReselected += 1 })
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
            GroupSheet(app: app, cards: cards).presentationDetents([.large])
        }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        // The testing gate decides whether the toggle has a max-buy segment at all,
        // and it is flipped from a Settings sheet. Mirrored into AppState rather
        // than read there from UserDefaults, because a read inside `lens` would not
        // be observable — the third segment would linger until something unrelated
        // invalidated the header. Locking while max buy leads drops every consumer
        // back to the source underneath, in AppState's own didSet.
        .onChange(of: testingUnlocked) { _, unlocked in app.testingUnlocked = unlocked }
        .task { app.testingUnlocked = testingUnlocked }
        // Returns at once, with no request, unless TeamsFeature.isAvailable.
        .task { await refreshTeam() }
        .preferredColorScheme(.dark) // Caliper is dark-only; cyan-on-black doesn't invert.
    }

    private func refreshTeam() async {
        guard TeamsFeature.isAvailable else { return }
        await app.team.load()
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
        let key = ScanScreen.scanGroupKey
        let stored = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
        if let stored, let kept = repair.merged[stored] {
            UserDefaults.standard.set(kept.uuidString, forKey: key)
        } else if let stored, released.contains(stored), !repair.reattached.contains(stored) {
            // That group is not a lot any more; filing into it would skip the claim.
            UserDefaults.standard.set("", forKey: key)
        }
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

    private func exportSelection() {
        shareURL = CSVExport.write(
            selected,
            columns: app.exportColumns,
            scope: nil,
            payoutPercent: app.payoutPercent,
            maxBuyCents: MaxBuyValue.centsByCard(selected)
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

/// Four columns, 1pt line top border, bg fill. Active is cyan with a heavier
/// stroke; inactive is textSecondary.
struct CaliperTabBar: View {
    @Binding var tab: AppTab
    var onChange: () -> Void = {}
    /// The active tab was tapped again.
    var onReselect: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                ForEach(AppTab.allCases) { destination in
                    let active = destination == tab
                    Button {
                        if destination != tab { onChange() } else { onReselect() }
                        tab = destination
                    } label: {
                        VStack(spacing: Caliper.space2) {
                            Image(systemName: destination.glyph)
                                .font(.system(size: 17, weight: active ? .semibold : .regular))
                            Text(destination.title).caliperLabel(active ? Caliper.cyan : Caliper.textSecondary)
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
