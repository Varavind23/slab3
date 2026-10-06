import SwiftUI
import SwiftData

/// Shared by Cards and Export — the same component, only the confirm verb changes
/// (README.md §5). The sticky confirm is always visible and always carries the
/// live count, which updates BEFORE the sheet closes.
///
/// The design's `BUY RANGE` section is deliberately absent: buy ranges are
/// consumed as a filter and referenced by payout, but nothing in the client's
/// reference or in Caliper ever authors one (README.md open question 3). Rather
/// than ship a section that can only ever be empty, this sheet offers the filter
/// the data actually supports — unmatched cards — and the section returns when
/// there's a screen that creates a range.
struct FiltersSheet: View {
    @Bindable var app: AppState
    let cards: [Card]
    let groups: [Folder]
    /// "Show" from Cards, "Export" from Export.
    let confirmVerb: String
    /// For "delete group and its cards" — the same undo window as every card delete.
    var pendingDeletes: PendingDeletionStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showArchived = false

    private var active: [Folder] { groups.filter { !$0.archived } }
    private var archived: [Folder] { groups.filter(\.archived) }

    var body: some View {
        CaliperSheet(title: "Filters") {
            if app.filter != .all {
                Button("Clear all") { app.filter = .all }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.cyan)
            }
        } content: {
            SectionLabel(text: "Groups")
            SheetRow(
                label: "All cards",
                trailing: "\(cards.count)",
                active: app.filter == .all
            ) { app.filter = .all }
            Hairline()
            SheetRow(
                label: "Ungrouped",
                trailing: "\(cards.filter { $0.folder == nil }.count)",
                active: app.filter == .ungrouped
            ) { app.filter = .ungrouped }
            Hairline()
            // Groups with zero cards still render — an empty group is a real one.
            // Long-press a row to archive or delete it (GroupActions).
            ForEach(active) { group in
                groupRow(group)
            }
            if !archived.isEmpty {
                Button { withAnimation(Caliper.easeOut) { showArchived.toggle() } } label: {
                    HStack {
                        Text("Archived · \(archived.count)").caliperLabel(Caliper.textTertiary)
                        Spacer()
                        Image(systemName: showArchived ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10)).foregroundStyle(Caliper.textTertiary)
                    }
                    .padding(.horizontal, Caliper.gutter)
                    .frame(minHeight: Caliper.hitMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CaliperPressStyle())
                Hairline()
                // Still a filter: an archived buyer's cards can be shown and exported.
                if showArchived { ForEach(archived) { group in groupRow(group) } }
            }

            SectionLabel(text: "Match")
            SheetRow(
                label: "Unmatched",
                sub: "No price from any source",
                trailing: "\(cards.filter { !$0.isMatched }.count)",
                active: app.filter == .unmatched
            ) { app.filter = .unmatched }
        } confirm: {
            CaliperButton(
                title: "\(confirmVerb) \(count) cards",
                variant: .primary,
                fullWidth: true
            ) { dismiss() }
        }
    }

    private func groupRow(_ group: Folder) -> some View {
        VStack(spacing: 0) {
            SheetRow(
                label: group.name,
                sub: "\(group.cards.count) cards",
                active: app.filter == .group(group.localId),
                leading: { Circle().fill(group.hue).frame(width: 8, height: 8) }
            ) { app.filter = .group(group.localId) }
            .groupManageMenu(group, app: app, pending: pendingDeletes, revealUndo: { dismiss() })
            Hairline()
        }
    }

    /// Live count for the confirm label — recalculated as the user taps rows.
    private var count: Int {
        cards.filter { card in
            switch app.filter {
            case .all: return true
            case .ungrouped: return card.folder == nil
            case .unmatched: return !card.isMatched
            case .group(let id): return card.folder?.localId == id
            }
        }.count
    }
}

/// Add the current selection to a group. Creating a group and assigning the
/// selection are ONE action — there is never a separate manage-groups screen
/// (README.md §4). After assignment the sheet dismisses, the selection clears,
/// and the affected rows show their new chip immediately.
struct GroupSheet: View {
    @Bindable var app: AppState
    let cards: [Card]
    /// Cards the caller has already picked, when filing is not a selection — the
    /// Cards swipe filing one row. Without this the sheet would have to flip the
    /// screen into selection mode just to file a single card, which is a mode the
    /// user did not ask for.
    var targets: [Card]?
    /// For "delete group and its cards" from a row's long-press.
    var pendingDeletes: PendingDeletionStore? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.createdAt, order: .reverse) private var allGroups: [Folder]
    @State private var newName = ""

    /// Ordinary groups, plus the groups of OPEN team lots — filing into one claims
    /// each card (CardFiling), so the 3-per-lot check runs on this path too.
    private var groups: [Folder] {
        let open = app.lots.openLotIds
        return allGroups.filter {
            !$0.archived && LotFolders.isFileable($0, openLots: open, lotsLoaded: app.lots.hasLoaded)
        }
    }

    private var selected: [Card] { targets ?? cards.filter { app.selection.contains($0.localId) } }

    var body: some View {
        CaliperSheet(title: "Add \(selected.count) to group") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            ForEach(groups) { group in
                SheetRow(
                    label: group.name,
                    sub: "\(group.cards.count) cards",
                    trailing: "›",
                    leading: { Circle().fill(group.hue).frame(width: 8, height: 8) }
                ) { assign(to: group) }
                .groupManageMenu(group, app: app, pending: pendingDeletes, revealUndo: { dismiss() })
                Hairline()
            }
            if groups.isEmpty {
                Text("No groups yet. Name one below.")
                    .font(.calBody)
                    .foregroundStyle(Caliper.textSecondary)
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.vertical, Caliper.space6)
            }
        } confirm: {
            VStack(spacing: Caliper.space5) {
                Hairline(color: Caliper.cyanDim)
                HStack(spacing: Caliper.space4) {
                    TextField("New group name...", text: $newName)
                        .font(.calBody)
                        .foregroundStyle(Caliper.textPrimary)
                        .padding(.horizontal, Caliper.rowPad)
                        .frame(height: Caliper.hitMin)
                        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                    CaliperButton(title: "Create", variant: .primary, disabled: trimmed.isEmpty) {
                        create()
                    }
                }
            }
        }
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespaces) }

    private func create() {
        guard !trimmed.isEmpty else { return }
        // Hue rotates through the palette so consecutive groups stay tellable apart.
        let group = Folder(name: trimmed, hueIndex: allGroups.count % Caliper.groupHues.count)
        context.insert(group)
        assign(to: group)
    }

    private func assign(to group: Folder) {
        // Recency (the swipe's "file into the group last used") is recorded inside.
        CardFiling.file(selected, into: group, in: context)
        app.endSelecting()
        dismiss()
    }
}
