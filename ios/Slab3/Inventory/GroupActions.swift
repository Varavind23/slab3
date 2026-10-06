import SwiftData
import SwiftUI

/// Archive and delete for a user's own groups (owner, 2026-10-01;
/// ~/.claude/plans/misty-puzzling-nebula.md).
///
/// `Folder.archived` existed from the start and every picker already honours it
/// (`Folder.mostRecentlyUsed`, ScanFilingBar, ScanTargetRule) — nothing ever SET it,
/// so a finished buyer's group stayed in every list forever. There is deliberately
/// no manage-groups screen (FiltersSheet), so these run from a long-press on the
/// group rows that already exist, and live here so both sheets share one rule.
///
/// Plain groups only. A lot's group belongs to `LotFolders.sync` and to the lead's
/// archive of the LOT; archiving or deleting it here would fight the next sync.
@MainActor
enum GroupActions {
    static func canManage(_ group: Folder) -> Bool { !group.isTeamLot }

    /// Out of every list and picker; its cards keep their group, and the Archived
    /// section brings it back. Nothing may keep pointing at it as a destination.
    static func archive(_ group: Folder, app: AppState, in context: ModelContext) {
        guard canManage(group) else { return }
        group.archived = true
        let it = group.localId
        if app.scanTargetId == it.uuidString { app.scanTargetId = "" }
        if app.filter == .group(it) { app.filter = .all }
        try? context.save()
    }

    static func unarchive(_ group: Folder, in context: ModelContext) {
        group.archived = false
        try? context.save()
    }

    /// The group goes; its cards stay in inventory, ungrouped (`Folder.cards` is a
    /// `.nullify` relationship).
    static func deleteKeepingCards(_ group: Folder, app: AppState, in context: ModelContext) {
        guard canManage(group) else { return }
        forget(group, app: app)
        context.delete(group)
        try? context.save()
    }

    /// The group AND its cards, through the same undo window as every other card
    /// delete: the cards vanish now, the real delete (cards, then the group) lands
    /// when the window closes, and Undo puts everything back untouched.
    static func deleteWithCards(_ group: Folder, app: AppState, pending: PendingDeletionStore,
                                in context: ModelContext) {
        guard canManage(group) else { return }
        let ids = Set(group.cards.map(\.localId))
        guard !ids.isEmpty else { deleteKeepingCards(group, app: app, in: context); return }
        let groupId = group.localId
        let label = "\(group.name) and \(ids.count) \(ids.count == 1 ? "card" : "cards") deleted"
        pending.enqueue(ids, label: label) { ids in
            CardDeletion.commit(ids, in: context)
            // Re-read: the group may have been deleted or archived meanwhile.
            let all = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
            if let group = all.first(where: { $0.localId == groupId }), group.cards.isEmpty {
                forget(group, app: app)
                context.delete(group)
                try? context.save()
            }
        }
    }

    private static func forget(_ group: Folder, app: AppState) {
        if app.scanTargetId == group.localId.uuidString { app.scanTargetId = "" }
        if app.filter == .group(group.localId) { app.filter = .all }
    }
}

/// The long-press menu on a group row (FiltersSheet, GroupSheet): Archive or
/// Unarchive, and Delete — which ASKS what happens to the cards every time (owner).
/// "And its cards" is offered only where the undo window is reachable.
struct GroupManageMenu: ViewModifier {
    let group: Folder
    @Bindable var app: AppState
    var pending: PendingDeletionStore?
    /// Run after a choice, e.g. to close the sheet the row is in.
    var after: () -> Void = {}
    /// Run after "…and its cards" only: the Undo bar lives under any sheet, and its
    /// 5s window ran out unseen behind an open Filters sheet (workflow test
    /// 2026-10-06), so the sheet closes to show it.
    var revealUndo: () -> Void = {}
    @Environment(\.modelContext) private var context
    @State private var confirmDelete = false

    func body(content: Content) -> some View {
        if GroupActions.canManage(group) {
            content
                .contextMenu {
                    if group.archived {
                        Button { GroupActions.unarchive(group, in: context) } label: {
                            Label("Unarchive", systemImage: "tray.and.arrow.up")
                        }
                    } else {
                        Button { GroupActions.archive(group, app: app, in: context); after() } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                }
                .confirmationDialog("Delete \(group.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete group only") {
                        GroupActions.deleteKeepingCards(group, app: app, in: context); after()
                    }
                    if let pending, !group.cards.isEmpty {
                        let n = group.cards.count
                        Button("Delete group and its \(n) \(n == 1 ? "card" : "cards")", role: .destructive) {
                            GroupActions.deleteWithCards(group, app: app, pending: pending, in: context); after(); revealUndo()
                        }
                    }
                } message: {
                    Text(group.cards.isEmpty
                         ? "It has no cards."
                         : "Delete the group only and its cards stay in your inventory, ungrouped.")
                }
        } else {
            content
        }
    }
}

extension View {
    func groupManageMenu(_ group: Folder, app: AppState, pending: PendingDeletionStore? = nil,
                         after: @escaping () -> Void = {},
                         revealUndo: @escaping () -> Void = {}) -> some View {
        modifier(GroupManageMenu(group: group, app: app, pending: pending, after: after, revealUndo: revealUndo))
    }
}
