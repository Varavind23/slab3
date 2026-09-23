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

    // MARK: Scrub selection
    //
    // Long-press takes a row; dragging on from there takes every row crossed. Three
    // measurements make that work without each row publishing its own frame — which
    // would re-publish the whole list on every scroll tick, the one shape certain to
    // stutter on a 200-slab stack.
    @State private var dragSelect = DragSelectController()
    /// Screen-space y of the top of the rows stack. It moves AS THE LIST SCROLLS,
    /// which is exactly what lets a finger position become a row index without
    /// tracking scroll offset separately.
    @State private var rowsOriginY: CGFloat = 0
    /// One row's height, derived from the stack's height and the row count rather
    /// than measured per row. Rows are uniform and their fonts are fixed size, so
    /// this holds — see DragSelectRange.index.
    @State private var rowHeight: CGFloat = 0
    /// Where the scrolling viewport sits on screen, for the auto-scroll edge bands.
    @State private var viewport: CGRect = .zero
    /// nil when no auto-scroll is running; otherwise which way. It is the task id,
    /// so the loop starts and cancels itself as the finger enters and leaves a band.
    @State private var autoScrollUp: Bool?
    /// How deep into the band the finger is, 0...1. Kept out of the task id so that
    /// a change of speed does not restart the loop.
    @State private var autoScrollIntensity: CGFloat = 0
    /// The last place the finger was seen, in screen space. The auto-scroll loop
    /// re-reads it after every step, because a finger that is holding still is
    /// still crossing rows while the list moves under it.
    @State private var lastScrubPoint: CGPoint = .zero
    /// Held rather than built per press: the first buzz of a generator made on the
    /// spot lands late enough to feel disconnected from the press that caused it
    /// (the same reason the scanner holds its own).
    @State private var scrubHaptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 0) {
            header
            // The reader is here only so a scrub can drive the list past its own
            // edges; nothing else on this screen scrolls programmatically.
            ScrollViewReader { proxy in
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
                .background(viewportReader)
                // While a scrub is running the list must NOT scroll under it. The
                // scrub is attached simultaneously, so without this both recognise
                // the same vertical drag: the list scrolls, the finger never crosses
                // a row relative to the content, and dragging down selects nothing.
                // Reaching the rows below is what the edge auto-scroll is for.
                // `&& app.isSelecting` is a FAILSAFE, not a redundancy: endScrub()
                // is only reachable from the sequence's onEnded, and a CANCELLED
                // gesture never calls it — a row recycled by LazyVStack mid-scrub
                // does exactly that, which the edge auto-scroll actively causes.
                // A stranded anchor used to leave the list unscrollable until the
                // screen was rebuilt (user report, 0.5). Leaving selection mode now
                // always gives scrolling back.
                .scrollDisabled(dragSelect.isActive && app.isSelecting)
                .onChange(of: app.isSelecting) { _, selecting in
                    if !selecting { endScrub() }
                }
                .onDisappear { endScrub() }
                // One rendered row's index and frame give the whole stack's origin
                // and pitch. It refreshes as the list scrolls, which is what lets a
                // finger position become a row index without tracking scroll offset
                // separately — and what keeps working when LazyVStack discards the
                // rows that have gone off screen.
                .onPreferenceChange(RowSampleKey.self) { sample in
                    guard let sample, sample.height > 0 else { return }
                    rowHeight = sample.height
                    rowsOriginY = sample.minY - CGFloat(sample.index) * (sample.height + Caliper.rowGap)
                }
                // Keyed on direction, so entering a band starts the loop and
                // leaving one cancels it — no timer to forget to tear down.
                .task(id: autoScrollUp) { await autoScrollLoop(proxy: proxy) }
                .task { scrubHaptic.prepare() }
            }
        }
        .background(Caliper.bg)
        .sheet(isPresented: $showFilters) {
            FiltersSheet(app: app, cards: allCards, groups: groups, confirmVerb: "Show")
                .presentationDetents([.large])
        }
        // Filing one card from the swipe when no group has ever been used. It
        // deliberately does not enter selection mode: the user swiped a single row,
        // they did not ask to start a multi-select.
        .sheet(item: $filingCard) { card in
            GroupSheet(app: app, cards: allCards, targets: [card])
                .presentationDetents([.large])
        }
        .navigationDestination(item: $route) { id in
            if let card = allCards.first(where: { $0.localId == id }) {
                CardDetailScreen(card: card, app: app, pendingDeletes: pendingDeletes)
            }
        }
    }

    // MARK: Header

    private var header: some View {
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

            }

            Text(refreshLine).caliperLabel(Caliper.textTertiary)
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
    private var refreshLine: String {
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
            // Enumerated because a scrub has to know which row it started on.
            ForEach(Array(visible.enumerated()), id: \.element.localId) { index, card in
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
                    fileTarget: Folder.mostRecentlyUsed(in: groups),
                    openRowID: $openRowID,
                    onTap: {
                        if app.isSelecting {
                            // A long press that ends without a drag also reports
                            // a tap; toggling on it would undo the selection the
                            // press just made.
                            guard !dragSelect.swallowsTap() else { return }
                            app.toggleSelection(card.localId)
                        } else {
                            route = card.localId
                        }
                    },
                    onFile: { file(card) },
                    onDelete: { delete(card) }
                )
                // A target the scrub's auto-scroll can aim at.
                .id(card.localId)
                // Any ONE rendered row locates them all: rows are uniform, so its
                // index and frame give the stack's origin and its pitch. Sampling
                // whichever row happens to be rendered — rather than the first — is
                // what keeps this right after the list has scrolled and LazyVStack
                // has thrown row 0 away.
                .background(rowSampleReader(index: index))
                // The long press belongs to the SYSTEM again (2026-09-16). iOS's own
                // menu brings its zoom and its haptic with it, and that pairing is
                // what V4 had and what a hand-built lift never matched — the lift
                // and its 0.8s press went out with this coming back. Select turns
                // selection mode on; the scrub takes over from there.
                .contextMenu {
                    Button("Select") {
                        app.isSelecting = true
                        app.selection.insert(card.localId)
                    }
                    if card.folder != nil {
                        Button("Remove from group") {
                            card.folder = nil
                            try? context.save()
                        }
                    }
                    Button("Delete card", role: .destructive) { delete(card) }
                }
                // The scrub exists ONLY once selection mode is on, so it can never
                // compete with the context menu for the long press.
                .simultaneousGesture(
                    scrub(at: index),
                    including: app.isSelecting ? .all : .subviews
                )
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
        card.folder = target
        target.markUsed()
        try? context.save()
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

    // MARK: Scrub selection

    /// Long-press to take a row, then keep dragging to take the rest.
    ///
    /// `.sequenced` is what makes this ONE continuous touch: the press must succeed
    /// before the drag is recognised at all, so the finger never lifts between
    /// taking the first card and painting the rest. The drag reports in GLOBAL
    /// space because two different questions get asked of the same point — which
    /// row is under it, against the rows' measured origin, and how near it is to
    /// the viewport's edges, against the viewport's frame.
    private func scrub(at index: Int) -> some Gesture {
        // By the time this gesture exists the user is ALREADY in selection mode —
        // they chose Select from the menu — so the hold only has to separate a
        // deliberate scrub from a drag meant to scroll the list.
        //
        // It was 0.18s, and that is INSIDE the pause a finger makes between landing
        // and dragging: a user scrolling a selected list held still for a fifth of a
        // second, the press fired, scrollDisabled went true under their finger, and
        // the drag painted a selection instead of scrolling (user report, 0.5).
        // Scroll is the common action here and must win ties; Photos holds roughly
        // this long before it starts painting too.
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginScrub(at: index)
                case .second(true, let drag):
                    if let drag { updateScrub(at: drag.location) }
                default:
                    break
                }
            }
            .onEnded { _ in endScrub() }
    }

    private func beginScrub(at index: Int) {
        guard !dragSelect.isActive else { return }
        // A tray left open under the finger would be offering actions on a card the
        // user has just started selecting.
        openRowID = nil
        app.isSelecting = true
        app.selection = dragSelect.begin(at: index, rowIDs: rowIDs, selection: app.selection)

        // A light tick to say the scrub has taken hold — not the thump the old
        // hand-built long press needed, because getting into selection mode already
        // carried the system menu's own haptic.
        scrubHaptic.impactOccurred(intensity: 0.7)
        scrubHaptic.prepare()
    }

    private func updateScrub(at point: CGPoint) {
        guard dragSelect.isActive else { return }
        lastScrubPoint = point
        paintSelection(at: point.y)
        updateAutoScroll(for: point.y)
    }

    private func endScrub() {
        dragSelect.end()
        autoScrollUp = nil
    }

    /// Assigns only when the finger crosses into a different row — `move` returns
    /// nil otherwise, so neither the selection nor the haptic fires sixty times a
    /// second at a finger that has not really gone anywhere.
    private func paintSelection(at y: CGFloat) {
        guard let index = rowIndex(at: y),
              let next = dragSelect.move(to: index, rowIDs: rowIDs) else { return }
        app.selection = next
    }

    private func rowIndex(at y: CGFloat) -> Int? {
        DragSelectRange.index(
            at: y, rowsTop: rowsOriginY, rowHeight: rowHeight,
            gap: Caliper.rowGap, count: visible.count
        )
    }

    private var rowIDs: [UUID] { visible.map(\.localId) }

    /// Which edge band the finger is in, if any. Assigning `autoScrollUp` starts or
    /// cancels the loop, because it is that task's id — there is no timer of my own
    /// to forget to tear down.
    private func updateAutoScroll(for y: CGFloat) {
        let band: CGFloat = 70
        guard viewport.height > band * 2 else {
            autoScrollUp = nil
            return
        }
        let fromTop = y - viewport.minY
        let fromBottom = viewport.maxY - y
        if fromTop < band {
            autoScrollIntensity = min(1, max(0, 1 - fromTop / band))
            if autoScrollUp != true { autoScrollUp = true }
        } else if fromBottom < band {
            autoScrollIntensity = min(1, max(0, 1 - fromBottom / band))
            if autoScrollUp != false { autoScrollUp = false }
        } else if autoScrollUp != nil {
            autoScrollUp = nil
        }
    }

    /// Scrolls while the finger holds an edge, and re-reads what is under it after
    /// every step: the rows move beneath a stationary finger, so the selection has
    /// to keep extending even though the drag itself reports nothing.
    private func autoScrollLoop(proxy: ScrollViewProxy) async {
        guard let up = autoScrollUp else { return }
        while !Task.isCancelled, dragSelect.isActive {
            let step = 1 + Int(autoScrollIntensity * 2)
            guard let current = rowIndex(at: lastScrubPoint.y) else { break }
            let target = up ? current - step : current + step
            guard visible.indices.contains(target) else { break }
            withAnimation(.linear(duration: 0.1)) {
                proxy.scrollTo(visible[target].localId, anchor: up ? .top : .bottom)
            }
            try? await Task.sleep(for: .milliseconds(110))
            paintSelection(at: lastScrubPoint.y)
        }
    }

    // MARK: Geometry

    private func rowSampleReader(index: Int) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowSampleKey.self,
                value: RowSample(
                    index: index,
                    minY: geo.frame(in: .global).minY,
                    height: geo.size.height
                )
            )
        }
    }

    private var viewportReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { viewport = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, frame in viewport = frame }
        }
    }

    /// One rendered row's position, which is all it takes to place every row: they
    /// are a uniform height, so an index and a frame give both the stack's origin
    /// and its pitch.
    private struct RowSample: Equatable {
        let index: Int
        let minY: CGFloat
        let height: CGFloat
    }

    private struct RowSampleKey: PreferenceKey {
        static let defaultValue: RowSample? = nil
        /// Whichever rendered row reports first wins — they all describe the same
        /// stack, so there is nothing to combine.
        static func reduce(value: inout RowSample?, nextValue: () -> RowSample?) {
            value = value ?? nextValue()
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
