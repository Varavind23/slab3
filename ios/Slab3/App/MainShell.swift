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
    @Query(sort: \Card.scannedAt, order: .reverse) private var cards: [Card]

    @State private var showGroupSheet = false
    @State private var shareURL: URL?

    var body: some View {
        ZStack(alignment: .bottom) {
            Caliper.bg.ignoresSafeArea()

            NavigationStack {
                screen
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tint(Caliper.cyan)
            .padding(.bottom, Caliper.hitMin + (app.isSelecting ? 96 : 0))

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
                CaliperTabBar(tab: $app.tab, onChange: { app.endSelecting() })
            }
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
        .preferredColorScheme(.dark) // Caliper is dark-only; cyan-on-black doesn't invert.
    }

    @ViewBuilder private var screen: some View {
        switch app.tab {
        case .scan: ScanScreen(app: app)
        case .cards: CardsScreen(app: app)
        case .export: ExportScreen(app: app)
        case .settings: SettingsScreen(app: app, auth: auth)
        }
    }

    // MARK: Selection actions

    private var selected: [Card] { cards.filter { app.selection.contains($0.localId) } }
    private var selectionTotal: Int {
        selected.compactMap { $0.prices.best(preferring: app.activeSource) }.reduce(0, +)
    }

    private func removeFromGroup() {
        for card in selected { card.folder = nil }
        try? context.save()
        app.endSelecting()
    }

    private func exportSelection() {
        shareURL = CSVExport.write(
            selected,
            columns: app.enabledColumns,
            scope: nil,
            payoutPercent: app.payoutPercent
        )
        app.endSelecting()
    }

    private func deleteSelection() {
        for card in selected { context.delete(card) }
        try? context.save()
        app.endSelecting()
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
