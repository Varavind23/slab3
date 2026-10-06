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
    /// Owned by MainShell — rows inside their undo window are hidden from this
    /// list, and the swipe's delete enqueues here rather than deleting outright.
    let pendingDeletes: PendingDeletionStore
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.scannedAt, order: .reverse) private var allCards: [Card]
    @Query(sort: \Folder.createdAt, order: .reverse) private var groups: [Folder]

    @State private var showFilters = false
    @State private var route: UUID?
    /// Whose swipe tray is open. One at a time, so a row opening closes the last.
    @State private var openRowID: UUID?
    /// Set when a swipe wants to file a card but no group has ever been used —
    /// the picker opens for that one card without entering selection mode.
    @State private var filingCard: Card?

    var body: some View {
        // Filtered, searched and sorted ONCE per render. It used to be a computed
        // property read ~10 times a pass, and a scan's price writebacks re-render
        // this screen many times over a large inventory (review 2026-10-02).
        let visible = self.visible
        // Follows the lens (owner decision, 2026-09-25); see `LensTotal`.
        let summary = LensTotal.of(visible, lens: app.lens)
        VStack(spacing: 0) {
            header(visible)
            ScrollView {
                LazyVStack(spacing: Caliper.rowGap) {
                    SummaryBlock(
                        totalCents: summary.cents,
                        payoutCents: app.payoutCents(on: summary.cents),
                        matched: app.isMaxBuy ? summary.counted : visible.filter(\.isMatched).count,
                        of: visible.count,
                        scoped: app.filter != .all,
                        maxBuy: app.isMaxBuy
                    )
                    FilterPill(
                        label: filterLabel,
                        color: filterHue,
                        isActive: app.filter != .all,
                        open: { showFilters = true },
                        clear: { app.filter = .all }
                    )
                    // A lot's group is cards only; how full the lot is lives on
                    // Teams (teams-first plan, D9) — one tap away.
                    if let lot = filteredLot {
                        LotLinkLine(lot: lot, room: LotRoom.lot(ranges: app.lots.ranges(for: lot),
                                                                usage: app.lots.usage)) {
                            app.tabTouched = true
                            app.tab = .teams
                            app.teamsPath = [.lot(lot.id)]
                        }
                    }
                    controls(visible)
                    rows(visible)
                    if let lot = filteredLot { teammateRows(lot) }
                }
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space8)
            }
            // The filter pill and search stay live in selection mode, and the bulk
            // actions act on `app.selection` against the WHOLE store — so a card
            // selected and then filtered out of sight would still be deleted by
            // the selection bar. Only what is on screen may stay selected.
            .onChange(of: visible.map(\.localId)) { _, ids in
                guard app.isSelecting else { return }
                let onScreen = app.selection.intersection(ids)
                if onScreen != app.selection { app.selection = onScreen }
            }
        }
        .background(Caliper.bg)
        .sheet(isPresented: $showFilters) {
            FiltersSheet(app: app, cards: allCards, groups: groups, confirmVerb: "Show", pendingDeletes: pendingDeletes)
                .presentationDetents([.large])
        }
        // Filing one card from the swipe when no group has ever been used. It
        // deliberately does not enter selection mode: the user swiped a single row,
        // they did not ask to start a multi-select.
        .sheet(item: $filingCard) { card in
            GroupSheet(app: app, cards: allCards, targets: [card], pendingDeletes: pendingDeletes)
                .presentationDetents([.large])
        }
        // Tapping Cards while a card is open goes back to the list.
        .onChange(of: app.tabReselected) { _, _ in route = nil }
        .navigationDestination(item: $route) { id in
            if let card = allCards.first(where: { $0.localId == id }) {
                CardDetailScreen(card: card, app: app, pendingDeletes: pendingDeletes)
            }
        }
    }

    // MARK: Header

    private func header(_ visible: [Card]) -> some View {
        ScreenHeader(
            context: app.isSelecting ? "\(app.selection.count) of \(visible.count) selected" : "\(visible.count) cards",
            title: app.isSelecting ? "Select cards" : filterTitle,
            contextTint: app.isSelecting ? Caliper.cyan : Caliper.textSecondary,
            lens: $app.lens,
            lenses: app.availableLenses
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

    private func controls(_ visible: [Card]) -> some View {
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

            }

            Text(refreshLine(visible)).caliperLabel(Caliper.textTertiary)
        }
        .padding(.top, Caliper.space2)
    }

    /// When these prices were last fetched — and nothing that re-fetches them.
    ///
    /// The refresh-all button that sat beside the sort control was removed
    /// 2026-09-16 (owner decision). One tap ran the whole visible scope, which is a
    /// stack-sized burst at an endpoint that 403s an IP for hammering it, against a
    /// 200/day per-user Card Ladder budget — the volume risk outweighed the
    /// convenience. Prices arrive on the scan and are re-fetched one card at a time
    /// from the detail screen, so this line now reports rather than explains; its
    /// in-flight `Refreshing N cards · CL, CY` state went with the button. Caliper
    /// §3 specifies both, and this deviates from it knowingly.
    private func refreshLine(_ visible: [Card]) -> String {
        guard let last = visible.compactMap(\.lastPricedAt).max() else {
            return "Prices not fetched yet"
        }
        return "Prices refreshed \(last.formatted(.dateTime.month(.abbreviated).day())) · \(last.formatted(.dateTime.hour().minute()))"
    }

    // MARK: Rows

    @ViewBuilder private func rows(_ visible: [Card]) -> some View {
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
            ForEach(visible, id: \.localId) { card in
                // The context menu that used to hang here — Select / Remove from
                // group / Delete card — is gone. Its actions moved to the swipe and
                // the selection bar, and the long-press it occupied now starts
                // selection instead. `SwipeableCardRow` carries the same two actions
                // as accessibility actions, which is the only route VoiceOver has
                // to them once a swipe is the affordance.
                SwipeableCardRow(
                    card: card,
                    lens: app.lens,
                    selectable: app.isSelecting,
                    selected: app.selection.contains(card.localId),
                    paidCents: app.paidCents(card),
                    fileTarget: Folder.mostRecentlyUsed(in: groups),
                    openRowID: $openRowID,
                    onTap: {
                        if app.isSelecting {
                            app.toggleSelection(card.localId)
                        } else {
                            route = card.localId
                        }
                    },
                    onFile: { file(card) },
                    onDelete: { delete(card) }
                )
                // The long press belongs to the SYSTEM again (2026-09-16). iOS's own
                // menu brings its zoom and its haptic with it, and that pairing is
                // what V4 had and what a hand-built lift never matched — the lift
                // and its 0.8s press went out with this coming back. Select turns
                // selection mode on; from there a tap toggles a card and a drag
                // always scrolls (drag-to-select was removed 2026-10-04).
                //
                // EMPTY in selection mode, which suppresses the menu entirely:
                // selection mode has the selection bar for these actions.
                .contextMenu {
                    if !app.isSelecting {
                        Button("Select") {
                            app.isSelecting = true
                            app.selection.insert(card.localId)
                        }
                        if card.folder != nil {
                            Button("Remove from group") {
                                CardFiling.unfile([card], in: context)
                            }
                        }
                        Button("Delete card", role: .destructive) { delete(card) }
                    }
                }
            }
        }
    }

    // MARK: Swipe actions

    /// File a swiped card into the group last filed into — or, when nothing has
    /// ever been filed, open the picker rather than inventing a destination. Same
    /// rule prices follow: never fabricate an answer to look decisive.
    private func file(_ card: Card) {
        guard let target = Folder.mostRecentlyUsed(in: groups) else {
            filingCard = card
            return
        }
        CardFiling.file([card], into: target, in: context)
    }

    /// The row leaves the list now; the delete becomes real when the undo window
    /// closes. Animated, because this collapse is the only thing the user sees —
    /// and unreachable in selection mode, where Caliper forbids the list reflowing
    /// and the swipe is masked off anyway.
    private func delete(_ card: Card) {
        withAnimation(Caliper.easeOut) {
            pendingDeletes.enqueue([card.localId], label: "Card deleted") { ids in
                CardDeletion.commit(ids, in: context)
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
        // Pending deletes come out first: a row inside its undo window has left the
        // inventory as far as the user is concerned, and every count, total and
        // placeholder on this screen reads from this one array.
        var cards = allCards.filter { !pendingDeletes.pendingIDs.contains($0.localId) }
        cards = cards.filter { card in
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
            // Sorts by whatever LEADS — the toggle changes the sort basis, not just
            // the colour. Cards with no figure for it sink to the bottom.
            guard app.isMaxBuy else {
                return cards.sorted { ($0.prices[app.activeSource] ?? -1) > ($1.prices[app.activeSource] ?? -1) }
            }
            // Decorate–sort–undecorate: each card is valued ONCE per sort rather
            // than once per comparison. The scannedAt tiebreak matters more here
            // than on a price sort — comps-less cards all tie at -1, and without it
            // their order would shuffle between recomputes of this property.
            //
            // Spelled out in steps rather than chained: the tuple version defeats
            // the type checker ("unable to type-check in reasonable time").
            var valued: [(card: Card, cents: Int)] = []
            valued.reserveCapacity(cards.count)
            for card in cards {
                valued.append((card, MaxBuyValue.cents(for: card) ?? -1))
            }
            valued.sort { lhs, rhs in
                if lhs.cents != rhs.cents { return lhs.cents > rhs.cents }
                return lhs.card.scannedAt > rhs.card.scannedAt
            }
            return valued.map(\.card)
        }
    }


    private var activeGroup: Folder? {
        if case .group(let id) = app.filter { return groups.first { $0.localId == id } }
        return nil
    }
    private var filterTitle: String { activeGroup?.name ?? "Inventory" }
    private var filterHue: Color? { activeGroup?.hue }
    /// Teammates' slabs in this lot — everything claimed into it by someone ELSE
    /// (plan §7.5). By buyer, not by "cert not on this phone": a slab this phone
    /// scanned and was turned away from (a teammate had it) is still theirs to list.
    /// Read-only: no swipe, no selection. A lead can release one.
    @ViewBuilder
    private func teammateRows(_ lot: Lot) -> some View {
        let theirs = app.lots.claims(for: lot).filter { $0.buyerId != app.team.myUserId }
        if !theirs.isEmpty {
            Text("Teammates' buys · \(theirs.count)")
                .caliperLabel(Caliper.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Caliper.space6)
            ForEach(theirs) { claim in
                TeammateClaimRow(claim: claim,
                                 buyer: app.team.members.first { $0.userId == claim.buyerId }?.displayName ?? "A teammate",
                                 isMine: claim.buyerId == app.team.myUserId)
                    .contextMenu {
                        if app.team.isLead {
                            Button("Release from lot", role: .destructive) {
                                Task {
                                    guard let teamId = app.team.team?.id else { return }
                                    _ = await app.lots.release(claim, teamId: teamId)
                                }
                            }
                        }
                    }
            }
        }
    }

    /// The lot behind the current filter, when the filter is a team lot's group.
    private var filteredLot: Lot? {
        guard case .group(let id) = app.filter,
              let lotId = groups.first(where: { $0.localId == id })?.teamLotId else { return nil }
        return app.lots.lots.first { $0.id == lotId }
    }

    private var filterLabel: String {
        switch app.filter {
        case .all: return "All cards"
        case .ungrouped: return "Ungrouped"
        case .unmatched: return "Unmatched"
        case .group: return activeGroup?.name ?? "Group"
        }
    }
}
