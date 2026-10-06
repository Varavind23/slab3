import Foundation
import SwiftData
import Testing
@testable import Slab3

/// Deleting a group through `GroupActions` (2026-10-02 cases, kept when 0.9 merged the
/// two group-delete builds into one): a neighbouring group is untouched, the filter
/// and scan target never point at a ghost, and team lots — the server's — are never
/// deletable by either path. Archive + the undo window's restore are ArchiveTests.
@MainActor
struct GroupDeletionTests {
    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private func fixture() -> (AppState, Folder, Folder, Card, Card) {
        let context = store.mainContext
        let suite = "slabs.test.groupdel.\(UUID().uuidString)"
        let app = AppState(defaults: UserDefaults(suiteName: suite)!)
        let old = Folder(name: "show 7/24"), other = Folder(name: "keep")
        context.insert(old); context.insert(other)
        let a = Card(scan: CertScan(grader: .psa, certNumber: "11111111", raw: "11111111"))
        let b = Card(scan: CertScan(grader: .psa, certNumber: "22222222", raw: "22222222"))
        context.insert(a); context.insert(b)
        CardFiling.file([a], into: old, in: context)
        CardFiling.file([b], into: other, in: context)
        return (app, old, other, a, b)
    }

    @Test func keepingCardsUngroupsThem() throws {
        let (app, old, other, a, b) = fixture()
        let pending = PendingDeletionStore(delay: .milliseconds(10))
        GroupActions.deleteKeepingCards(old, app: app, in: store.mainContext)
        let groups = try store.mainContext.fetch(FetchDescriptor<Folder>())
        #expect(groups.map(\.name) == ["keep"])
        #expect(a.folder == nil)
        #expect(b.folder === other)
        #expect(pending.pendingIDs.isEmpty)
    }

    @Test func withCardsDefersThroughTheUndoWindow() async throws {
        let (app, old, _, a, b) = fixture()
        let aId = a.localId, bId = b.localId
        let pending = PendingDeletionStore(delay: .milliseconds(10))
        GroupActions.deleteWithCards(old, app: app, pending: pending, in: store.mainContext)
        #expect(pending.pendingIDs == [aId])
        await pending.window?.value
        let left = try store.mainContext.fetch(FetchDescriptor<Card>()).map(\.localId)
        #expect(left == [bId])
        #expect(try store.mainContext.fetch(FetchDescriptor<Folder>()).map(\.name) == ["keep"])
    }

    @Test func filterAndScanTargetLetGo() {
        let (app, old, _, _, _) = fixture()
        app.filter = .group(old.localId)
        app.scanTargetId = old.localId.uuidString
        GroupActions.deleteKeepingCards(old, app: app, in: store.mainContext)
        #expect(app.filter == .all)
        #expect(app.scanTargetId == "")
    }

    @Test func teamLotsAreNeverDeleted() throws {
        let (app, old, _, _, _) = fixture()
        old.teamLotId = UUID()
        #expect(!GroupActions.canManage(old))
        GroupActions.deleteKeepingCards(old, app: app, in: store.mainContext)
        GroupActions.deleteWithCards(old, app: app, pending: PendingDeletionStore(), in: store.mainContext)
        #expect(try store.mainContext.fetch(FetchDescriptor<Folder>()).count == 2)
    }
}
