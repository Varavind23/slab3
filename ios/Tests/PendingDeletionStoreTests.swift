import Testing
import Foundation
@testable import Slab3

/// The undo window is the only thing standing between a thumb and permanent loss of
/// a scanned card, so every path that commits or cancels one is pinned here.
///
/// The store takes its delay as an injectable `Duration` precisely so these run in
/// milliseconds instead of the five seconds the app uses.
@MainActor
struct PendingDeletionStoreTests {
    private let a = UUID(), b = UUID(), c = UUID()

    /// Collects what actually got deleted, so a test can tell "committed" from
    /// "still pending" without a ModelContext.
    private final class Recorder {
        var committed: [Set<UUID>] = []
        var all: Set<UUID> { committed.reduce(into: []) { $0.formUnion($1) } }
    }

    @Test func enqueueHidesRowsWithoutDeletingThem() {
        let store = PendingDeletionStore(delay: .seconds(60))
        let recorder = Recorder()
        store.enqueue([a, b], label: "2 cards deleted") { recorder.committed.append($0) }
        #expect(store.pendingIDs == [a, b], "the rows leave the list immediately")
        #expect(recorder.committed.isEmpty, "but nothing is deleted yet")
        #expect(store.pending?.label == "2 cards deleted")
    }

    /// Awaiting the window rather than sleeping past it: `Task.sleep` carries
    /// tolerance, so a wall-clock wait makes these tests both slow and flaky.
    @Test func undoCancelsTheDeleteEntirely() async {
        let store = PendingDeletionStore(delay: .milliseconds(20))
        let recorder = Recorder()
        store.enqueue([a], label: "Card deleted") { recorder.committed.append($0) }
        let window = store.window
        store.undo()
        #expect(store.pendingIDs.isEmpty, "the row comes back")
        await window?.value
        #expect(recorder.committed.isEmpty, "and the window must not fire afterwards")
    }

    @Test func theWindowClosesAndTheDeleteCommits() async {
        let store = PendingDeletionStore(delay: .milliseconds(20))
        let recorder = Recorder()
        store.enqueue([a, b], label: "2 cards deleted") { recorder.committed.append($0) }
        await store.window?.value
        #expect(recorder.all == [a, b])
        #expect(store.pendingIDs.isEmpty)
        #expect(store.pending == nil, "and the Undo bar goes away with it")
    }

    /// There is only ever one thing to undo. A second delete commits the first,
    /// which is what keeps this a single optional instead of a table of timers.
    @Test func anotherDeleteCommitsThePreviousOne() {
        let store = PendingDeletionStore(delay: .seconds(60))
        let recorder = Recorder()
        store.enqueue([a], label: "Card deleted") { recorder.committed.append($0) }
        store.enqueue([b], label: "Card deleted") { recorder.committed.append($0) }
        #expect(recorder.all == [a], "the first delete is now real")
        #expect(store.pendingIDs == [b], "and only the second is undoable")
    }

    /// Each batch commits with the closure it was enqueued with — a later delete
    /// must not hand an older batch's ids to a newer screen's closure.
    @Test func eachBatchCommitsWithItsOwnClosure() {
        let store = PendingDeletionStore(delay: .seconds(60))
        var first: Set<UUID> = [], second: Set<UUID> = []
        store.enqueue([a], label: "Card deleted") { first.formUnion($0) }
        store.enqueue([b], label: "Card deleted") { second.formUnion($0) }
        store.flush()
        #expect(first == [a])
        #expect(second == [b])
    }

    /// Leaving the Cards tab and backgrounding both land here. A card that has left
    /// the list must never come back after a relaunch.
    @Test func flushCommitsImmediately() {
        let store = PendingDeletionStore(delay: .seconds(60))
        let recorder = Recorder()
        store.enqueue([a, b, c], label: "3 cards deleted") { recorder.committed.append($0) }
        store.flush()
        #expect(recorder.all == [a, b, c])
        #expect(store.pendingIDs.isEmpty)
    }

    @Test func flushWithNothingPendingDoesNothing() {
        let store = PendingDeletionStore(delay: .seconds(60))
        let recorder = Recorder()
        store.flush()
        store.undo()
        #expect(recorder.committed.isEmpty)
        #expect(store.pending == nil)
    }

    /// A delete of nothing must not raise an Undo bar with nothing in it.
    @Test func anEmptyDeleteIsIgnored() {
        let store = PendingDeletionStore(delay: .seconds(60))
        let recorder = Recorder()
        store.enqueue([], label: "0 cards deleted") { recorder.committed.append($0) }
        #expect(store.pending == nil)
        #expect(recorder.committed.isEmpty)
    }
}
