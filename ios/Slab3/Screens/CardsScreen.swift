import SwiftUI
import SwiftData

/// Inventory — the centre of gravity. Everything else is upstream or downstream
/// of it (README.md §3).
///
/// Selection is a MODE on this screen, not a separate screen: the list does not
/// reflow and the scroll position doesn't change when it turns on. The selection
/// bar rises above the tab bar rather than replacing it, which is why it's hosted
/// by MainShell and not here.
struct CardsScreen: View {
    @Bindable var app: AppState
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.scannedAt, order: .reverse) private var allCards: [Card]
    @Query(sort: \Folder.createdAt, order: .reverse) private var groups: [Folder]

    @State private var refresher = PriceRefresher()
    @State private var showFilters = false
    @State private var route: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: Caliper.rowGap) {
                    SummaryBlock(
                        totalCents: totalCents,
                        payoutCents: app.payoutCents(on: totalCents),
                        matched: visible.filter(\.isMatched).count,
                        of: visible.count,
                        scoped: app.filter != .all
                    )
                    FilterPill(
                        label: filterLabel,
                        color: filterHue,
                        isActive: app.filter != .all,
                        open: { showFilters = true },
                        clear: { app.filter = .all }
                    )
                    controls
                    rows
                }
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space8)
            }
        }
        .background(Caliper.bg)
        .sheet(isPresented: $showFilters) {
            FiltersSheet(app: app, cards: allCards, groups: groups, confirmVerb: "Show")
                .presentationDetents([.large])
        }
        .navigationDestination(item: $route) { id in
            if let card = allCards.first(where: { $0.localId == id }) {
                CardDetailScreen(card: card, app: app)
            }
        }
        .alert("Prices", isPresented: Binding(
            get: { refresher.notice != nil },
            set: { if !$0 { refresher.clearNotice() } }
        )) {
            Button("OK", role: .cancel) { refresher.clearNotice() }
        } message: { Text(refresher.notice ?? "") }
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(
            context: app.isSelecting ? "\(app.selection.count) of \(visible.count) selected" : "\(visible.count) cards",
            title: app.isSelecting ? "Select cards" : filterTitle,
            contextTint: app.isSelecting ? Caliper.cyan : Caliper.textSecondary,
            source: $app.activeSource
        ) {
            if app.isSelecting {
                HStack(spacing: Caliper.space5) {
                    Button("All") { app.selection = Set(visible.map(\.localId)) }
                        .font(.mono(10, .medium)).foregroundStyle(Caliper.cyan)
                    Button("Cancel") { app.endSelecting() }
                        .font(.mono(10, .medium)).foregroundStyle(Caliper.textSecondary)
                }
            } else {
                Button("Select") { app.isSelecting = true }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textPrimary)
                    .disabled(visible.isEmpty)
            }
        }
    }

    // MARK: Search / sort / refresh

    private var controls: some View {
        VStack(alignment: .leading, spacing: Caliper.space4) {
            HStack(spacing: Caliper.space4) {
                HStack(spacing: Caliper.space4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(Caliper.textSecondary)
                    // The placeholder counts the CURRENT scope, not the library —
                    // one of the small things that makes filtering feel live.
                    TextField("Search \(visible.count) cards", text: $app.search)
                        .font(.calBody)
                        .foregroundStyle(Caliper.textPrimary)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, Caliper.rowPad)
                .frame(height: 36)
                .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))

                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button(order.label) { app.sort = order }
                    }
                } label: {
                    HStack(spacing: Caliper.space2) {
                        Text(app.sort.label).caliperLabel()
                        Image(systemName: "arrow.down").font(.system(size: 9))
                            .foregroundStyle(Caliper.textSecondary)
                    }
                    .padding(.horizontal, Caliper.space5)
                    .frame(height: 36)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                }

                // The price-refresh trigger the client's spec listed as missing:
                // `Refreshed at` had no visible cause until this button existed.
                Button {
                    Task { await refresher.refresh(visible, in: context) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundStyle(refresher.isRefreshing ? Caliper.cyan : Caliper.textPrimary)
                        .rotationEffect(.degrees(refresher.isRefreshing ? 360 : 0))
                        .animation(refresher.isRefreshing
                                   ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default, value: refresher.isRefreshing)
                        .frame(width: 36, height: 36)
                        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                }
                .buttonStyle(CaliperPressStyle())
                .disabled(visible.isEmpty || refresher.isRefreshing)
                .accessibilityLabel("Refresh prices")
            }

            Text(refreshLine)
                .caliperLabel(refresher.isRefreshing ? Caliper.cyan : Caliper.textTertiary)
        }
        .padding(.top, Caliper.space2)
    }

    private var refreshLine: String {
        if refresher.isRefreshing {
            return "Refreshing \(refresher.total) cards · CL, CY"
        }
        guard let last = visible.compactMap(\.lastPricedAt).max() else {
            return "Prices not fetched yet"
        }
        return "Prices refreshed \(last.formatted(.dateTime.month(.abbreviated).day())) · \(last.formatted(.dateTime.hour().minute()))"
    }

    // MARK: Rows

    @ViewBuilder private var rows: some View {
        if visible.isEmpty {
            VStack(spacing: Caliper.space5) {
                Text(emptyCopy)
                    .font(.calBody)
                    .foregroundStyle(Caliper.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Caliper.space8 * 2)
        } else {
            ForEach(visible) { card in
                Button {
                    if app.isSelecting { app.toggleSelection(card.localId) } else { route = card.localId }
                } label: {
                    CardRow(
                        card: card,
                        source: app.activeSource,
                        selectable: app.isSelecting,
                        selected: app.selection.contains(card.localId)
                    )
                }
                .buttonStyle(CaliperPressStyle())
                .contextMenu {
                    Button("Select") { app.isSelecting = true; app.selection.insert(card.localId) }
                    if card.folder != nil {
                        Button("Remove from group") { card.folder = nil }
                    }
                    Button("Delete card", role: .destructive) { context.delete(card) }
                }
            }
        }
    }

    private var emptyCopy: String {
        switch app.filter {
        case .all: return app.search.isEmpty
            ? "No cards yet. Scan a slab to begin."
            : "Nothing matches “\(app.search)”."
        case .ungrouped: return "Every card is in a group."
        case .unmatched: return "Every card has a price."
        case .group: return "This group is empty. Select cards and add them."
        }
    }

    // MARK: Scope

    /// The visible scope: filter, then search, then sort. Every count, total and
    /// placeholder on this screen reads from this one array so they can't drift.
    private var visible: [Card] {
        var cards = allCards.filter { card in
            switch app.filter {
            case .all: return true
            case .ungrouped: return card.folder == nil
            case .unmatched: return !card.isMatched
            case .group(let id): return card.folder?.localId == id
            }
        }
        let needle = app.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            cards = cards.filter {
                $0.displayTitle.lowercased().contains(needle)
                || $0.certNumber.contains(needle)
                || ($0.set?.lowercased().contains(needle) ?? false)
            }
        }
        switch app.sort {
        case .recent: return cards.sorted { $0.scannedAt > $1.scannedAt }
        case .name: return cards.sorted { $0.displayTitle.localizedCompare($1.displayTitle) == .orderedAscending }
        case .price:
            // Sorts by the ACTIVE source — the toggle changes the sort basis, not
            // just the colour. Cards with no price for it sink to the bottom.
            return cards.sorted { ($0.prices[app.activeSource] ?? -1) > ($1.prices[app.activeSource] ?? -1) }
        }
    }

    private var totalCents: Int {
        visible.compactMap { $0.prices.best(preferring: app.activeSource) }.reduce(0, +)
    }

    private var activeGroup: Folder? {
        if case .group(let id) = app.filter { return groups.first { $0.localId == id } }
        return nil
    }
    private var filterTitle: String { activeGroup?.name ?? "Inventory" }
    private var filterHue: Color? { activeGroup?.hue }
    private var filterLabel: String {
        switch app.filter {
        case .all: return "All cards"
        case .ungrouped: return "Ungrouped"
        case .unmatched: return "Unmatched"
        case .group: return activeGroup?.name ?? "Group"
        }
    }
}
