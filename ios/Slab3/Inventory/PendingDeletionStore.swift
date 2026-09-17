import Foundation
import Observation
import SwiftData

/// The delete the undo window defers, in ONE place — the swipe and the selection
/// bar hand it the same ids, and neither owns the implementation.
///
/// It re-reads from the store rather than closing over the cards themselves: the
/// window is seconds long, and the array a view was rendering when the user swiped
/// is not guaranteed to still describe the store by the time it expires.
enum CardDeletion {
    @MainActor
    static func commit(_ ids: Set<UUID>, in context: ModelContext) {
        guard !ids.isEmpty else { return }
        let all = (try? context.fetch(FetchDescriptor<Card>())) ?? []
        for card in all where ids.contains(card.localId) { context.delete(card) }
        try? context.save()
    }
}

/// Deletes that have happened on screen but not yet in the store.
///
/// WHY DELETION IS DEFERRED AT ALL. A card carries its scan photograph, its prices
/// and its comps, nothing is synced to a server, and there is no other copy — so a
/// delete is the one irreversible act in the app. Swipe-to-delete makes that act
/// reachable with a thumb, and a full swipe commits it without a menu. Making it
/// easier without making it recoverable would be a bad trade, so the row leaves the
/// list immediately and the real `context.delete` happens a few seconds later,
/// behind an Undo bar.
///
/// ONE BATCH AT A TIME. Starting a new delete commits the previous one, which is
/// what collapses this to a single optional rather than a table of timers: there is
/// never more than one thing to undo, and the Undo bar never has to choose which
/// delete it is talking about.
///
/// It holds no `ModelContext`. The caller hands in the closure that does the actual
/// deleting, so this stays testable without a store and cannot delete anything on
/// its own.
///
/// Lifetime matters: it belongs to `MainShell`, alongside the selection bar it
/// shares a slot with. Rebuilt per screen appearance, its timer would be cancelled
/// by ARC and a pending delete would silently never commit.
@MainActor
@Observable
final class PendingDeletionStore {

    struct Batch: Equatable {
        let ids: Set<UUID>
        /// What the Undo bar says: "Card deleted", "12 cards deleted".
        let label: String
    }

    private(set) var pending: Batch?

    /// Rows to hide right now — read by `CardsScreen.visible` AND
    /// `ExportScreen.scoped`, because a card inside its undo window must not appear
    /// in inventory or in an exported CSV.
    var pendingIDs: Set<UUID> { pending?.ids ?? [] }

    private var timer: Task<Void, Never>?

    /// The running window, so a test can await it instead of racing a wall clock:
    /// `Task.sleep` carries tolerance, and a 40ms window can land well past a
    /// 150ms wait on a loaded machine. Nothing in the app reads this.
    var window: Task<Void, Never>? { timer }
    /// Kept with the batch rather than passed to `flush`, so committing an older
    /// batch always uses the closure that batch was enqueued with.
    private var commitPending: ((Set<UUID>) -> Void)?
    private let delay: Duration

    /// Tests inject milliseconds; the app takes the default.
    init(delay: Duration = .seconds(5)) {
        self.delay = delay
    }

    /// Hide these rows now, delete them for real once the window closes.
    func enqueue(_ ids: Set<UUID>, label: String, commit: @escaping (Set<UUID>) -> Void) {
        guard !ids.isEmpty else { return }
        flush() // a new delete commits whatever was still pending
        pending = Batch(ids: ids, label: label)
        commitPending = commit
        let wait = delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Put the rows back. The cards were never touched, so there is nothing to
    /// restore — which is the whole point of deferring rather than deleting and
    /// re-inserting a copy.
    func undo() {
        timer?.cancel()
        timer = nil
        pending = nil
        commitPending = nil
    }

    /// Commit now. Called on the timer, when another delete starts, when the user
    /// leaves the Cards tab, and when the app backgrounds — backgrounding being the
    /// last checkpoint iOS guarantees, and the one that stops a "deleted" card from
    /// reappearing after a relaunch.
    func flush() {
        timer?.cancel()
        timer = nil
        guard let batch = pending, let commit = commitPending else { return }
        pending = nil
        commitPending = nil
        commit(batch.ids)
    }
}
