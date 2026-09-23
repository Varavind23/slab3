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
            .tint(Caliper.cyan)
            .padding(.bottom, Caliper.hitMin
                     + (app.isSelecting ? 96 : 0)
                     + (pendingDeletes.pending != nil ? Caliper.hitMin : 0))

            VStack(spacing: 0) {
                // Selection mode does NOT replace the tab bar.
                if app.isSelecting && !app.selection.isEmpty {
                    SelectionBar(
                        count: app.selection.count,
                        totalCents: selectionTotal,
                        group: { showGroupSheet = true },
                        remove: removeFromGroup,
                        export: exportSelection,
                        delete: deleteSelection
                    )
                    .transition(.move(edge: .bottom))
                }
                // Shares the selection bar's slot, and in practice never coexists
                // with it: a bulk delete ends selection before enqueueing.
                if let pending = pendingDeletes.pending {
                    UndoBar(label: pending.label) {
                        withAnimation(Caliper.easeOut) { pendingDeletes.undo() }
                    }
                    .transition(.move(edge: .bottom))
                }
                CaliperTabBar(tab: $app.tab, onChange: { app.endSelecting() })
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
        .preferredColorScheme(.dark) // Caliper is dark-only; cyan-on-black doesn't invert.
    }

    @ViewBuilder private var screen: some View {
        switch app.tab {
        case .scan: ScanScreen(app: app)
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
    private var selectionTotal: Int {
        if app.isMaxBuy {
            return selected.compactMap { MaxBuyValue.cents(for: $0) }.reduce(0, +)
        }
        return selected.compactMap { $0.prices.best(preferring: app.activeSource) }.reduce(0, +)
    }

    private func removeFromGroup() {
        for card in selected { card.folder = nil }
        try? context.save()
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

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                ForEach(AppTab.allCases) { destination in
                    let active = destination == tab
                    Button {
                        if destination != tab { onChange() }
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
